--- Declaring where the fleet unloads.
---
--- ## The list existed and nothing could add to it
---
--- `domain/depot/list.lua` has had priorities, full-detection, item filters and
--- reordering since ICOS 1. What it never had was a way in: the server allocated
--- an empty list at boot, no message could change it, and no page drew it - so
--- every base ran with zero declared drop-offs forever, and the whole mechanism
--- was dead code that looked like a feature.
---
--- This is the missing half. Four actions, each one a thing somebody standing at
--- a base wants to do to a chest.
---
--- ## Why more than one, and why they are ordered
---
--- A single chest fills. When it does, a turtle holding a full inventory has
--- nowhere to put it and the correct behaviour - stop and wait - looks exactly
--- like a turtle that has crashed. With a list, `list.usable` walks it in order
--- and hands back the first that is enabled, not full, and accepts what is being
--- carried, so the fleet routes around a full chest without anybody noticing.
---
--- Order is priority, which is why `move` exists: the nearest chest should be
--- tried first, and only the person who built the room knows which that is.
---
--- ## Positions are absolute, and this is not negotiable
---
--- A drop-off is a place in the world. Every turtle has a different idea of
--- where its own home is, so a depot recorded relative to anything would be a
--- different chest for each machine that read it. `list.add` already refuses a
--- position it cannot read as three numbers; this refuses to build one out of
--- nothing.

local depotList = require("domain.depot.list")
local persist = require("os.server.services.persist")

local depots = {}

--- The message kind this answers.
depots.KIND = "depot"

--- Where the list lives in server state, and in `server.PATHS`.
depots.SECTION = "depots"

--- Answer one depot message.
---
--- Every reply carries the whole list rather than the one record that changed.
--- A page that had to merge a delta into what it was already showing is a page
--- that can disagree with the server about what exists, and the list is short
--- enough that sending all of it costs less than being wrong about it.
function depots.handle(context, _sender, message)
  if type(message) ~= "table" or message.kind ~= depots.KIND then
    return nil
  end
  if type(message.body) ~= "table" then
    return nil
  end

  local state = context.state[depots.SECTION]
  if state == nil then
    return { kind = "depot_result", ok = false, reason = "this machine keeps no depot list" }
  end

  local body = message.body
  local action = body.action

  if action == "add" then
    return depots.add(context, state, body)
  end

  if action == "remove" then
    return depots.change(context, state, depotList.remove(state, body.id) ~= nil, "no such depot")
  end

  if action == "move" then
    local delta = tonumber(body.delta) or 0

    -- `== true`, not `~= nil`. `list.move` answers a boolean and `false ~= nil`
    -- is true, so the obvious test reported success for a depot that does not
    -- exist - and for one already at the end of the list, which is the case it
    -- returns false for on purpose. Every sibling here returns a record or nil;
    -- this one does not, and that asymmetry is exactly the kind a spec catches
    -- and a read-through does not.
    return depots.change(
      context,
      state,
      depotList.move(state, body.id, delta) == true,
      "no such depot"
    )
  end

  if action == "enable" then
    local wanted = body.enabled ~= false
    return depots.change(
      context,
      state,
      depotList.enable(state, body.id, wanted) ~= nil,
      "no such depot"
    )
  end

  if action == "list" then
    return depots.reply(state, true, nil)
  end

  return { kind = "depot_result", ok = false, reason = "no such action: " .. tostring(action) }
end

--- Record a new drop-off.
---
--- The position is refused rather than defaulted. A depot at `0, 0, 0` is a
--- place in the world that almost certainly has no chest in it, and a turtle
--- sent there would fly the length of the map to find out - which is a long way
--- to travel to learn that somebody left a field blank.
function depots.add(context, state, body)
  -- Refusals carry the list too. A page that got a reply with no `depots` field
  -- would have to decide whether that meant "unchanged" or "empty", and one of
  -- those readings clears the list on screen for a typo.
  local position = body.position
  if type(position) ~= "table" then
    return depots.reply(state, false, "a depot needs a position")
  end

  local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
  if x == nil or y == nil or z == nil then
    return depots.reply(state, false, "a position needs x, y and z")
  end

  -- `list.add` raises on a bad position and this has already checked for one,
  -- but it is wrapped anyway: it is the only call here that can throw, and a
  -- server that died because somebody typed into a stepper would be a worse
  -- outcome than any refusal it could return.
  local ok, record = pcall(depotList.add, state, {
    label = body.label,
    position = { x = x, y = y, z = z },
    accepts = body.accepts,
  })

  if not ok then
    return depots.reply(state, false, tostring(record))
  end

  persist.mark(context, depots.SECTION)
  return depots.reply(state, true, nil, record.id)
end

--- Apply a change that either worked or did not, and reply with the list.
function depots.change(context, state, worked, reason)
  if not worked then
    return depots.reply(state, false, reason)
  end
  persist.mark(context, depots.SECTION)
  return depots.reply(state, true, nil)
end

function depots.reply(state, ok, reason, id)
  return {
    kind = "depot_result",
    ok = ok,
    reason = reason,
    id = id,
    depots = state.depots,
  }
end

return depots
