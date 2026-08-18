--- Monitor attachment and automatic text scaling.
---
--- Monitor character size depends on both the block layout and the text scale,
--- so hardcoding either is how dashboards end up clipped on someone else's
--- wall. Instead, say how many columns and rows your layout needs and this
--- picks the LARGEST scale that still fits - biggest readable text, nothing cut
--- off, whatever size the wall happens to be.

local util = require("lib.util")

local display = {}
local primaryName = nil

-- Valid scales are multiples of 0.5 from 0.5 to 5. Largest first: we want the
-- biggest text that fits, not the smallest that works.
local SCALES = { 5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5 }

local function monitorEntries(excludedName)
  local names = peripheral.getNames()
  -- monitor_10 belongs after monitor_9, so a fleet with ten walls picks the same
  -- one every boot rather than whichever the alphabet happened to favour.
  table.sort(names, util.naturalLess)
  local entries = {}
  for _, name in ipairs(names) do
    if name ~= excludedName and peripheral.getType(name) == "monitor" then
      local monitor = peripheral.wrap(name)
      if monitor then
        -- Compare every wall at the same scale, otherwise the monitor with the
        -- smallest current text can look physically larger than it really is.
        monitor.setTextScale(0.5)
        local width, height = monitor.getSize()
        entries[#entries + 1] = {
          name = name,
          monitor = monitor,
          area = width * height,
        }
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.area == b.area then
      return util.naturalLess(a.name, b.name)
    end
    return a.area > b.area
  end)
  return entries
end

local function scaleToFit(monitor, minWidth, minHeight)
  for _, scale in ipairs(SCALES) do
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

--- Pick the physically largest monitor as the primary dashboard and scale it to
--- fit the requested layout. The peripheral name is returned as the fifth
--- value so touch events can be routed to the correct wall.
function display.attach(minWidth, minHeight)
  local entries = monitorEntries()
  if not entries[1] then
    primaryName = nil
    return nil
  end

  local selected = entries[1]
  primaryName = selected.name
  local scale, width, height = scaleToFit(selected.monitor, minWidth, minHeight)
  return selected.monitor, scale, width, height, selected.name
end

--- Largest monitor not being used by the dashboard. Fleet uses this for its haul
--- wall. Re-running it also handles a newly attached or replaced monitor.
function display.secondary(minWidth, minHeight)
  local entries = monitorEntries(primaryName)
  if not entries[1] then
    return nil
  end

  local selected = entries[1]
  local scale, width, height = scaleToFit(selected.monitor, minWidth, minHeight)
  return selected.monitor, scale, width, height, selected.name
end

function display.primaryName()
  return primaryName
end

function display.isAttached(name)
  return name ~= nil and peripheral.isPresent(name) and peripheral.getType(name) == "monitor"
end

--- Run `fn` with output redirected to `target`, restoring afterwards even if it
--- throws. Returns whatever fn returned, or re-raises.
function display.on(target, fn)
  local previous = term.redirect(target)
  local ok, result = pcall(fn)
  term.redirect(previous)
  if not ok then
    error(result, 0)
  end
  return result
end

--- Every monitor attached, for multi-wall setups.
function display.all()
  local monitors = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      monitors[#monitors + 1] = peripheral.wrap(name)
    end
  end
  return monitors
end

return display
