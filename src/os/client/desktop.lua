--- The desktop: what a machine looks like when nothing is open.
---
--- `os/client/shell.lua` mounted one app full-screen and drew a row of words
--- underneath. That is a launcher. It tells you what exists and never tells you
--- what you are looking at, there is no way back to anywhere, and the first
--- thing it does on boot is put you inside an app you did not choose.
---
--- This is a desktop: a wall of icons, a bar that says what the machine is, and
--- apps that open in a window you can close.
---
--- ## Why the icons are a grid and not a list
---
--- A list of eight apps on a 51-column monitor uses one column and wastes fifty.
--- The grid is computed from the actual screen, so a wall monitor shows four
--- across and a Pocket Computer shows two, from the same numbers - and neither
--- has a layout written for it.
---
--- ## One app at a time, and that is not a limitation
---
--- CC gives a computer one terminal and one event queue. Two windows would mean
--- deciding which one a keypress belongs to, drawing one over the other, and
--- keeping both live - ten pages of `Computed` recalculating so nine can be
--- invisible, which is the thing `reactive.live()` exists to catch.
---
--- So a window is modal and closing it returns to the desktop. What that buys is
--- that the open app is always the focused app, which is the property a tiling
--- window manager spends most of its code enforcing.
---
--- ## The icons can be moved, and where they end up is remembered
---
--- A grid whose order is fixed by a `require` list is a grid arranged by whoever
--- wrote the list. Press `m` to pick an icon up, arrow it somewhere, press enter
--- to put it down; the arrangement is written to `.desktop` as app **ids**, so
--- an update that adds an app leaves everything else where it was.
---
--- A held modifier would be the obvious gesture and is not available: CC reports
--- shift as an ordinary key event with no way to ask whether it is still down,
--- so a drag would be a state machine guessing at a key it cannot observe. A
--- mode you enter and leave is honest about that, and the tile says which it is
--- in.
---
--- ## The state is four values
---
--- Which cell is selected, which app is open, which cell is being carried, and
--- the permutation that says what is in each cell. Everything on screen is
--- derived from those and the machine's tick, so there is no arrangement of them
--- that can disagree with what is drawn.
---
--- The tiles are built per *cell* rather than per app, which is what makes a move
--- one `Value` away from being drawn. Tiles built per app would have to be torn
--- down and re-mounted to move one, inside a keypress handler.

local appIcons = require("ui.icons")
local host = require("ui.host")
local reactive = require("ui.state.reactive")
local shell = require("os.client.shell")
local theme = require("ui.theme")
local ui = require("ui.init")

require("ui.components.desktop")

local T = theme.TOKENS

local desktop = {}

--- A glyph per app, chosen for what it suggests at one character.
---
--- CC's font is code page 437, so these are the shapes that actually exist
--- rather than the ones a modern terminal would offer. A missing codepoint
--- renders as a question mark box, which is worse than a plain letter.
desktop.GLYPHS = {
  fleet = "\4", -- diamond: the fleet as a whole
  devices = "\7", -- bullet: one device among many
  job = "\15", -- sun: the thing a turtle is doing
  services = "\9", -- circle: running or not
  logs = "\29", -- lines: a record
  automation = "\24", -- up arrow: something acting on its own
  operations = "\30", -- triangle: the mine
  console = "\16", -- caret: a prompt
  gps = "\10", -- ring: a beacon putting out circles
  hardware = "\254", -- filled square: a block that is plugged in
  disks = "\254", -- the same square, because 437 has no floppy
  bank = "\9", -- ring: a vault door
}

--- How many columns of icons fit, and how wide each is.
---
--- Derived rather than declared, so the same code lays out a 26-wide handheld
--- and a 51-wide monitor. Two is the floor: one column is a list, and a list is
--- what this replaced.
function desktop.grid(width)
  local tile = 11
  local gap = 1
  local columns = math.max(2, math.floor((width - 2 + gap) / (tile + gap)))
  return columns, tile
end

--- Which icon a selection index sits at, given the column count.
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

