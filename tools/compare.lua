--- ICOS's renderer against the dirty-rectangle approach Basalt 2 uses.
---
--- Run with `tools\compare.ps1`.
---
--- ## Why this exists
---
--- Basalt (https://github.com/Pyroxenium/Basalt2) is the established UI
--- framework for CC: Tweaked, and "we should do better than that" is worth
--- nothing as an assertion. This runs one identical dashboard workload through
--- both renderer designs and counts what each sends to the terminal.
---
--- ## What is being compared, and what is not
---
--- `basaltStyle` below is a faithful reimplementation of the algorithm in
--- Basalt 2's `src/render.lua` - its string-per-row buffer, its `addDirtyRect`
--- on every write, its single-pass overlap merge, and its one-blit-per-rect-row
--- emit. It is NOT Basalt: no element tree, no properties, no event system, and
--- none of the sixty-odd widgets Basalt ships and ICOS does not. Basalt is a
--- much larger and more finished piece of software than anything in this
--- repository.
---
--- The comparison is therefore narrow on purpose. It asks one question, which
--- happens to be the question ICOS's entire UI plan rests on: **given the same
--- painting, how much terminal traffic does each design produce?**
---
--- ## The difference in one sentence
---
--- Basalt 2's buffer records where it was *written to*; ICOS's records what
--- *changed*. Repainting a row with the text it already had costs Basalt a blit
--- and costs ICOS nothing, because ICOS compares against a front buffer and
--- Basalt has no front buffer to compare against.
---
--- That distinction is invisible until you ask what a fleet dashboard actually
--- does, which is redraw itself on every heartbeat while almost nothing about it
--- has changed.

package.path = table.concat({
  "src/?.lua",
  "tools/spec/?.lua",
  package.path,
}, ";")

local buffer = require("ui.buffer")

local HEX = "0123456789abcdef"

local function hex(index)
  return HEX:sub((index or 0) + 1, (index or 0) + 1)
end

---------------------------------------------------------------------------
-- A counting terminal, shared by both
---------------------------------------------------------------------------

local function counting(width, height)
  local state = { blits = 0, chars = 0, width = width, height = height }
  state.setCursorPos = function() end
  state.blit = function(text)
    state.blits = state.blits + 1
    state.chars = state.chars + #text
  end
  state.getSize = function()
    return state.width, state.height
  end
  -- The screen port ICOS's buffer expects, over the same counters.
  state.port = {
    size = state.getSize,
    blit = function(_, _, text)
      state.blit(text)
    end,
    clear = function() end,
    isColour = function()
      return true
    end,
    setPalette = function() end,
    setCursor = function() end,
  }
  return state
end

---------------------------------------------------------------------------
-- Basalt 2's algorithm, reimplemented
---------------------------------------------------------------------------

local basaltStyle = {}
basaltStyle.__index = basaltStyle

function basaltStyle.new(terminal, width, height)
  local self = setmetatable({
    terminal = terminal,
    width = width,
    height = height,
    text = {},
    fg = {},
    bg = {},
    rects = {},
  }, basaltStyle)
  for y = 1, height do
    self.text[y] = string.rep(" ", width)
    self.fg[y] = string.rep("0", width)
    self.bg[y] = string.rep("f", width)
  end
  return self
end

function basaltStyle:size()
  return self.width, self.height
end

--- Every write records a rectangle. Note what is missing: nothing compares the
--- new content against the old. A rect is added because a write happened, not
--- because anything is different afterwards.
function basaltStyle:addDirtyRect(x, y, width, height)
  self.rects[#self.rects + 1] = { x = x, y = y, width = width, height = height }
end

function basaltStyle:blit(x, y, text, fg, bg)
  if y < 1 or y > self.height then
    return
  end
  local sub = string.sub
  self.text[y] = sub(sub(self.text[y], 1, x - 1) .. text .. sub(self.text[y], x + #text), 1, self.width)
  self.fg[y] = sub(sub(self.fg[y], 1, x - 1) .. fg .. sub(self.fg[y], x + #fg), 1, self.width)
  self.bg[y] = sub(sub(self.bg[y], 1, x - 1) .. bg .. sub(self.bg[y], x + #bg), 1, self.width)
  self:addDirtyRect(x, y, #text, 1)
end

function basaltStyle:write(x, y, text, fg, bg)
  text = tostring(text)
  if #text == 0 then
    return
  end
  self:blit(x, y, text, string.rep(hex(fg), #text), string.rep(hex(bg), #text))
end

function basaltStyle:fill(x, y, width, height, char, fg, bg)
  local run = string.rep(tostring(char or " "):sub(1, 1), math.max(0, width))
  for row = y, y + height - 1 do
    self:write(x, row, run, fg, bg)
  end
end

--- A clear marks every row dirty, so any frame that begins by clearing its
--- background has already committed to repainting the whole surface.
function basaltStyle:clear(fg, bg)
  for y = 1, self.height do
    self.text[y] = string.rep(" ", self.width)
    self.fg[y] = string.rep(hex(fg), self.width)
    self.bg[y] = string.rep(hex(bg), self.width)
    self:addDirtyRect(1, y, self.width, 1)
  end
end

local function overlaps(a, b)
  return not (
    a.x + a.width <= b.x
    or b.x + b.width <= a.x
    or a.y + a.height <= b.y
    or b.y + b.height <= a.y
  )
end

--- Merge to the bounding box, which is where the interesting cost is: two small
--- changes that each overlap a third rectangle become one rectangle covering all
--- three, including everything between them that did not change.
local function merge(target, source)
  local x1 = math.min(target.x, source.x)
  local y1 = math.min(target.y, source.y)
  local x2 = math.max(target.x + target.width, source.x + source.width)
  local y2 = math.max(target.y + target.height, source.y + source.height)
  target.x, target.y, target.width, target.height = x1, y1, x2 - x1, y2 - y1
end

function basaltStyle:present()
  local mergedRects = {}
  for _, rect in ipairs(self.rects) do
    local didMerge = false
    for _, existing in ipairs(mergedRects) do
      if overlaps(rect, existing) then
        merge(existing, rect)
        didMerge = true
        break
      end
    end
    if not didMerge then
      mergedRects[#mergedRects + 1] = rect
    end
  end

  local blits = 0
  for _, rect in ipairs(mergedRects) do
    for y = rect.y, rect.y + rect.height - 1 do
      if y >= 1 and y <= self.height then
        self.terminal.setCursorPos(rect.x, y)
        self.terminal.blit(
          self.text[y]:sub(rect.x, rect.x + rect.width - 1),
          self.fg[y]:sub(rect.x, rect.x + rect.width - 1),
          self.bg[y]:sub(rect.x, rect.x + rect.width - 1)
        )
        blits = blits + 1
      end
    end
  end

  self.rects = {}
  return blits
end

---------------------------------------------------------------------------
-- One dashboard, painted the same way by both
---------------------------------------------------------------------------

local WHITE, BLACK, GREY, GREEN, RED = 0, 15, 7, 13, 14
local PHASES = { "mining", "returning", "unloading", "parked", "travelling" }

local function pad(text, width)
  text = tostring(text)
  if #text >= width then
    return text:sub(1, width)
  end
  return text .. string.rep(" ", width - #text)
end

local function paintFleet(frame, tick)
  local width, height = frame:size()

  frame:clear(WHITE, BLACK)
  frame:write(1, 1, pad("  ICOS  fleet", width), WHITE, GREY)
  frame:write(width - 8, 1, ("%02d:%02d:%02d"):format(12, 30, tick % 60), WHITE, GREY)
  frame:write(
    2,
    2,
    pad("id", 5) .. pad("label", 16) .. pad("phase", 12) .. pad("fuel", 8),
    GREY,
    BLACK
  )

  for row = 3, height - 1 do
    local id = row - 2
    local fuel = 51000 - id * 137 - tick
    frame:write(2, row, pad(id, 5), WHITE, BLACK)
    frame:write(7, row, pad("miner-" .. id, 16), WHITE, BLACK)
    frame:write(23, row, pad(id % 3 == 0 and "returning" or "mining", 12), GREEN, BLACK)
    frame:write(35, row, pad(fuel, 8), fuel < 800 and RED or WHITE, BLACK)
    frame:fill(45, row, math.floor((fuel % 1000) / 40), 1, " ", WHITE, GREEN)
  end

  frame:write(1, height, pad("  q quit    enter open", width), WHITE, GREY)
end

--- Only the cells that actually changed: ten heartbeats and a clock.
local function updateOnlyWhatChanged(frame, tick)
  local width = frame:size()
  frame:write(width - 8, 1, ("%02d:%02d:%02d"):format(12, 30, tick % 60), WHITE, GREY)
  for id = 1, 10 do
    local row = id + 2
    local fuel = 51000 - id * 137 - tick * 61
    frame:write(23, row, pad(PHASES[(tick + id) % #PHASES + 1], 12), GREEN, BLACK)
    frame:write(35, row, pad(fuel, 8), fuel < 800 and RED or WHITE, BLACK)
  end
end

---------------------------------------------------------------------------

local WIDTH, HEIGHT = 164, 81

local function run(build, prepare, step, frames)
  local screen = counting(WIDTH, HEIGHT)
  local frame = build(screen)

  prepare(frame)
  frame:present()
  screen.blits, screen.chars = 0, 0

  local started = os.clock()
  for tick = 1, frames do
    step(frame, tick)
    frame:present()
  end
  local elapsed = os.clock() - started

  return screen.blits / frames, screen.chars / frames, (elapsed / frames) * 1000
end

local function icos(screen)
  return buffer.new(screen.port, WIDTH, HEIGHT)
end

local function basalt(screen)
  return basaltStyle.new(screen, WIDTH, HEIGHT)
end

local CASES = {
  {
    name = "idle: no state change at all",
    note = "the frame loop ticks; nothing has moved",
    prepare = function(frame)
      paintFleet(frame, 0)
    end,
    step = function() end,
  },
  {
    name = "one label changes",
    note = "what a single heartbeat costs, tree repainted",
    prepare = function(frame)
      paintFleet(frame, 0)
    end,
    -- A property change marks the root frame dirty, so the whole visible tree
    -- redraws. This is the real cost of one changed value in a retained tree
    -- that invalidates upwards, which is what both frameworks do today.
    step = function(frame, tick)
      paintFleet(frame, 0)
      frame:write(2, 4, pad(("miner-%d"):format(tick % 9 + 1), 16), WHITE, BLACK)
    end,
  },
  {
    name = "dashboard update, 10 turtles",
    note = "only the changed cells are repainted",
    prepare = function(frame)
      paintFleet(frame, 0)
    end,
    step = updateOnlyWhatChanged,
  },
  {
    name = "page repaints itself, same result",
    note = "every app in this repository draws like this",
    prepare = function(frame)
      paintFleet(frame, 0)
    end,
    step = function(frame)
      paintFleet(frame, 0)
    end,
  },
  {
    name = "full repaint, everything differs",
    note = "the worst case, and the budget in section 12",
    prepare = function(frame)
      paintFleet(frame, 0)
    end,
    step = function(frame, tick)
      paintFleet(frame, tick)
      for row = 1, HEIGHT do
        frame:write(
          1,
          row,
          string.rep(tick % 2 == 0 and "#" or ".", WIDTH),
          WHITE,
          tick % 2 == 0 and 1 or 2
        )
      end
    end,
  },
}

print("ICOS ui/buffer versus the dirty-rectangle design in Basalt 2")
print("")
print(("  surface: %dx%d, the largest monitor that can be built"):format(WIDTH, HEIGHT))
print("  the same painting, through two renderers. lower is better.")
print("")
print(("  %-34s %20s %20s"):format("", "blit calls / frame", "characters / frame"))
print(("  %-34s %9s %10s %9s %10s"):format("case", "ICOS", "Basalt 2", "ICOS", "Basalt 2"))
print("  " .. string.rep("-", 78))

for _, case in ipairs(CASES) do
  local mineBlits, mineChars = run(icos, case.prepare, case.step, 100)
  local theirsBlits, theirsChars = run(basalt, case.prepare, case.step, 100)
  print(
    ("  %-34s %9.0f %10.0f %9.0f %10.0f"):format(
      case.name,
      mineBlits,
      theirsBlits,
      mineChars,
      theirsChars
    )
  )
  print(("  %-34s"):format("    " .. case.note))
end

---------------------------------------------------------------------------
-- The same question, one layer up
---------------------------------------------------------------------------

--- Everything above compares renderers given identical painting. This compares
--- what the two **frameworks** paint, which is where Basalt 2's advantage is
--- actually lost.
---
--- Its property system knows exactly which property changed. Then
--- `BaseElement:updateRender` walks up the parent chain and marks the root
--- frame, so the whole visible tree redraws and every one of those redraws is a
--- write and every write is a rectangle. Ours marks the node, and the frame
--- paints that node's subtree and nothing else.
---
--- The ICOS side here is the real thing - `ui/runtime.lua`, the real reactive
--- graph, the real layout solver, the real Fleet screen. The Basalt side is its
--- renderer fed the full repaint its invalidation model produces.
local ui = require("ui.init")
local fleetScreen = require("apps.fleet.view")

local function roster(fuel, phase)
  return {
    { id = 1, label = "miner-1", phase = "mining", fuel = 82000, fuelLimit = 100000, online = true },
    { id = 2, label = "miner-2", phase = phase, fuel = fuel, fuelLimit = 100000, online = true },
    { id = 3, label = "miner-3", phase = "unloading", fuel = 77000, fuelLimit = 100000, online = true },
    { id = 4, label = "miner-4", phase = "parked", fuel = 2000, fuelLimit = 100000, online = false },
    { id = 5, label = "miner-5", phase = "mining", fuel = 55000, fuelLimit = 100000, online = true },
    { id = 6, label = "miner-6", phase = "mining", fuel = 48000, fuelLimit = 100000, online = true },
  }
end

local function frameworkCase()
  local screen = counting(WIDTH, HEIGHT)
  local scope = ui.scoped()
  local devices
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      devices = s:Value(roster(31000, "returning"))
      return fleetScreen.build(s, {
        devices = devices,
        selected = s:Value(nil),
        capacity = 60,
        onDeploy = function() end,
      })
    end,
  })
  root:render()
  screen.blits, screen.chars = 0, 0

  -- One heartbeat: one turtle burns fuel and changes phase. Everything else on
  -- the page recomputes to exactly the string it already held.
  devices:set(roster(30000, "mining"))
  root:render()
  local mine = screen.blits

  root:destroy()
  return mine
end

--- What the same heartbeat costs when one property change invalidates the root.
local function rootInvalidationCase()
  local screen = counting(WIDTH, HEIGHT)
  local frame = basaltStyle.new(screen, WIDTH, HEIGHT)
  paintFleet(frame, 0)
  frame:present()
  screen.blits, screen.chars = 0, 0

  -- The whole tree redraws, so every element writes, so every write is a rect.
  paintFleet(frame, 0)
  frame:write(35, 4, pad(30000, 8), WHITE, BLACK)
  frame:present()
  return screen.blits
end

print("")
print("  through the whole framework, not just the renderer")
print("  one heartbeat: one turtle changes fuel and phase, on a full page")
print("")
print(("    ICOS      %3d blits   node marked, subtree painted"):format(frameworkCase()))
print(("    Basalt 2  %3d blits   root marked, whole tree painted"):format(rootInvalidationCase()))

print("")
print("  Basalt 2 is reimplemented from its published src/render.lua: a string")
print("  buffer per row, a dirty rectangle recorded on every write, a single-pass")
print("  overlap merge to bounding boxes, one blit per row of each rectangle.")
print("  It is the renderer only - not the element tree, the properties, the")
print("  event system, or the sixty widgets Basalt ships and ICOS does not.")
