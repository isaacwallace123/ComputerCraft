--- Branding, boot and shutdown animations.
---
--- Everything here is sized from `term.getSize()` at runtime, so the same code
--- plays on a 26x20 pocket computer, a 51x19 desktop and a monitor wall. On a
--- non-advanced machine the colours collapse to greyscale on their own, so
--- nothing needs a separate path.
---
--- Kept deliberately short. An animation you have to sit through twice is an
--- animation you end up deleting.

local ui = require("core.ui")
local sound = require("core.sound")

local boot = {}

boot.NAME = "FleetOS"
boot.VERSION = "1.0"

local function centreX(text)
  local width = term.getSize()
  return math.max(1, math.floor((width - #text) / 2) + 1)
end

--- Reveal text one character at a time with a trailing cursor.
local function typeOut(y, text, color, delay)
  local x = centreX(text)
  for i = 1, #text do
    ui.text(x, y, text:sub(1, i), color)
    if i < #text then
      ui.text(x + i, y, "_", ui.theme.dim)
    end
    sleep(delay)
  end
end

--- A bar that sweeps out from the centre.
local function sweep(y, span, color)
  local width = term.getSize()
  local from = math.max(1, math.floor((width - span) / 2) + 1)
  local mid = math.floor(span / 2)

  for step = 1, mid do
    local left = math.max(from, from + mid - step)
    local size = math.min(span, step * 2)
    ui.text(left, y, string.rep(" ", size), ui.theme.fg, color)
    sleep(0.015)
  end
end

--- The visual half of the boot sequence.
local function animate(subtitle)
  local _, height = term.getSize()
  local middle = math.max(2, math.floor(height / 2))

  ui.clear()
  typeOut(middle, boot.NAME, ui.theme.fg, 0.05)
  sweep(middle + 1, #boot.NAME + 6, ui.theme.accent)

  if subtitle then
    ui.center(middle + 3, subtitle, ui.theme.dim)
  end
  ui.center(height, "v" .. boot.VERSION, ui.theme.dim)

  sleep(0.25)
end

--- Play the boot sequence. Returns true if a key was pressed during it, which
--- callers use as "skip the automatic stuff and give me the menu".
function boot.splash(subtitle)
  local interrupted = false

  parallel.waitForAny(function()
    parallel.waitForAll(function()
      animate(subtitle)
    end, function()
      sound.play("boot")
    end)
  end, function()
    os.pullEvent("key")
    interrupted = true
  end)

  return interrupted
end

--- CRT power-off: the picture folds to a line, then a dot, then nothing.
function boot.shutdown(quiet)
  local width, height = term.getSize()
  local middle = math.floor((height + 1) / 2)

  local function paint(rows, columns)
    ui.clear()
    local from = math.max(1, math.floor((width - columns) / 2) + 1)
    for row = middle - rows, middle + rows do
      if row >= 1 and row <= height then
        ui.text(from, row, string.rep(" ", math.min(columns, width)), ui.theme.fg, ui.theme.bar)
      end
    end
  end

  local function visual()
    -- Fold vertically to a single lit line...
    for rows = middle, 0, -1 do
      paint(rows, width)
      sleep(0.02)
    end
    -- ...then pull that line in to a dot.
    for columns = width, 1, -math.max(1, math.floor(width / 12)) do
      paint(0, columns)
      sleep(0.02)
    end
    paint(0, 1)
    sleep(0.12)
    ui.clear()
  end

  if quiet then
    visual()
  else
    parallel.waitForAll(visual, function()
      sound.play("shutdown")
    end)
  end
end

--- Animate, then actually reboot.
function boot.reboot()
  boot.shutdown()
  os.reboot()
end

return boot
