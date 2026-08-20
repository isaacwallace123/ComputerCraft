--- Finding a wall, and making it the right size.
---
--- A monitor's character grid depends on both its block dimensions and its text
--- scale, so hard-coding either is how a dashboard ends up clipped on somebody
--- else's wall. This says how many columns and rows the layout needs and picks
--- the **largest** scale that still fits: biggest readable text, nothing cut off,
--- whatever size the wall happens to be.
---
--- ## Why this is an adapter and not part of the screen port
---
--- `adapters/cc/screen.lua` wraps a `term`-shaped object and does not care where
--- it came from - which is exactly right, and is what lets the same page render
--- to a terminal, a monitor, or the recording screen the renderer is tested
--- through. *Choosing* the object is a different job: it reads `peripheral`,
--- compares physical walls, and has an opinion about which one a person meant.
---
--- Keeping them apart is what stops the screen port growing a dependency on
--- there being peripherals at all.
---
--- ## It is `legacy/shell/display.lua`, narrowed
---
--- The ICOS 1 file also owned `term.redirect` juggling and a notion of a
--- secondary wall, both of which existed because every ICOS 1 app drew through
--- the global terminal. ICOS 2 hands a screen port to a page, so redirection has
--- nothing to redirect and is gone. What survives is the part that was actually
--- hard: comparing walls fairly and scaling one to fit.

local screen = require("ports.screen")

local display = {}

--- Text scales CC accepts, largest first.
---
--- Largest first because the answer wanted is the biggest text that fits, not
--- the smallest that works. A wall showing a fleet at scale 0.5 is technically
--- correct and unreadable from across the room, which is the only place anybody
--- reads it from.
display.SCALES = { 5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5 }

--- Columns and rows a fleet dashboard needs.
---
--- The same numbers `startup.lua` has always asked for. Below this the Fleet
--- page starts dropping rows, which on the one screen meant to be glanced at is
--- the failure worth avoiding.
display.MIN_WIDTH = 42
display.MIN_HEIGHT = 18

--- Every monitor attached, biggest wall first.
---
--- Measured at a single scale before comparing, which is the subtle half: a
--- monitor someone previously set to scale 5 reports very few characters and
--- would look tiny beside one at 0.5, even if it is physically four times the
--- size. Setting them all to the same scale first compares walls rather than
--- settings.
function display.monitors(naturalLess)
  local names = peripheral.getNames()
  if naturalLess then
    -- `monitor_10` belongs after `monitor_9`, so a base with ten walls picks the
    -- same one on every boot rather than whichever the alphabet favoured.
    table.sort(names, naturalLess)
  else
    table.sort(names)
  end

  local entries = {}
  for _, name in ipairs(names) do
    if peripheral.hasType(name, "monitor") then
      local monitor = peripheral.wrap(name)
      if monitor then
        monitor.setTextScale(0.5)
        local width, height = monitor.getSize()
        entries[#entries + 1] = { name = name, monitor = monitor, area = width * height }
      end
    end
  end

  table.sort(entries, function(a, b)
    if a.area == b.area then
      return a.name < b.name
    end
    return a.area > b.area
  end)
  return entries
end

--- Set the largest scale at which `monitor` is still at least this big.
---
--- Falls back to 0.5 - the most characters the wall can show - when nothing
--- fits. A wall too small for the layout is a wall that shows a cramped fleet,
--- which is worth more than a blank one and is the honest thing to do with
--- hardware somebody has already built.
function display.scaleToFit(monitor, minWidth, minHeight)
  for _, scale in ipairs(display.SCALES) do
    monitor.setTextScale(scale)
    local width, height = monitor.getSize()
    if width >= minWidth and height >= minHeight then
      return scale, width, height
    end
  end

  monitor.setTextScale(0.5)
  local width, height = monitor.getSize()
  return 0.5, width, height
end

--- The wall this machine should use, as a screen port.
---
--- Returns nil when there is no monitor, which is not a fault: most machines
--- have none, and a base with none simply draws on its own terminal. Returns the
--- port, the peripheral name, and the size it settled on - the name matters
--- because touch events carry it, and a base with two walls must not act on a
--- tap meant for the other one.
function display.attach(options)
  options = options or {}
  local entries = display.monitors(options.naturalLess)
  local selected = entries[1]
  if selected == nil then
    return nil
  end

  local scale, width, height = display.scaleToFit(
    selected.monitor,
    options.minWidth or display.MIN_WIDTH,
    options.minHeight or display.MIN_HEIGHT
  )

  return screen.check(require("adapters.cc.screen").new(selected.monitor)),
    selected.name,
    { scale = scale, width = width, height = height }
end

return display
