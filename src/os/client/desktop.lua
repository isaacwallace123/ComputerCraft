--- The desktop: one bar, a wall of icons, and whatever app you opened.
---
--- `os/client/shell.lua` mounted one app full-screen and drew a row of words
--- underneath. That is a launcher. It tells you what exists and never tells you
--- what you are looking at, there is no way back to anywhere, and the first
--- thing it does on boot is put you inside an app you did not choose.
---
--- ## One app is built at a time, and this is the important sentence
---
--- The first version of this file built *every* app's page at mount and hid all
--- but one behind a `Hidden` binding. That is precisely what `reactive.live()`
--- exists to catch, and `shell.lua` had already written the warning down:
--- "ten pages of Computed recalculating on every heartbeat so that nine can be
--- invisible".
---
--- It is worse than it sounds, because `invalidate` marks everything downstream
--- of a changed value stale whether or not the value moved. So one tick of the
--- machine clock invalidated every binding in twelve pages - including the ones
--- that walk peripherals, read the log file, and re-sort the fleet - and
--- repainted the lot, once a second, forever. In world that came out as a
--- desktop too slow to click and a turtle that died with
--- `java.lang.OutOfMemoryError`.
---
--- So the session loop below builds the icon wall **or** one app, runs it, tears
--- it down, and builds the next. Switching costs a rebuild, which happens when a
--- person presses a key and is invisible; being open costs nothing at all.
---
--- ## The bar is the whole of the chrome
---
--- `ICOS` on the left is home, the apps you have opened follow it as tabs, and
--- the time is on the right. The active tab is painted in the page's own
--- background so it reads as continuous with what is below it, which is the one
--- trick a tab strip has.
---
--- There is no second bar and no hint line. A window that drew its own title
--- over a page that drew its own title, above a hint saying which key closes it,
--- was three rows of furniture on a screen with nineteen.
---
--- ## The keys
---
--- `Q` closes, everywhere, unless something is focused that can accept a
--- letter - typing `q` into the console must type a `q`. Escape goes home
--- without closing. Numbers open from the wall. `M` picks an icon up.
---
--- None of that is written on screen, because a bar that lists its own shortcuts
--- is a bar spending a row on the assumption you will need telling twice.

local format = require("ui.format")
local host = require("ui.host")
local reactive = require("ui.state.reactive")
local registry = require("apps.registry")
local theme = require("ui.theme")
local ui = require("ui.init")

require("ui.components.desktop")

local T = theme.TOKENS

local desktop = {}

--- How many columns of icons fit, how wide each is, and where the wall starts.
---
--- Derived rather than declared, so the same code lays out a 26-wide handheld
--- and a 51-wide monitor. Two columns is the floor: one column is a list, and a
--- list is what this replaced.
---
--- The third return is the margin, and it is the fix for a wall that sat hard
--- against the left edge with four cells of nothing on the right. Whatever the
--- tiles do not use is split evenly, so the grid is centred in the screen rather
--- than merely starting at it.
function desktop.grid(width)
  local tile = 11
  local gap = 1
  local columns = math.max(2, math.floor((width - 2 + gap) / (tile + gap)))
  local used = columns * tile + (columns - 1) * gap
  return columns, tile, math.max(0, math.floor((width - used) / 2))
end

--- Which cell a selection index sits at, given the column count.
function desktop.cell(index, columns)
  local zero = index - 1
  return math.floor(zero / columns) + 1, (zero % columns) + 1
end

--- Move the selection by a row or a column, clamped.
---
--- Clamped rather than wrapped, unlike the old taskbar. On a grid, wrapping from
--- the last icon to the first jumps the cursor across and up, which reads as the
--- selection having been lost - whereas on a single row it read as continuing.
function desktop.move(index, count, columns, dx, dy)
  if count == 0 then
    return 1
  end
  local row, column = desktop.cell(index, columns)
  local rows = math.ceil(count / columns)

  row = math.max(1, math.min(rows, row + (dy or 0)))
  column = math.max(1, math.min(columns, column + (dx or 0)))

  local moved = (row - 1) * columns + column
  return math.max(1, math.min(count, moved))
end

