--- The device registry: who exists, what they were doing, and where they were.
---
--- Phase 2 of docs/icos-2.md, and the answer to the second of the four failures
--- in §1: *"Three miners vanished and nothing knew where — position is broadcast
--- and discarded."*
---
--- ## The bug this exists to fix
---
--- `fleet/roster.lua` does record every heartbeat, and it does persist them. What
--- it does is replace the whole record:
---
---     devices[key] = { snap = snapshot, lastSeen = now, pairedAt = ... }
---
--- A turtle's snapshot carries `world` only while it has an origin. Reboot one
--- underground, or deploy a build that has never been given its position, and it
--- reports `world = nil` — at which point the base **overwrites the last position
--- it knew with nothing.** The information was there, it arrived, and the next
--- message destroyed it.
---
--- So the location is kept apart from the snapshot and only ever replaced by
--- another location. A device that stops knowing where it is does not make the
--- fleet stop knowing where it was.
---
--- ## Pure, and staying that way
---
--- No `os.epoch`, no `core/config`, no CC global. `now` is a parameter and
--- persistence belongs to the caller.
---
--- That is deliberate and it is the lesson of D027. `domain/mine/registry.lua`
--- was moved into `domain/` without being de-globalised, is the single entry in
--- the layering check's allow list, and is still there. This one is written the
--- way that file has to be rewritten, so the debt does not double.
---
--- ## Time is the server's, never the device's
---
--- `seenAt` is stamped from the clock of whatever machine received the
--- heartbeat. A turtle's own clock resets on reboot and drifts against every
--- other computer, so a timestamp it supplied would be uncomparable with one
--- from the turtle beside it — and "which of these went quiet first" is the
--- entire question this module exists to answer.

local registry = {}

--- Seconds of silence before a device is late, and before it is gone.
---
--- Two thresholds rather than one because they mean different things to a
--- person. Late is "it missed a heartbeat", which happens constantly to a
--- wireless turtle at the edge of range and is not news. Offline is "stop
--- expecting it", which is.
registry.LATE_AFTER = 10
registry.OFFLINE_AFTER = 60

function registry.empty()
  return { devices = {} }
end

--- Pull a world position out of a snapshot, or nil if it has none.
---
--- `world` is the turtle's absolute position and the only one worth keeping: the
--- `x`/`y`/`z` beside it are relative to that turtle's own home block, so two
--- turtles reporting `0,0,0` are in different places and neither is findable.
---
--- Returns nil rather than a zero for a device that does not know. Nil is the
--- honest answer and it is what stops `observe` from overwriting a good record;
--- `0,0,0` is a real place in the world and has already cost this fleet a night.
function registry.locate(snapshot)
  if type(snapshot) ~= "table" then
    return nil
  end
  local world = snapshot.world
  if type(world) ~= "table" then
    return nil
  end
  local x, y, z = tonumber(world.x), tonumber(world.y), tonumber(world.z)
  if x == nil or y == nil or z == nil then
    return nil
  end
  return {
    x = math.floor(x),
    y = math.floor(y),
    z = math.floor(z),
    facing = snapshot.facing,
    -- Carried so cross-dimension support does not have to be retrofitted into
    -- every saved record later. Nothing reads it yet; see §11 of icos-2.md.
    dimension = world.dimension or snapshot.dimension or "overworld",
  }
end

--- Record a heartbeat.
---
--- Returns the updated record and whether this device was previously unknown, so
--- a caller can log a device joining without diffing the whole table itself.
function registry.observe(state, id, snapshot, now)
  local key = tostring(id)
  local previous = state.devices[key]
  local fix = registry.locate(snapshot)

  local record = {
    id = tonumber(id) or id,
    snap = snapshot,
    seenAt = now,
    pairedAt = previous and previous.pairedAt or now,

    -- The whole point. A fresh fix replaces the old one; no fix leaves the old
    -- one exactly where it was, along with when it was taken - because "last
    -- seen at these coordinates twenty minutes ago" is the difference between a
    -- search and a shrug.
    location = fix or (previous and previous.location) or nil,
    locatedAt = fix and now or (previous and previous.locatedAt) or nil,
  }

  state.devices[key] = record
  return record, previous == nil
end

--- Forget a device. The operator's "this one is gone for good".
function registry.forget(state, id)
  local key = tostring(id)
  local previous = state.devices[key]
  state.devices[key] = nil
  return previous
end

function registry.get(state, id)
  return state.devices[tostring(id)]
end

--- How long a device has been quiet, in seconds.
function registry.age(record, now)
  if record == nil or record.seenAt == nil then
    return math.huge
  end
  return math.max(0, (now - record.seenAt) / 1000)
end

--- `online`, `late` or `offline`.
function registry.health(record, now)
  local age = registry.age(record, now)
  if age > registry.OFFLINE_AFTER then
    return "offline"
  end
  if age > registry.LATE_AFTER then
    return "late"
  end
  return "online"
end

--- Every device, each annotated with what the caller would otherwise recompute.
---
--- `sort` is a comparator over the annotated records. The default is stable and
--- alphabetical-ish by id, which is only useful as a default; the two orders
--- worth having are `registry.byLabel` and `registry.byStaleness`.
function registry.list(state, now, sort)
  local rows = {}
  for _, record in pairs(state.devices) do
    rows[#rows + 1] = {
      id = record.id,
      snap = record.snap,
      seenAt = record.seenAt,
      pairedAt = record.pairedAt,
      location = record.location,
      locatedAt = record.locatedAt,
      age = registry.age(record, now),
      health = registry.health(record, now),
    }
  end
  table.sort(rows, sort or function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)
  return rows
end

--- Quietest first.
---
--- §6 of icos-2.md: *"A Devices app view sorted by staleness makes that the first
--- thing you see."* A roster sorted by name buries the one device that has
--- stopped reporting among nine that are fine, which is precisely backwards -
--- the healthy ones need no attention at all.
function registry.byStaleness(a, b)
  if a.age ~= b.age then
    return a.age > b.age
  end
  return tostring(a.id) < tostring(b.id)
end

--- Devices that have gone quiet, quietest first, with wherever they were last
--- seen.
---
--- This is the search party. A missing device that was never located is still
--- listed, with `location = nil`, because "we do not know where miner-7 is" is
--- itself worth reporting - it is the answer to a different question than "there
--- is no miner-7".
function registry.missing(state, now, after)
  after = after or registry.OFFLINE_AFTER
  local rows = {}
  for _, row in ipairs(registry.list(state, now, registry.byStaleness)) do
    if row.age > after then
      rows[#rows + 1] = row
    end
  end
  return rows
end

--- A short human description of where something was, for a log line or a chat
--- notification.
function registry.describe(row)
  local label = (row.snap and row.snap.label) or ("computer " .. tostring(row.id))
  if not row.location then
    return label .. " at an unknown position"
  end
  return ("%s at %d, %d, %d"):format(label, row.location.x, row.location.y, row.location.z)
end

return registry
