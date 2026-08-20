--- One event model over CC's nine, and the tree walks that route them.
---
--- Pure functions over a laid-out tree and a raw event. No state, no screen, no
--- runtime - which is why every routing rule below is a unit test rather than
--- something inferred from clicking around on a monitor.
---
--- ## A monitor touch is a whole tap
---
--- The most important thing this file knows. CC gives a computer terminal
--- `mouse_click`, `mouse_up`, `mouse_drag` and `mouse_scroll`; it gives a
--- monitor exactly one event, `monitor_touch`, with no release, no drag, and no
--- hover ever. So a touch is normalised into a press **and** a release at the
--- same point, and nothing above here may assume that a release follows a press
--- after some interesting interval, or that a drag is possible.
---
--- That is not a detail. The fleet dashboard's whole reason to exist is a wall
--- monitor, and D020 makes the input capability of a surface a safety boundary.
--- A component whose behaviour needs a hover or a press-and-hold simply does not
--- work on the surface it was built for, which is why section 9 of
--- docs/ui-framework.md omits long-press deliberately rather than as an
--- oversight.
---
--- ## Events are normalised, never passed through raw
---
--- A component sees `{ kind = "pointer", phase = "down", x, y }` whether that
--- came from a mouse or a finger. Anything unrecognised becomes
--- `{ kind = "other", name = ... }` and is offered to the tree unchanged, which
--- is how an app receives `icos_open_app`, a rednet message, or a timer without
--- the framework needing to know those exist.

local input = {}

--- CC's mouse buttons. Named because `2` appearing in a hit test would be
--- unreadable, and because a monitor touch has to report something.
input.LEFT = 1
input.RIGHT = 2
input.MIDDLE = 3

--- The handful of key codes the framework itself acts on.
---
--- Written out rather than read from CC's `keys` table, because `ui/` may not
--- reference a CC global and `tools\check.ps1` enforces that. The values are
--- GLFW codes, copied from `rom/apis/keys.lua` at CC: Tweaked v1.20.1-1.113.1,
--- which is the build this fleet runs.
---
--- CC's own header says these "are not guaranteed to remain the same between
--- versions" - they changed once already, when CC moved from LWJGL to GLFW. So
--- this table is a version dependency and should be re-checked against the
--- source on a major CC upgrade. It is small on purpose: everything else a
--- screen wants to bind is passed through to it as a number, and only the keys
--- the framework *itself* consumes need naming here.
input.KEY = {
  space = 32,
  escape = 256,
  enter = 257,
  tab = 258,
  backspace = 259,
  delete = 261,
  right = 262,
  left = 263,
  down = 264,
  up = 265,
  pageUp = 266,
  pageDown = 267,
  home = 268,
  ["end"] = 269,
  leftShift = 340,
  rightShift = 344,
  numpadEnter = 335,
}

---------------------------------------------------------------------------
-- Normalising
---------------------------------------------------------------------------

