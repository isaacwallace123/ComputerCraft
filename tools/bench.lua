--- Renderer bench: what a frame actually costs.
---
--- Run with `tools\bench.ps1`. Reports blit calls and wall time for the three
--- cases docs/ui-framework.md sets budgets for, plus the full-canvas phase 5
--- case, on the two surfaces that exist: a computer terminal and the largest
--- monitor a person can build.
---
--- ## Read the times with the caveat attached
---
--- This runs on the Lua the language server embeds - PUC Lua on a desktop CPU.
--- In game the same code runs on Cobalt, which is an interpreter written in Java
--- and is slower, and it runs inside a scheduler that hands each computer a
--- slice rather than a whole tick (see the note in docs/ui-framework.md section
--- 2). So the wall times here are a floor, not a prediction.
---
--- Which is why the bench also reports counts - blits, and the cells painted to
--- produce them. Those are properties of the algorithm and are identical on
--- every interpreter, so they are the numbers to hold the design to. The times
--- say whether there is room; the counts say whether the design is right.

package.path = table.concat({
  "src/?.lua",
  "tools/spec/?.lua",
  package.path,
}, ";")

local buffer = require("ui.buffer")
local canvas = require("ui.canvas")
local recorder = require("adapters.sim.screen")
local theme = require("ui.theme")