--- Exchange two cells, returning a new list.
---
--- A swap rather than an insert-and-shift. On a grid, shifting means every icon
--- after the one being moved slides to a new cell, so putting Bank next to Fleet
--- rearranges eight other things - and the person who moved one icon now has to
--- find the rest. A swap changes exactly the two cells somebody was looking at.
---
--- A copy rather than a mutation, because the result is handed to a `Value` and
--- `reactive` compares by identity: a list mutated in place is the same table it
--- was, so nothing would redraw and the icon would appear not to have moved.
function desktop.swap(layout, from, to)
  local out = {}
  for index, value in ipairs(layout) do
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
function desktop.persist(context, entries, layout)
  if context.storage == nil or context.serialise == nil then
    return false
  end
  local ids = {}
  for _, index in ipairs(layout) do
    local entry = entries[index]
    if entry then
      local manifest = entry.manifest or entry
      ids[#ids + 1] = manifest.id
    end
  end
  return context.storage.write(desktop.ORDER_PATH, context.serialise.encode(ids)) and true or false
end

--- The bar along the top: what this machine is, and how it is doing.
local function statusBar(scope, context, state)
  return scope:Row({
    Height = 1,
    Padding = { left = 1, right = 1, top = 0, bottom = 0 },
    Background = T.primary,
    Children = {
      scope:Text({
        Text = context.label or context.role or "ICOS",
        Color = T.primaryFg,
      }),
      scope:Spacer({ Grow = 1 }),
      scope:Text({
        Color = T.primaryFg,
        Text = scope:Computed(function(use)
          use(state.tick)
          -- The one number worth the space: how many services are not running.
          -- A desktop that showed a clock would be showing the only thing on a
          -- CC machine nobody needs.
          local sup = context.supervisor
          if sup == nil then
            return ""
          end
          local healthy, why = sup:healthy()
          if not healthy then
            return "! " .. tostring(why):sub(1, 24)
          end
          local waiting = 0
          for _, row in ipairs(sup:health()) do
            if row.state ~= "running" then
              waiting = waiting + 1
            end
          end
          return waiting > 0 and (waiting .. " starting") or "ok"
        end),
      }),
    },
  })
end

--- The wall of icons.
---
--- One tile per **cell**, not per app, and everything on it is bound to
--- `state.layout`. That indirection is what makes icons movable: the tiles never
--- change, the permutation under them does, and a swap is one `Value` away from
--- being drawn. Tiles built per app would have to be rebuilt to move one, which
--- means tearing down and re-mounting a subtree inside a keypress handler.
local function icons(scope, state, entries, columns, tile)
  --- Which app sits in this cell right now.
  local function appAt(use, cell)
    local entry = entries[use(state.layout)[cell]]
    if entry == nil then
      return nil
    end
    return entry.manifest or entry
  end

  -- Tiles are collected into plain lists first and turned into rows after.
  -- Building the Row as we go meant appending to `row.Children` after the node
  -- had been made, which works and reads as if it might not - and left the
  -- checker unable to prove `row` was ever assigned.
  local grouped = {}
  for cell = 1, #entries do
    local at = math.floor((cell - 1) / columns) + 1
    grouped[at] = grouped[at] or {}

    grouped[at][#grouped[at] + 1] = scope:Icon({
      Width = tile,

      -- Four rows: two of picture, one of name, one that says whether this tile
      -- is being carried. The component's default is five, which is a row of
      -- padding this screen does not have to spare - eleven apps at four columns
      -- is three rows of tiles, and a nineteen-row terminal has room for exactly
      -- that plus the bar and the hint.
      Height = 4,

      -- A picture rather than a letter. `ui/icons.lua` has existed for a while
      -- and nothing passed one, so a desktop built to show objects was showing
      -- punctuation - the exact thing its own header says it replaced.
      Sprite = scope:Computed(function(use)
        local manifest = appAt(use, cell)
        return manifest and appIcons.forApp(manifest.id) or appIcons.app
      end),

      Label = scope:Computed(function(use)
        local manifest = appAt(use, cell)
        return manifest and (manifest.name or manifest.id) or ""
      end),

      -- The cell being carried says so, because a selection highlight alone
      -- would leave "moving" and "selected" looking identical - and the arrow
      -- keys do completely different things in the two states.
      Detail = scope:Computed(function(use)
        return use(state.holding) == cell and "moving" or ""
      end),

      Selected = scope:Computed(function(use)
        return use(state.selected) == cell
      end),

      OnOpen = function()
        state.selected:set(cell)
        state.open:set(reactive.peek(state.layout)[cell])
      end,
    })
  end

  local rows = {}
  for _, tiles in ipairs(grouped) do
    rows[#rows + 1] = scope:Row({ Gap = 1, Height = 4, Children = tiles })
  end
  return rows
end

--- Whether there is room for a blank line between rows of icons.
---
--- The wall grows every time an app is added and the terminal does not, so the
--- gap is the first thing to give up. Without this the twelfth app pushed the
--- bottom row off a 19-row screen, which reads as the app not existing - the
--- worst possible way for a desktop to run out of space.
function desktop.spacing(height, count, columns)
  local rows = math.ceil(count / math.max(1, columns))
  -- The bar, the line under it, and the hint at the bottom.
  local chrome = 3
  return (height - chrome - rows * 4) >= rows and 1 or 0
end

--- Build the whole surface: wallpaper, bar, icons, and a window when one is open.
function desktop.build(scope, context, state, entries, options)
  options = options or {}
  local width = options.width or 51
  local columns, tile = desktop.grid(width)
  local gap = desktop.spacing(options.height or 19, #entries, columns)

  local children = {
    statusBar(scope, context, state),
  }
  if gap > 0 then
    children[#children + 1] = scope:Spacer({ Height = gap })
  end

  for _, row in ipairs(icons(scope, state, entries, columns, tile)) do
    children[#children + 1] = row
    if gap > 0 then
      children[#children + 1] = scope:Spacer({ Height = gap })
    end
  end

  children[#children + 1] = scope:Spacer({ Grow = 1 })
  children[#children + 1] = scope:Muted({
    Height = 1,
    Padding = { left = 1, right = 1, top = 0, bottom = 0 },

    -- The hint changes with the mode, because in move mode the arrow keys do
    -- something else entirely and a line that said "enter opens" would be
    -- telling somebody the opposite of what is about to happen.
    Text = scope:Computed(function(use)
      if use(state.holding) ~= nil then
        return "arrows place it   enter drops it"
      end
      if options.readOnly then
        return ""
      end
      return "arrows or click   enter opens   m moves"
    end),
  })

  local surface = scope:Column({
    Grow = 1,
    Background = T.background,
    Children = children,
  })

  -- The window, built once and hidden, rather than built when opened.
  --
  -- A window created on demand would mean building an app's whole binding graph
  -- inside a click handler, which is the one place a slow build is visible. This
  -- way the cost is at mount and opening is a flag.
  local windows = {}
  for index, entry in ipairs(entries) do
    local manifest = entry.manifest or entry
    windows[#windows + 1] = scope:Window({
      Title = manifest.name or manifest.id,
      Hidden = scope:Computed(function(use)
        return use(state.open) ~= index
      end),
      Children = {
        entry.mount(scope, context, {
          readOnly = options.readOnly,
          capacity = options.capacity,
          tick = state.tick,
        }),
      },
    })
  end

  local stack = { surface }
  for _, window in ipairs(windows) do
    stack[#stack + 1] = window
  end

  return scope:Box({ Grow = 1, Children = stack })
end

--- Run the desktop until the screen stops.
---
--- The `draw` that a client, a server and a turtle all supervise. It replaces
--- `shell.run`, which mounted one app and never let go of it.
function desktop.run(context, options)
  options = options or {}

  local entries = shell.available(
    options.apps or shell.apps(),
    options.role or "client",
    options.surface or "desktop"
  )
  if #entries == 0 then
    return
  end

  -- Whatever arrangement the person at this machine last left. Applied to the
  -- entries themselves rather than kept as an indirection, so a session that
  -- moves nothing carries no permutation at all.
  entries = desktop.arrange(entries, desktop.load(context))

  local scope = ui.scoped()
  local layout = {}
  for index = 1, #entries do
    layout[index] = index
  end

  local state = {
    selected = scope:Value(1),
    open = scope:Value(nil),
    tick = context.tick or scope:Value(0),

    -- Which app is in which cell. Identity until somebody moves something, and
    -- the reason every tile is bound rather than built per app.
    layout = scope:Value(layout),

    -- The cell being carried, or nil. One value, because carrying two icons is
    -- not a thing a grid can show.
    holding = scope:Value(nil),
  }

  local width, height = context.screen.size()
  local columns = desktop.grid(width)

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
      })
    end,
  })

  host.run(root, context.input, {
    clock = context.clock,
    timeout = options.timeout,
    onEvent = function(name, a, b, c)
      local KEY = require("ui.input").KEY

      --- Put the carried icon down, and remember where.
      ---
      --- Written on drop rather than on every arrow press, because each move is
      --- a real filesystem write on the host and somebody arranging a desktop
      --- presses a lot of arrows.
      local function drop()
        state.holding:set(nil)
        desktop.persist(context, entries, reactive.peek(state.layout))
      end

      --- Move the selection, carrying an icon with it when one is held.
      local function step(dx, dy)
        local count = #entries
        local from = reactive.peek(state.selected)
        local to = desktop.move(from, count, columns, dx, dy)

        if reactive.peek(state.holding) ~= nil and to ~= from then
          state.layout:set(desktop.swap(reactive.peek(state.layout), from, to))
          state.holding:set(to)
        end
        state.selected:set(to)
      end

      if name == "key" then
        local open = reactive.peek(state.open)

        -- Closing beats everything. A key that sometimes closes a window and
        -- sometimes types into it is a key nobody trusts.
        if open and (a == KEY.escape or a == KEY.backspace) then
          state.open:set(nil)
          return true
        end
        if open then
          return false
        end

        local index = reactive.peek(state.selected)
        if a == KEY.left then
          step(-1, 0)
          return true
        elseif a == KEY.right then
          step(1, 0)
          return true
        elseif a == KEY.up then
          step(0, -1)
          return true
        elseif a == KEY.down then
          step(0, 1)
          return true
        elseif a == KEY.enter then
          -- Enter drops what is being carried rather than opening it. Opening an
          -- app at the end of a move would mean the key that finishes arranging
          -- the desktop also leaves it.
          if reactive.peek(state.holding) ~= nil then
            drop()
          else
            state.open:set(reactive.peek(state.layout)[index])
          end
          return true
        elseif a == KEY.escape and reactive.peek(state.holding) ~= nil then
          drop()
          return true
        end
        return false
      end

      if name == "char" and reactive.peek(state.open) then
        if a == "q" or a == "Q" then
          state.open:set(nil)
          return true
        end
      end

      if name == "char" and not reactive.peek(state.open) then
        -- Pick an icon up, or put it down. A held modifier would be the obvious
        -- gesture and is not available: CC reports shift as an ordinary key
        -- event with no way to ask whether it is still down, so a drag would be
        -- a state machine guessing at a key it cannot observe. A mode you enter
        -- and leave is honest about that, and it says so on the tile.
        if (a == "m" or a == "M") and not options.readOnly then
          if reactive.peek(state.holding) ~= nil then
            drop()
          else
            state.holding:set(reactive.peek(state.selected))
          end
          return true
        end

        -- Numbers open directly from the desktop, which is the one habit worth
        -- keeping from the taskbar this replaced.
        local picked = tonumber(a)
        if picked and reactive.peek(state.layout)[picked] then
          state.selected:set(picked)
          state.open:set(reactive.peek(state.layout)[picked])
          return true
        end
      end

      local _ = b
      local _ = c
      return false
    end,
  })

  scope:destroy()
end

return desktop