--- Whether there is room for a blank line between rows of icons.
---
--- The wall grows every time an app is added and the terminal does not, so the
--- gap is the first thing to give up. Without this the twelfth app pushed the
--- bottom row off a 19-row screen, which reads as the app not existing - the
--- worst possible way for a desktop to run out of space.
function desktop.spacing(height, count, columns)
  local rows = math.ceil(count / math.max(1, columns))
  -- The bar, and the blank line under it.
  local chrome = 2
  return (height - chrome - rows * 4) >= rows and 1 or 0
end

---------------------------------------------------------------------------
-- Arranging
---------------------------------------------------------------------------

--- Where the arrangement is kept.
---
--- Its own file rather than a section of anything, because it belongs to the
--- person sitting at this machine and to nothing else - a base and the pocket
--- computer in their inventory should not have to agree about where Bank sits.
desktop.ORDER_PATH = ".desktop"

--- Put the apps in the order somebody arranged them.
---
--- Pure, and it has to be: the two things that can go wrong here are an app that
--- was uninstalled still holding a cell, and an app that was added never getting
--- one. Both are silent - the first draws a hole and the second draws nothing at
--- all - so both are specs rather than something noticed in a screenshot.
---
--- Unknown ids are dropped and unplaced apps are appended in their declared
--- order, which means a fleet that updates into a new app finds it at the end of
--- the wall rather than not at all.
function desktop.arrange(entries, order)
  if type(order) ~= "table" then
    return entries
  end

  local byId = {}
  for _, entry in ipairs(entries) do
    local manifest = entry.manifest or entry
    byId[manifest.id] = entry
  end

  local out = {}
  local placed = {}
  for _, id in ipairs(order) do
    local entry = byId[id]
    if entry and not placed[id] then
      placed[id] = true
      out[#out + 1] = entry
    end
  end

  for _, entry in ipairs(entries) do
    local manifest = entry.manifest or entry
    if not placed[manifest.id] then
      out[#out + 1] = entry
    end
  end

  return out
end

--- Exchange two entries, returning a new list.
---
--- A swap rather than an insert-and-shift. On a grid, shifting means every icon
--- after the one being moved slides to a new cell, so putting Bank next to Fleet
--- rearranges eight other things - and the person who moved one icon now has to
--- find the rest. A swap changes exactly the two cells somebody was looking at.
---
--- A copy rather than a mutation, because the result is handed to a `Value` and
--- `reactive` compares by identity: a list mutated in place is the same table it
--- was, so nothing would redraw and the icon would appear not to have moved.
function desktop.swap(entries, from, to)
  local out = {}
  for index, value in ipairs(entries) do
    out[index] = value
  end
  if from ~= to and out[from] ~= nil and out[to] ~= nil then
    out[from], out[to] = out[to], out[from]
  end
  return out
end

--- Read the arrangement somebody saved, or nil.
---
--- Every failure is nil, which the caller reads as "not arranged yet". A desktop
--- that refused to draw because its layout file was corrupt would be a desktop
--- nobody could use to fix it.
function desktop.load(context)
  if context.storage == nil or context.serialise == nil then
    return nil
  end
  local text = context.storage.read(desktop.ORDER_PATH)
  if text == nil then
    return nil
  end
  local ok, saved = pcall(context.serialise.decode, text)
  if not ok or type(saved) ~= "table" then
    return nil
  end
  return saved
end

--- Write the arrangement, as app ids rather than positions.
---
--- Ids, so that an update that adds or removes an app leaves the rest where they
--- were. A file of numbers would silently rearrange the whole wall the first
--- time the app list changed length, which is exactly when somebody is least
--- expecting their desktop to move.
function desktop.persist(context, entries)
  if context.storage == nil or context.serialise == nil then
    return false
  end
  local ids = {}
  for _, entry in ipairs(entries) do
    local manifest = entry.manifest or entry
    ids[#ids + 1] = manifest.id
  end
  return context.storage.write(desktop.ORDER_PATH, context.serialise.encode(ids)) and true or false
end

---------------------------------------------------------------------------
-- What is open
---------------------------------------------------------------------------

--- Add an app to the list of open ones, keeping the order they were opened in.
---
--- A tab here is a bookmark, not a live window, and that is an honest name for
--- what a machine with one terminal can offer. Nothing is recomputing behind the
--- app you are looking at, because nothing behind it is built - see the header.
--- What the strip buys is getting back to the four pages you are actually using
--- without going through the wall each time.
function desktop.opened(list, index)
  for _, value in ipairs(list) do
    if value == index then
      return list
    end
  end
  local out = {}
  for position, value in ipairs(list) do
    out[position] = value
  end
  out[#out + 1] = index
  return out
end

--- Take an app out of the list.
function desktop.closed(list, index)
  local out = {}
  for _, value in ipairs(list) do
    if value ~= index then
      out[#out + 1] = value
    end
  end
  return out
end

--- The entry behind whatever `state.open` holds.
---
--- An index into the wall, or an app id. Two kinds because a section bar names
--- its siblings by id: Mine, Automation and Job are hidden from the wall, so
--- they have no index there and an index could never reach them.
---
--- Nil for the wall itself and for an id that no longer exists, which is what a
--- saved arrangement naming a retired app looks like.
function desktop.entryAt(entries, open)
  if type(open) == "number" then
    return entries[open]
  end
  if type(open) == "string" then
    return registry.byId(open)
  end
  return nil
end

---------------------------------------------------------------------------
-- Chrome
---------------------------------------------------------------------------

--- One tab in the bar.
---
--- The active one is painted in the page's own background so that it reads as
--- continuous with the content below it. That is the whole of what makes a strip
--- of words look like tabs, and it costs nothing.
local function tab(scope, label, active, onPick, onClose)
  local background = active and T.background or T.chrome

  if onClose == nil then
    return scope:Text({
      Text = " " .. label .. " ",
      Background = background,
      Color = active and T.foreground or T.chromeFg,
      OnClick = onPick,
    })
  end

  -- Two nodes, because a cell can only belong to one click target. The label
  -- opens and the `x` closes, and they have to be separately hittable or the
  -- close is a corner of the tab somebody finds by accident.
  return scope:Row({
    Children = {
      scope:Text({
        Text = " " .. label,
        Background = background,
        Color = active and T.foreground or T.chromeFg,
        OnClick = onPick,
      }),
      scope:Text({
        Text = "x",
        Background = background,
        Color = active and T.mutedFg or T.chromeFg,
        OnClick = onClose,
      }),
    },
  })
end

--- The bar: home, what is open, and the time.
---
--- The health warning appears only when there is one, and it takes the space the
--- clock would otherwise have. A machine whose services are failing has
--- something better to say than what time it is, and hiding a fault to make room
--- for a clock would be the wrong trade in the one place everybody looks.
local function bar(scope, context, state, entries, options)
  local children = {
    tab(
      scope,
      "ICOS",
      scope:Computed(function(use)
        return use(state.open) == nil
      end),
      options.readOnly and nil or function()
        state.wanted:set("home")
      end
    ),
  }

  -- How many tabs there is room for, and the clock always wins.
  --
  -- The strip used to grow until it ran off the right edge, taking the time with
  -- it - so the machine's own bar became the one thing on screen that could not
  -- fit on screen. The oldest tabs are dropped rather than the newest, because
  -- the one you just opened is the one you are about to go back to.
  local width = options.width or 51
  local room = math.max(1, math.floor((width - 6 - 8) / 8))
  local shown = {}
  for index = math.max(1, #state.tabs - room + 1), #state.tabs do
    shown[#shown + 1] = state.tabs[index]
  end

  for _, index in ipairs(shown) do
    local manifest = desktop.entryAt(entries, index) or { id = "?" }
    children[#children + 1] = tab(
      scope,
      format.ellipsis(manifest.name or manifest.id, 5),
      scope:Computed(function(use)
        return use(state.open) == index
      end),
      options.readOnly and nil or function()
        state.wanted:set(index)
      end,
      options.readOnly and nil
        or function()
          state.closing:set(index)

          -- Closing the page you are looking at goes home; closing any other one
          -- stays where you are. Both end the session, because the strip is built
          -- from a list the session captured and a change to it cannot be seen
          -- without rebuilding.
          state.wanted:set(
            reactive.peek(state.open) == index and "home" or reactive.peek(state.open) or "home"
          )
        end
    )
  end

  children[#children + 1] = scope:Spacer({ Grow = 1 })
  children[#children + 1] = scope:Text({
    Color = T.chromeFg,
    Text = scope:Computed(function(use)
      use(state.tick)

      local sup = context.supervisor
      if sup ~= nil then
        local healthy, why = sup:healthy()
        if not healthy then
          return "! " .. format.ellipsis(tostring(why), 20)
        end
      end

      -- The world's hour, not UTC. The person reading it is standing in the
      -- world; see `ports/clock.lua` for why those are two different clocks.
      return context.clock and format.clock(context.clock.time()) or ""
    end),
  })

  return scope:Row({
    Height = 1,
    Background = T.chrome,
    Children = children,
  })
end

--- The row of sections across the top of a page that belongs to one.
---
--- Fleet, Mine, Automation and Job are four views of one activity, and they used
--- to be four icons: setting up a mine meant crossing the home screen four times
--- to do one thing. This makes them one app with four sections, using the same
--- machinery the tab bar uses - picking one ends the session and the next is
--- built showing that page, so exactly one section is ever built.
---
--- That last point is why this is a bar and not four `Hidden` subtrees. Building
--- all of them and showing one is how twelve pages came to be live at once on a
--- machine that could afford one.
---
--- Nil when the open page is in no section, which is most of them.
local function sections(scope, state, entry, options)
  if entry == nil or entry.section == nil then
    return nil
  end

  local family =
    registry.family(entry.section, options.role or "client", options.surface or "desktop")
  if #family < 2 then
    return nil
  end

  local children = {}
  for _, sibling in ipairs(family) do
    local active = sibling.id == entry.id
    children[#children + 1] = scope:Text({
      Text = " " .. (sibling.sectionName or sibling.name or sibling.id) .. " ",
      Background = active and T.accent or T.muted,
      Color = active and T.accentFg or T.mutedFg,
      OnClick = (options.readOnly or active) and nil or function()
        state.wanted:set(sibling.id)
      end,
    })
    children[#children + 1] = scope:Spacer({ Width = 1 })
  end

  return scope:Row({ Height = 1, Children = children })
end

---------------------------------------------------------------------------
-- The wall
---------------------------------------------------------------------------

local function wall(scope, state, entries, options)
  local width = options.width or 51
  local height = options.height or 19
  local columns, tile, margin = desktop.grid(width)
  local gap = desktop.spacing(height, #entries, columns)

  local grouped = {}
  for index = 1, #entries do
    local at = math.floor((index - 1) / columns) + 1
    grouped[at] = grouped[at] or {}

    local manifest = entries[index]
    grouped[at][#grouped[at] + 1] = scope:Icon({
      Width = tile,

      -- A glyph, not a sprite. There were 8x6 sprites here and they went back
      -- out: four cells of two-colour pixels is not enough to draw an object, so
      -- every icon came out a blue smudge that had to be labelled anyway - and a
      -- wall of them costs 1.6x a wall of glyphs to build, measured. The sprites
      -- still exist for ores and blocks, where the subject is a texture rather
      -- than an idea.
      Glyph = manifest.glyph,
      Label = format.ellipsis(manifest.name or manifest.id, tile),

      Selected = scope:Computed(function(use)
        return use(state.selected) == index
      end),
      Held = scope:Computed(function(use)
        return use(state.holding) == index
      end),

      OnOpen = function()
        state.selected:set(index)
        state.wanted:set(index)
      end,
    })
  end

  local children = {}
  for _, tiles in ipairs(grouped) do
    children[#children + 1] = scope:Row({
      Gap = 1,
      Height = 4,
      Padding = { left = margin, right = margin, top = 0, bottom = 0 },
      Children = tiles,
    })
    if gap > 0 then
      children[#children + 1] = scope:Spacer({ Height = gap })
    end
  end

  return scope:Column({ Grow = 1, Children = children })
end

---------------------------------------------------------------------------
-- Building one session
---------------------------------------------------------------------------

--- The whole surface: the bar, and either the wall or one app.
---
--- `state.open` is the entry index or nil for the wall, and it does not change
--- while a session is alive - the session ends and the next one is built with a
--- different one. Everything else on screen is derived from it and the machine's
--- tick.
function desktop.build(scope, context, state, entries, options)
  options = options or {}

  local body
  local section = nil
  local index = reactive.peek(state.open)
  local entry = desktop.entryAt(entries, index)

  if index == nil then
    body = wall(scope, state, entries, options)
  else
    section = sections(scope, state, entry, options)

    -- Read off disk here, not at boot. `registry.available` hands back names;
    -- the module behind one is loaded the first time somebody opens it, which is
    -- why a machine that never opens the console never pays for it.
    local app, why = registry.load(entry)
    body = scope:Column({
      Grow = 1,
      Children = {
        app
            and app.mount(scope, context, {
              readOnly = options.readOnly,
              capacity = options.capacity,
              tick = state.tick,
            })
          or scope:Text({
            -- A page that failed to load says so rather than leaving a blank
            -- rectangle, which is the single most common way somebody concludes a
            -- machine has hung.
            Text = format.ellipsis(tostring(why or "could not open"), (options.width or 51) - 2),
            Color = T.destructive,
          }),
      },
    })
  end

  local children = { bar(scope, context, state, entries, options) }

  -- One blank row under the bar on the wall, none inside an app: a page brings
  -- its own top padding and a second one would push its last row off the screen.
  if index == nil then
    children[#children + 1] = scope:Spacer({ Height = 1 })
  end
  if section ~= nil then
    children[#children + 1] = section
  end
  children[#children + 1] = body

  return scope:Column({
    Grow = 1,
    Background = T.background,
    Children = children,
  })
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

--- Run the desktop until the screen stops.
---
--- The `draw` that a client, a server and a turtle all supervise. A session is
--- one view - the wall, or one app - and ends when somebody asks for a different
--- one; the loop then destroys the whole scope and builds the next. See the
--- header for why that is not merely tidy.
function desktop.run(context, options)
  options = options or {}

  local entries = options.apps
    or registry.available(options.role or "client", options.surface or "desktop")
  if #entries == 0 then
    return
  end

  -- Whatever arrangement the person at this machine last left.
  entries = desktop.arrange(entries, desktop.load(context))

  local width, height = context.screen.size()
  local columns = desktop.grid(width)

  -- Carried across sessions in plain locals, because they outlive the scope that
  -- draws them. A `Value` here would be destroyed with its session and the
  -- desktop would forget which icon was selected every time an app closed.
  local open = nil
  local selected = 1
  local holding = nil
  local tabs = {}

  while true do
    local scope = ui.scoped()
    local state = {
      open = scope:Value(open),
      selected = scope:Value(selected),
      holding = scope:Value(holding),
      tick = context.tick or scope:Value(0),
      tabs = tabs,

      -- What the next session should show: an entry index, or "home". Read by
      -- the loop after `host.run` returns, so a click on a tab and a keypress
      -- end a session the same way.
      wanted = scope:Value(nil),

      -- A tab somebody pressed the `x` on. Read after the session ends, for the
      -- same reason `wanted` is: the strip is built from a list this session
      -- captured, so removing an entry from it cannot show up until the next one.
      closing = scope:Value(nil),
    }

    local root = host.mount({
      screen = context.screen,
      scope = scope,
      palette = options.palette,
      build = function(inner)
        return desktop.build(inner, context, state, entries, {
          width = width,
          height = height,
          readOnly = options.readOnly,
          capacity = options.capacity,

          -- Carried through, not defaulted inside `build`. The section bar asks
          -- the registry which pages share a section *for this machine*, and a
          -- missing role silently answers "none" - so the bar drew nothing and
          -- Mine, Automation and Job became unreachable rather than merely
          -- unstyled. A filter whose failure mode is an empty list has to be
          -- given the real value.
          role = options.role or "client",
          surface = options.surface or "desktop",
        })
      end,
    })

    --- Whether the thing with focus is expecting letters.
    ---
    --- `Q` closes an app everywhere except inside a text field, where it has to
    --- type a `q`. Asking the focused node whether it takes characters is the
    --- only test that stays right when a new component learns to: a list of
    --- component kinds here would be a list somebody has to remember to add to.
    local function typing()
      return root.focused ~= nil and root.focused.OnChar ~= nil
    end

    --- End this session and say what to build next.
    local function go(target)
      state.wanted:set(target)
      return host.STOP
    end

    host.run(root, context.input, {
      clock = context.clock,
      timeout = options.timeout,

      -- A click on an icon or a tab reaches the component, not `onEvent`, so
      -- the handler can only record what was wanted. This is what turns that
      -- record into the end of the session - without it a click set the value
      -- and the old view kept drawing until the next keypress, which is what
      -- "clicking does nothing" looks like from the other side of the screen.
      onFrame = function()
        if reactive.peek(state.wanted) ~= nil then
          return host.STOP
        end
        return nil
      end,

      onEvent = function(name, a)
        local KEY = require("ui.input").KEY
        local current = reactive.peek(state.open)

        --- Put the carried icon down, and remember where.
        ---
        --- Written on drop rather than on every arrow press, because each move
        --- is a real filesystem write and somebody arranging a desktop presses a
        --- lot of arrows.
        local function drop()
          state.holding:set(nil)
          holding = nil
          desktop.persist(context, entries)
        end

        if name == "key" then
          -- Escape goes home without closing anything, which is the difference
          -- between backing out of an app and being done with it.
          if a == KEY.escape then
            if reactive.peek(state.holding) ~= nil then
              drop()
              return true
            end
            if current ~= nil then
              return go("home")
            end
            return false
          end

          if current ~= nil then
            -- Inside an app every other key is the app's. A desktop that also
            -- read them would be a desktop competing with the page for arrows.
            return false
          end

          local held = reactive.peek(state.holding)
          local from = reactive.peek(state.selected)

          local function step(dx, dy)
            local to = desktop.move(from, #entries, columns, dx, dy)
            if held ~= nil and to ~= from then
              entries = desktop.swap(entries, from, to)
              -- Carried in a plain local as well as in the session's `Value`,
              -- because the swap ends the session and the next one is built from
              -- these. Without it an icon was dropped after one step and had to
              -- be picked up again for every cell it moved.
              holding = to
              selected = to
              -- The wall is built from `entries`, which the session captured, so
              -- a swap has to end the session to be seen. It is a keypress; the
              -- rebuild is invisible.
              return go("home")
            end
            state.selected:set(to)
            selected = to
            return true
          end

          if a == KEY.left then
            return step(-1, 0)
          elseif a == KEY.right then
            return step(1, 0)
          elseif a == KEY.up then
            return step(0, -1)
          elseif a == KEY.down then
            return step(0, 1)
          elseif a == KEY.enter then
            if held ~= nil then
              drop()
              return true
            end
            return go(from)
          end
          return false
        end

        if name == "char" then
          -- A field that is focused gets every letter, `q` included. Closing an
          -- app somebody is typing into is the bug this exists to prevent.
          if typing() then
            return false
          end

          if a == "q" or a == "Q" then
            if current ~= nil then
              tabs = desktop.closed(tabs, current)
              return go("home")
            end
            return false
          end

          if current ~= nil then
            return false
          end

          -- Pick an icon up, or put it down. A held modifier would be the
          -- obvious gesture: CC does report shift, but only as a key down and up
          -- either side of the arrow, so a drag would be a state machine racing
          -- the repeat rate. A mode you enter and leave is honest about that,
          -- and the tile turns amber to say which it is in.
          if (a == "m" or a == "M") and not options.readOnly then
            if reactive.peek(state.holding) ~= nil then
              drop()
            else
              holding = reactive.peek(state.selected)
              state.holding:set(holding)
            end
            return true
          end

          local picked = tonumber(a)
          if picked and entries[picked] then
            selected = picked
            return go(picked)
          end
        end

        return false
      end,
    })

    local wanted = reactive.peek(state.wanted)
    scope:destroy()

    if wanted == nil then
      -- The input port ended rather than somebody asking for another view. The
      -- supervisor treats a returned draw loop as a fault, which is right: a
      -- client whose screen has stopped should be remounted, not left showing
      -- its last frame.
      return
    end

    local closing = reactive.peek(state.closing)
    if closing ~= nil then
      tabs = desktop.closed(tabs, closing)
    end

    if wanted == "home" then
      open = nil
    else
      open = wanted
      tabs = desktop.opened(tabs, wanted)
      selected = wanted
    end
  end
end

return desktop
