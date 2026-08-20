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
--- ## The state is two values
---
--- Which icon is selected, and which app is open. Everything else on screen is
--- derived from those two and the machine's tick, so there is no arrangement of
--- them that can disagree with what is drawn.

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
local function icons(scope, state, entries, columns, tile)
  -- Tiles are collected into plain lists first and turned into rows after.
  -- Building the Row as we go meant appending to `row.Children` after the node
  -- had been made, which works and reads as if it might not - and left the
  -- checker unable to prove `row` was ever assigned.
  local grouped = {}
  for index, entry in ipairs(entries) do
    local at = math.floor((index - 1) / columns) + 1
    grouped[at] = grouped[at] or {}

    local manifest = entry.manifest or entry
    grouped[at][#grouped[at] + 1] = scope:Icon({
      Width = tile,
      Glyph = desktop.GLYPHS[manifest.id] or "\7",
      Label = manifest.name or manifest.id,
      Selected = scope:Computed(function(use)
        return use(state.selected) == index
      end),
      OnOpen = function()
        state.selected:set(index)
        state.open:set(index)
      end,
    })
  end

  local rows = {}
  for _, tiles in ipairs(grouped) do
    rows[#rows + 1] = scope:Row({ Gap = 1, Height = 4, Children = tiles })
  end
  return rows
end

--- Build the whole surface: wallpaper, bar, icons, and a window when one is open.
function desktop.build(scope, context, state, entries, options)
  options = options or {}
  local width = options.width or 51
  local columns, tile = desktop.grid(width)

  local children = {
    statusBar(scope, context, state),
    scope:Spacer({ Height = 1 }),
  }

  for _, row in ipairs(icons(scope, state, entries, columns, tile)) do
    children[#children + 1] = row
    children[#children + 1] = scope:Spacer({ Height = 1 })
  end

  children[#children + 1] = scope:Spacer({ Grow = 1 })
  children[#children + 1] = scope:Muted({
    Height = 1,
    Padding = { left = 1, right = 1, top = 0, bottom = 0 },
    Text = "arrows or click   enter opens",
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

  local scope = ui.scoped()
  local state = {
    selected = scope:Value(1),
    open = scope:Value(nil),
    tick = context.tick or scope:Value(0),
  }

  local width = select(1, context.screen.size())
  local columns = desktop.grid(width)

  local root = host.mount({
    screen = context.screen,
    scope = scope,
    palette = options.palette,
    build = function(inner)
      return desktop.build(inner, context, state, entries, {
        width = width,
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

        local count = #entries
        local index = reactive.peek(state.selected)
        if a == KEY.left then
          state.selected:set(desktop.move(index, count, columns, -1, 0))
          return true
        elseif a == KEY.right then
          state.selected:set(desktop.move(index, count, columns, 1, 0))
          return true
        elseif a == KEY.up then
          state.selected:set(desktop.move(index, count, columns, 0, -1))
          return true
        elseif a == KEY.down then
          state.selected:set(desktop.move(index, count, columns, 0, 1))
          return true
        elseif a == KEY.enter then
          state.open:set(index)
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

      -- Numbers open directly from the desktop, which is the one habit worth
      -- keeping from the taskbar this replaced.
      if name == "char" and not reactive.peek(state.open) then
        local picked = tonumber(a)
        if picked and entries[picked] then
          state.selected:set(picked)
          state.open:set(picked)
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
