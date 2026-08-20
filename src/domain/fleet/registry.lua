--- The device registry: who exists, what they were doing, and where they were.
---
--- Phase 2 of docs/icos-2.md, and the answer to the second of the four failures
--- in §1: *"Three miners vanished and nothing knew where — position is broadcast
--- and discarded."*
---
--- ## The bug this exists to fix
---
--- `legacy/fleet/roster.lua` does record every heartbeat, and it does persist them. What
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

--- The name of this server's run of numbering.
---
--- Desired-state generations count up per device record, so a generation only
--- means anything next to the state that holds it. This gives that state an
--- identity, so a device can tell "an order older than one I have applied" from
--- "an order from a server that has started counting again" - which look
--- identical as bare numbers and call for opposite responses.
---
--- Minted once from the clock and persisted alongside the devices, so it
--- survives a reboot and changes exactly when the state it names is lost.
function registry.epoch(state, now)
  if state == nil then
    return nil
  end
  if state.epoch == nil then
    state.epoch = now
  end
  return state.epoch
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

--- Record a heartbeat, updating the record **in place** rather than replacing it.
---
--- Returns the record and whether this device was previously unknown, so a
--- caller can log a device joining without diffing the whole table itself.
---
--- This is the same rule as the location retention below, generalised, and it
--- was learned twice. `legacy/fleet/roster.lua` replaces the whole record and thereby
--- erases a position; the first version of this function replaced the whole
--- record too, and thereby erased the `desired` and `observed` fields that
--- `domain/fleet/desired.lua` attaches to it - so an order set while a device
--- was away vanished on that device's next heartbeat, which is precisely the
--- failure desired state exists to fix.
---
--- Copying the fields forward by name would work until somebody added a seventh
--- and forgot. Mutating the record cannot have that bug, because there is no
--- list to fall out of date.
function registry.observe(state, id, snapshot, now)
  local key = tostring(id)
  local record = state.devices[key]
  local isNew = record == nil

  if isNew then
    record = { id = tonumber(id) or id, pairedAt = now }
    state.devices[key] = record
  end

  record.snap = snapshot
  record.seenAt = now

  -- A fresh fix replaces the old one; no fix leaves the old one exactly where it
  -- was, along with when it was taken - because "last seen at these coordinates
  -- twenty minutes ago" is the difference between a search and a shrug.
  local fix = registry.locate(snapshot)
  if fix then
    record.location = fix
    record.locatedAt = now
  end

  return record, isNew
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

--- Record that a device is going down on purpose.
---
--- §6's whole subject is telling "we do not know where miner-7 is" from "there
--- is no miner-7", and this adds the third case it was missing: *miner-7 was
--- switched off, deliberately, at a time somebody can see.*
---
--- Without it a turtle that is powered down for maintenance looks exactly like
--- one that fell in lava - both simply stop reporting - so the dashboard raises
--- the same alarm for a planned shutdown as for a lost machine, and a person
--- learns to ignore it.
---
--- The record is kept rather than removed. A device that has gone away is still
--- a device that was here, and its last known position is the one fact somebody
--- may want tomorrow.
function registry.depart(state, id, now)
  local record = registry.get(state, id)
  if record == nil then
    return nil
  end
  record.departedAt = now
  return record
end

--- `off`, `online`, `late` or `offline`.
function registry.health(record, now)
  -- A farewell only counts until the device speaks again. A turtle that was
  -- switched off and switched back on is not "off" - and comparing against
  -- `seenAt` means nothing has to remember to clear the flag, which is the kind
  -- of bookkeeping that gets forgotten exactly once.
  if record ~= nil and record.departedAt ~= nil and (record.seenAt or 0) <= record.departedAt then
    return "off"
  end

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

--- The live records themselves, in a stable order.
---
--- `list` returns annotated copies, which is what a view wants and what a
--- mutator must not have: writing a goal onto a copy sets it on nothing. So
--- anything that changes a device goes through this instead.
---
--- Ordered by id rather than left in `pairs` order, and that is not tidiness.
--- The policy service applies one rolling update per pass, so whichever device
--- it reaches first is the one that updates - and `pairs` would make that a
--- different turtle on every pass and in a different order after every reboot,
--- which is a fleet that updates unpredictably and cannot be reasoned about
--- while it is happening.
function registry.records(state)
  local records = {}
  for _, record in pairs(state.devices) do
    records[#records + 1] = record
  end
  table.sort(records, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)
  return records
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
