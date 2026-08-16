--- pulse.lua - configurable redstone clock.
---
--- Emits a repeating on/off redstone signal. Useful long before you own any
--- peripherals: bone-meal dispensers, item-dropper farms, a Create clutch,
--- flint-and-steel cobble gens, an automated lamp on a day cycle.
---
--- Unlike a repeater loop this one has an exact, editable period and stops
--- cleanly - no dropped items or chunk-loaded lag machine.
---
--- Press Q to stop, Ctrl+T to terminate.

local ui = require("lib.ui")
local config = require("lib.config")

local CONFIG_PATH = ".pulse"

local defaults = {
  side = "top",
  onSeconds = 0.5, -- minimum meaningful value is 0.05 (one tick)
  offSeconds = 3.0,
}

local cfg = config.load(CONFIG_PATH, defaults)
config.save(CONFIG_PATH, cfg) -- write the file on first run so it is easy to edit

local state = { pulses = 0, on = false, startedAt = os.clock() }

--- Format a duration in seconds as e.g. "1h 04m 09s".
local function elapsed()
  local total = math.floor(os.clock() - state.startedAt)
  return string.format("%dh %02dm %02ds", total / 3600, (total % 3600) / 60, total % 60)
end

local function draw()
  ui.header("Redstone Pulse")
  ui.center(4, state.on and "[ ON  ]" or "[ off ]", colors.white)
  term.setTextColor(colors.lightGray)
  term.setCursorPos(3, 7)
  term.write("side    " .. cfg.side)
  term.setCursorPos(3, 8)
  term.write("period  " .. cfg.onSeconds .. "s on / " .. cfg.offSeconds .. "s off")
  term.setCursorPos(3, 10)
  term.write("pulses  " .. state.pulses)
  term.setCursorPos(3, 11)
  term.write("uptime  " .. elapsed())
  ui.footer("Q to stop")
end

--- The clock itself. Runs forever; parallel handles the exit.
local function run()
  while true do
    state.on = true
    redstone.setOutput(cfg.side, true)
    state.pulses = state.pulses + 1
    draw()
    sleep(cfg.onSeconds)

    state.on = false
    redstone.setOutput(cfg.side, false)
    draw()
    sleep(cfg.offSeconds)
  end
end

--- Redraw once a second so "uptime" ticks even during a long off phase.
local function refresh()
  while true do
    sleep(1)
    draw()
  end
end

local function waitForQuit()
  while true do
    local _, key = os.pullEvent("key")
    if key == keys.q then
      return
    end
  end
end

parallel.waitForAny(run, refresh, waitForQuit)

redstone.setOutput(cfg.side, false)
ui.clear()
print("Pulse stopped after " .. state.pulses .. " pulses (" .. elapsed() .. ").")
print("Edit " .. CONFIG_PATH .. " to change the side or timing.")