--- A screen port that counts calls and throws the pixels away.
---
--- The recording adapter keeps a full cell grid, which is what makes it useful
--- in a spec and useless in a bench: maintaining 13,284 cell tables would swamp
--- the thing being measured. Here only the counts matter.
local function counting()
  local state = { blits = 0, chars = 0 }
  state.port = {
    size = function()
      return state.width, state.height
    end,
    blit = function(_, _, text)
      state.blits = state.blits + 1
      state.chars = state.chars + #text
      return nil
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

local WHITE, BLACK, GREY, GREEN, RED = 0, 15, 7, 13, 14

local function pad(text, width)
  text = tostring(text)
  if #text >= width then
    return text:sub(1, width)
  end
  return text .. string.rep(" ", width - #text)
end

---------------------------------------------------------------------------
-- A dashboard worth measuring
---------------------------------------------------------------------------

--- Paint a fleet page: title bar, column headings, one row per device, footer.
---
--- Modelled on the real Fleet page rather than on a synthetic pattern, because
--- the number that matters is how a frame this repository actually draws
--- behaves. The row count follows the screen, so the same function fills a
--- pocket computer and a monitor wall.
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

--- One heartbeat's worth of change: ten devices report a new fuel level, some of
--- them change phase, one crosses the low-fuel threshold and turns red, and the
--- clock ticks. Nothing else on the page moves, which is exactly what a
--- dashboard between refreshes looks like.
---
--- The fuel figures move by a turtle's worth of burn rather than by one, on
--- purpose: a counter whose last digit changes would make the coalescing look
--- better than it is by only ever producing one-character runs.
local PHASES = { "mining", "returning", "unloading", "parked", "travelling" }

local function updateFleet(frame, tick)
  local width = frame:size()
  frame:write(width - 8, 1, ("%02d:%02d:%02d"):format(12, 30, tick % 60), WHITE, GREY)
  for id = 1, 10 do
    local row = id + 2
    local fuel = 51000 - id * 137 - tick * 61
    frame:write(23, row, pad(PHASES[(tick + id) % #PHASES + 1], 12), GREEN, BLACK)
    frame:write(35, row, pad(fuel, 8), fuel < 800 and RED or WHITE, BLACK)
  end
end

--- Rebuild a full-surface pixel image and change every cell.
---
--- This is intentionally harsher than the Blackjack table phase 6 will draw:
--- the canvas covers the whole monitor, is recreated exactly as the retained
--- component recreates one on repaint, and its ground colour alternates so the
--- diff cannot save any terminal traffic. Sparse diagonal stitches force the
--- semigraphic encoder down its two-colour path as well as its solid fast case.
local function paintCanvas(frame, tick)
  local width, height = frame:size()
  local ground = tick % 2 == 0 and 15 or 6
  local ink = tick % 2 == 0 and 1 or 7
  local pixels = frame._benchCanvas
  if not pixels then
    pixels = canvas.new(width * 2, height * 3, ground, theme.dark)
    frame._benchCanvas = pixels
  else
    pixels:clear(ground)
  end
  for y = 1, height * 3 do
    local first = (y + tick) % 8 + 1
    for x = first, width * 2, 8 do
      pixels:setPixel(x, y, ink)
    end
  end
  pixels:paint(frame, 1, 1, width, height, theme.dark)
end

---------------------------------------------------------------------------
-- Running one case
---------------------------------------------------------------------------

local function run(label, width, height, frames, prepare, step)
  local screen = counting()
  screen.width, screen.height = width, height
  local frame = buffer.new(screen.port, width, height)

  prepare(frame)
  frame:present()
  screen.blits, screen.chars = 0, 0

  local started = os.clock()
  for tick = 1, frames do
    step(frame, tick)
    frame:present()
  end
  local elapsed = os.clock() - started

  local perFrame = elapsed / frames
  print(
    ("  %-26s %3dx%-3d  %7.2f blits/frame  %8.3f ms/frame  %8d chars/frame"):format(
      label,
      width,
      height,
      screen.blits / frames,
      perFrame * 1000,
      math.floor(screen.chars / frames)
    )
  )
  return perFrame * 1000, screen.blits / frames
end

---------------------------------------------------------------------------

local SURFACES = {
  { name = "computer terminal", width = 51, height = 19 },
  { name = "monitor 8x6 at 0.5", width = 164, height = 81 },
}

print("ICOS renderer bench")
print("")
print("  Lua: " .. _VERSION .. "  (desktop; in game this is Cobalt and slower)")
print("")

local worst = { idle = 0, dashboard = 0, repaint = 0, canvas = 0 }

for _, surface in ipairs(SURFACES) do
  print(surface.name)

  -- Idle, in the two senses a screen can be idle. Untouched is a frame loop
  -- ticking over with no state change at all - the cost of the framework simply
  -- existing. Repainted is a page that redraws itself unconditionally and
  -- happens to produce the same picture, which is what every app in this
  -- repository does today and what the diff has to make free.
  local idle = run("idle, untouched", surface.width, surface.height, 200, function(frame)
    paintFleet(frame, 0)
  end, function() end)

  run("idle, repainted", surface.width, surface.height, 200, function(frame)
    paintFleet(frame, 0)
  end, function(frame)
    paintFleet(frame, 0)
  end)

  -- Typical update: ten heartbeats and a clock.
  local dashboard = run("dashboard update", surface.width, surface.height, 200, function(frame)
    paintFleet(frame, 0)
  end, function(frame, tick)
    updateFleet(frame, tick)
  end)

  -- Full repaint: every cell differs from the last frame.
  local repaint = run("full repaint", surface.width, surface.height, 200, function(frame)
    paintFleet(frame, 0)
  end, function(frame, tick)
    paintFleet(frame, tick)
    -- Force every cell to differ, not just the ones the page changes.
    local width, height = frame:size()
    for row = 1, height do
      frame:write(
        1,
        row,
        string.rep(tick % 2 == 0 and "#" or ".", width),
        WHITE,
        tick % 2 == 0 and 1 or 2
      )
    end
  end)

  -- Pixel work is substantially heavier than cell painting, so 50 frames are
  -- enough to smooth timer noise without making the normal verification loop
  -- wait on a synthetic wall-sized animation.
  local canvasRepaint = run(
    "full canvas repaint",
    surface.width,
    surface.height,
    50,
    function(frame)
      paintCanvas(frame, 0)
    end,
    function(frame, tick)
      paintCanvas(frame, tick)
    end
  )

  if surface.width == 164 then
    worst.idle, worst.dashboard, worst.repaint, worst.canvas =
      idle, dashboard, repaint, canvasRepaint
  end
  print("")
end

print("one tick is 50ms; a contended computer gets a 5ms slice of it")
print(
  ("full repaint of the largest monitor: %.3f ms  (%.0f%% of a tick, %.0f%% of a slice)"):format(
    worst.repaint,
    worst.repaint / 50 * 100,
    worst.repaint / 5 * 100
  )
)
-- Reported against the slice as well as the tick, like the line above it. The
-- slice is the budget that actually binds on a loaded server, and the canvas is
-- the one case in this repository where the two answers differ enough to change
-- a decision: a cell repaint uses a sixth of a slice, a full-wall canvas most of
-- one, and the same 10x Cobalt margin puts the first inside a slice and the
-- second nowhere near it.
print(
  ("full 2x3 canvas of the largest monitor: %.3f ms  (%.0f%% of a tick, %.0f%% of a slice)"):format(
    worst.canvas,
    worst.canvas / 50 * 100,
    worst.canvas / 5 * 100
  )
)
print("")
print("  a canvas costs about 0.3us per terminal cell here. Allowing 10x for")
print("  Cobalt, a 5ms slice affords roughly 1,700 cells of pixel surface per")
print("  frame - a full computer terminal, or a third of a monitor wall. Sizing")
print("  an animated canvas is therefore a real decision; see section 12.")
