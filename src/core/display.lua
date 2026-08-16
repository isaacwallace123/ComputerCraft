--- Monitor attachment and automatic text scaling.
---
--- Monitor character size depends on both the block layout and the text scale,
--- so hardcoding either is how dashboards end up clipped on someone else's
--- wall. Instead, say how many columns and rows your layout needs and this
--- picks the LARGEST scale that still fits - biggest readable text, nothing cut
--- off, whatever size the wall happens to be.

local display = {}

-- Valid scales are multiples of 0.5 from 0.5 to 5. Largest first: we want the
-- biggest text that fits, not the smallest that works.
local SCALES = { 5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5 }

--- Find a monitor and scale it to fit a layout at least `minWidth` x
--- `minHeight` characters. Returns monitor, scale, width, height - or nil if
--- there is no monitor attached.
function display.attach(minWidth, minHeight)
  local monitor = peripheral.find("monitor")
  if not monitor then
    return nil
  end

  for _, scale in ipairs(SCALES) do
    monitor.setTextScale(scale)
    local width, height = monitor.getSize()
    if width >= minWidth and height >= minHeight then
      return monitor, scale, width, height
    end
  end

  -- Nothing fits: use the densest scale so the layout degrades rather than
  -- disappears. Callers already drop columns as width shrinks.
  monitor.setTextScale(0.5)
  local width, height = monitor.getSize()
  return monitor, 0.5, width, height
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
  return { peripheral.find("monitor") }
end

return display
