--- Screen port over a CC terminal, monitor, or window.
---
--- Wraps a `term`-shaped redirect object rather than the `term` API itself, so
--- the base computer's keyboard terminal and its wall monitor are two screen
--- ports over two different objects instead of one global that has to be
--- redirected back and forth. That is what lets the two desktops in
--- docs/architecture.md stop sharing a cursor.
---
--- The adapter does exactly two things the port does not describe: it moves the
--- cursor before each run, and it caches the size. Both are explained below.

local screen = require("ports.screen")

local adapter = {}

--- Palette index -> the `colors.*` value CC's own calls want.
---
--- CC's colour constants are single-bit masks: slot 0 is 1, slot 1 is 2, slot 15
--- is 32768. `term.blit` is the one call that speaks in indices, and it is also
--- the only one on the hot path - so the framework keeps indices throughout and
--- pays for the conversion here, on the two calls a frame does not make.
local COLOUR = {}
for index = 0, 15 do
  COLOUR[index] = 2 ^ index
end

--- Build a screen over `target`, defaulting to whatever `term` currently points
--- at. Pass `peripheral.wrap("monitor_0")` for a monitor.
function adapter.new(target)
  target = target or term

  local impl = {}

  --- Size is asked for, never cached.
  ---
  --- A monitor is a different shape to a computer, `monitor.setTextScale`
  --- changes it at runtime, and a `term_resize` event arrives after the fact.
  --- The old `legacy/shell/ui.lua` made the same choice for the same reason; caching
  --- here would put a stale width inside the one component that decides how
  --- many characters get written to a real screen.
  function impl.size()
    return target.getSize()
  end

  --- One positioned run.
  ---
  --- `setCursorPos` then `blit` is two calls into the game, and there is no way
  --- to make it one - `term.blit` has no position argument. Which is precisely
  --- why `ui/buffer` coalesces a changed row into a single run rather than
  --- emitting one call per changed cell: the cursor move is paid per run, so
  --- runs are the unit worth minimising.
  function impl.blit(x, y, text, fg, bg)
    target.setCursorPos(x, y)
    target.blit(text, fg, bg)
  end

  function impl.clear(bg)
    target.setBackgroundColor(COLOUR[bg] or COLOUR[15])
    target.clear()
  end

  --- False on a standard (non-advanced) computer or monitor.
  ---
  --- Worth reading carefully, because the obvious conclusion is wrong: a
  --- standard terminal still has all sixteen palette slots and still honours
  --- `setPaletteColour`. What it does is render each slot as its greyscale
  --- average. So a theme is not unavailable on standard hardware, it is
  --- flattened to luminance - which means a theme whose tokens differ in
  --- brightness as well as hue keeps working, and one built from equally bright
  --- colours turns into an unreadable smear. That is a design constraint on the
  --- palette, not a reason to branch at the call site.
  function impl.isColour()
    return target.isColor and target.isColor() or false
  end

  function impl.setPalette(index, r, g, b)
    target.setPaletteColor(COLOUR[index] or COLOUR[0], r, g, b)
  end

  --- The text caret. Separate from `blit` because it is not part of the cell
  --- grid: it belongs to whichever component has focus, survives a frame that
  --- did not repaint its row, and must be repositioned after every present or
  --- it sits wherever the last run happened to end.
  function impl.setCursor(visible, x, y, colour)
    if visible then
      target.setCursorPos(x or 1, y or 1)
      if COLOUR[colour] then
        target.setTextColor(COLOUR[colour])
      end
    end
    target.setCursorBlink(visible and true or false)
  end

  return screen.check(impl)
end

return adapter