--- Turn a raw CC event into the framework's shape.
---
--- Returns a list, not a single event, because one raw event can be two: a
--- monitor touch is a press and a release. Callers dispatch each in order.
function input.normalise(name, a, b, c)
  if name == "mouse_click" then
    return { { kind = "pointer", phase = "down", button = a, x = b, y = c } }
  end
  if name == "mouse_up" then
    return { { kind = "pointer", phase = "up", button = a, x = b, y = c } }
  end
  if name == "mouse_drag" then
    return { { kind = "pointer", phase = "drag", button = a, x = b, y = c } }
  end
  if name == "mouse_scroll" then
    -- CC reports -1 for up and 1 for down. Kept as-is rather than inverted so
    -- that `delta` means the same thing here as it does in the event a person
    -- would look up in the CC documentation while debugging.
    return { { kind = "pointer", phase = "scroll", delta = a, x = b, y = c } }
  end
  if name == "monitor_touch" then
    return {
      {
        kind = "pointer",
        phase = "down",
        button = input.LEFT,
        x = b,
        y = c,
        touch = true,
        surface = a,
      },
      {
        kind = "pointer",
        phase = "up",
        button = input.LEFT,
        x = b,
        y = c,
        touch = true,
        surface = a,
      },
    }
  end
  if name == "key" then
    return { { kind = "key", key = a, held = b == true, down = true } }
  end
  if name == "key_up" then
    return { { kind = "key", key = a, down = false } }
  end
  if name == "char" then
    return { { kind = "char", char = a } }
  end
  if name == "paste" then
    return { { kind = "paste", text = a } }
  end
  if name == "term_resize" or name == "monitor_resize" then
    return { { kind = "resize", surface = a } }
  end
  -- Everything else, carried through with its arguments intact so a screen can
  -- act on a rednet message or an ICOS app event without the framework needing
  -- to have heard of it. `args` rather than array slots on the event itself,
  -- because a mixed table is a trap during iteration.
  return { { kind = "other", name = name, args = { a, b, c } } }
end

---------------------------------------------------------------------------
-- Hit testing
---------------------------------------------------------------------------

local function within(node, x, y)
  local left, top = node._x or 1, node._y or 1
  return x >= left and x < left + (node._w or 0) and y >= top and y < top + (node._h or 0)
end

--- The deepest, topmost node containing a point.
---
--- Children are tested in reverse order because that is the reverse of the paint
--- order: a later sibling is painted over an earlier one, so it is the one a
--- person sees and therefore the one they meant to press. Getting this backwards
--- produces a UI where overlapping things respond from underneath, which reads
--- as random rather than as a rule.
---
--- `Hidden` nodes are skipped entirely. A node with a zero-size box is skipped
--- by `within`, which is what makes a column squeezed off a pocket computer
--- unclickable rather than clickable at a width of nothing.
function input.hit(node, x, y)
  if not node or node.Hidden then
    return nil
  end
  if not within(node, x, y) then
    return nil
  end

  local children = node.Children
  if children then
    for index = #children, 1, -1 do
      local found = input.hit(children[index], x, y)
      if found then
        return found
      end
    end
  end

  return node
end

--- Walk up from a node looking for one that handles `property`.
---
--- Bubbling, and it is what lets a `Row` be clickable while the `Text` inside it
--- is the thing actually under the cursor. Without it every leaf would have to
--- forward events its author never thought about.
function input.bubble(node, property)
  local current = node
  while current do
    if current[property] then
      return current
    end
    current = current._parent
  end
  return nil
end

---------------------------------------------------------------------------
-- Focus
---------------------------------------------------------------------------

--- Every focusable node, in tree order.
---
--- Tree order rather than reading order: the tab ring follows the structure a
--- person wrote, so moving a button in the source moves it in the ring. Deriving
--- the order from screen position instead would look correct on a simple form
--- and scramble on anything with two columns.
function input.focusables(node, into)
  into = into or {}
  if not node or node.Hidden then
    return into
  end
  if node.Focusable and not node.Disabled then
    into[#into + 1] = node
  end
  for _, child in ipairs(node.Children or {}) do
    input.focusables(child, into)
  end
  return into
end

--- The node `step` places along the ring from `current`, wrapping.
---
--- Wrapping rather than stopping at the ends, because a person tabbing through a
--- five-control page should not have to know which end they are at - and on a
--- pocket computer with no shift key, forward-only wrapping is the only way to
--- reach the control you have just passed.
function input.nextFocus(ring, current, step)
  if #ring == 0 then
    return nil
  end
  step = step or 1

  local index = 0
  for position, node in ipairs(ring) do
    if node == current then
      index = position
      break
    end
  end

  if index == 0 then
    return step > 0 and ring[1] or ring[#ring]
  end
  return ring[(index - 1 + step) % #ring + 1]
end

return input
