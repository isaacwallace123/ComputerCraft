--- Body port over the `turtle` global.
---
--- A flat translation and nothing more. Every method here maps one port call to
--- one `turtle.*` call, keeps CC's `false, reason` shape intact, and decides
--- nothing.
---
--- Keeping the failure reasons is the load-bearing part. `nav` reads them to
--- tell an obstruction from a protected block from a peer, and D025 turns that
--- reading into a detour instead of an abandoned trip. Flattening them to a bare
--- `false` here would delete that behaviour a layer away from where anyone would
--- think to look for it.
---
--- Written for a later phase to lift `turtle/` onto. Nothing calls it yet.

local body = require("ports.body")

local adapter = {}

local MOVE = {
  forward = "forward",
  back = "back",
  up = "up",
  down = "down",
}

--- CC names the three workable faces by suffix: `dig`, `digUp`, `digDown`.
local FACE = {
  forward = "",
  up = "Up",
  down = "Down",
}

local function faceCall(prefix, direction, ...)
  local suffix = FACE[direction]
  if not suffix then
    return false, "no such direction: " .. tostring(direction)
  end
  return turtle[prefix .. suffix](...)
end

function adapter.new()
  local impl = {}

  function impl.move(direction)
    local name = MOVE[direction]
    if not name then
      return false, "no such direction: " .. tostring(direction)
    end
    return turtle[name]()
  end

  function impl.turn(direction)
    if direction == "left" then
      return turtle.turnLeft()
    end
    if direction == "right" then
      return turtle.turnRight()
    end
    return false, "no such turn: " .. tostring(direction)
  end

  function impl.dig(direction)
    return faceCall("dig", direction)
  end

  function impl.detect(direction)
    local ok = faceCall("detect", direction)
    return ok == true
  end

  function impl.inspect(direction)
    return faceCall("inspect", direction)
  end

  function impl.place(direction)
    return faceCall("place", direction)
  end

  function impl.drop(direction, count)
    return faceCall("drop", direction, count)
  end

  function impl.select(slot)
    return turtle.select(slot)
  end

  function impl.slot()
    return turtle.getSelectedSlot()
  end

  --- Nil for an empty slot, never an empty table. Callers branch on presence and
  --- a truthy empty table would read as "something is in there".
  function impl.stack(slot)
    return turtle.getItemDetail(slot)
  end

  function impl.fuel()
    return turtle.getFuelLevel(), turtle.getFuelLimit()
  end

  function impl.refuel(count)
    return turtle.refuel(count)
  end

  return body.check(impl)
end

return adapter
