--- The device registry: retention, staleness, and the search party.
---
--- Pure domain code, so these need no world, no screen and no clock — `now` is
--- a number the test picks. That is the point of writing it this way rather than
--- the way `domain/mine/registry.lua` still is.

local expect = require("support.expect")
local it = require("support.spec").it

local registry = require("domain.fleet.registry")

local SECOND = 1000

local function snapshot(overrides)
  local snap = {
    label = "miner-7",
    role = "miner",
    phase = "mining",
    job = "rare",
    fuel = 51000,
    facing = 2,
    world = { x = 138, y = -59, z = -1176 },
  }
  for key, value in pairs(overrides or {}) do
    if value == "nil" then
      snap[key] = nil
    else
      snap[key] = value
    end
  end
  return snap
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

it("a heartbeat records the device and stamps the server's clock", function()
  local state = registry.empty()
  local record, isNew = registry.observe(state, 7, snapshot(), 1000 * SECOND)

  expect.truthy(isNew, "reported as newly paired")
  expect.equal(record.id, 7, "the id is a number, not the table key")
  expect.equal(record.seenAt, 1000 * SECOND, "stamped from the clock it was given")
  expect.equal(record.pairedAt, 1000 * SECOND, "and paired at the same moment")

  local _, alsoNew = registry.observe(state, 7, snapshot(), 1030 * SECOND)
  expect.falsy(alsoNew, "the second heartbeat is not a new pairing")
  expect.equal(registry.get(state, 7).pairedAt, 1000 * SECOND, "and pairing time survives")
end)

it("a position is kept out of the snapshot so it can outlive one", function()
  local state = registry.empty()
  registry.observe(state, 7, snapshot(), 1000 * SECOND)

  local record = registry.get(state, 7)
  expect.equal(record.location.x, 138, "x")
  expect.equal(record.location.y, -59, "y")
  expect.equal(record.location.z, -1176, "z")
  expect.equal(record.locatedAt, 1000 * SECOND, "and when it was taken")
end)

it("a heartbeat with no position does not erase the one already known", function()
  -- The bug this module exists for. `fleet/roster.lua` replaces the whole
  -- record, so a turtle that reboots underground without its origin reports
  -- `world = nil` and the base overwrites the last position it knew with
  -- nothing. The information arrived, and the next message destroyed it.
  local state = registry.empty()
  registry.observe(state, 7, snapshot(), 1000 * SECOND)
  registry.observe(state, 7, snapshot({ world = "nil", located = false }), 1030 * SECOND)

  local record = registry.get(state, 7)
  expect.truthy(record.location, "the last known position survived")
  expect.equal(record.location.x, 138, "unchanged")
  expect.equal(record.locatedAt, 1000 * SECOND, "and still dated to when it was true")
  expect.equal(record.seenAt, 1030 * SECOND, "while the heartbeat time moved on")
end)

it("a fresh position replaces the old one", function()
  local state = registry.empty()
  registry.observe(state, 7, snapshot(), 1000 * SECOND)
  registry.observe(state, 7, snapshot({ world = { x = 200, y = -59, z = -1100 } }), 1030 * SECOND)

  local record = registry.get(state, 7)
  expect.equal(record.location.x, 200, "moved")
  expect.equal(record.locatedAt, 1030 * SECOND, "and redated")
end)

it("a malformed position is treated as no position at all", function()
  -- `0, 0, 0` is a real place in the world, and a partial record is how a device
  -- ends up claiming to be there. Nil is the honest answer, and it is what keeps
  -- the retention rule above from being defeated by a half-filled table.
  local state = registry.empty()
  expect.equal(registry.locate(nil), nil, "no snapshot")
  expect.equal(registry.locate({}), nil, "no world")
  expect.equal(registry.locate({ world = { x = 1, y = 2 } }), nil, "a missing axis")
  expect.equal(registry.locate({ world = "somewhere" }), nil, "not even a table")

  registry.observe(state, 7, snapshot(), 1000 * SECOND)
  registry.observe(state, 7, snapshot({ world = { x = 1, y = 2 } }), 1030 * SECOND)
  expect.equal(registry.get(state, 7).location.x, 138, "the good record is not replaced")
end)

it("a dimension is carried even though nothing reads it yet", function()
  -- §11 of icos-2.md: cross-dimension is deliberately not planned, and
  -- `dimension` is in the record so it does not have to be retrofitted into
  -- every saved file later.
  local state = registry.empty()
  registry.observe(state, 7, snapshot({ world = { x = 1, y = 2, z = 3, dimension = "nether" } }), 0)
  expect.equal(registry.get(state, 7).location.dimension, "nether", "kept")

  registry.observe(state, 8, snapshot(), 0)
  expect.equal(registry.get(state, 8).location.dimension, "overworld", "and defaulted")
end)

---------------------------------------------------------------------------
-- Staleness
---------------------------------------------------------------------------

it("health has three states and they mean different things", function()
  local state = registry.empty()
  registry.observe(state, 7, snapshot(), 0)

  local record = registry.get(state, 7)
  expect.equal(registry.health(record, 5 * SECOND), "online", "a recent heartbeat")
  -- Late happens constantly to a wireless turtle at the edge of range and is not
  -- news. Offline is "stop expecting it", which is.
  expect.equal(registry.health(record, 30 * SECOND), "late", "one missed heartbeat")
  expect.equal(registry.health(record, 120 * SECOND), "offline", "gone")
end)

it("a device that has never reported is infinitely stale, not zero", function()
  expect.equal(registry.age(nil, 1000), math.huge, "no record")
  expect.equal(registry.age({}, 1000), math.huge, "a record with no heartbeat")
  expect.equal(registry.health({}, 1000), "offline", "and reads as offline")
end)

it("the roster can be sorted quietest first", function()
  -- §6: a roster sorted by name buries the one device that has stopped
  -- reporting among nine that are fine, which is precisely backwards.
  local state = registry.empty()
  registry.observe(state, 1, snapshot({ label = "miner-1" }), 100 * SECOND)
  registry.observe(state, 2, snapshot({ label = "miner-2" }), 10 * SECOND)
  registry.observe(state, 3, snapshot({ label = "miner-3" }), 50 * SECOND)

  local rows = registry.list(state, 200 * SECOND, registry.byStaleness)
  expect.equal(rows[1].id, 2, "the quietest first")
  expect.equal(rows[3].id, 1, "and the healthiest last")
  expect.near(rows[1].age, 190, 0.01, "with the age in seconds")
end)

---------------------------------------------------------------------------
-- The search party
---------------------------------------------------------------------------

it("missing devices come back with wherever they were last seen", function()
  local state = registry.empty()
  registry.observe(state, 1, snapshot({ label = "miner-1" }), 500 * SECOND)
  registry.observe(state, 7, snapshot({ label = "miner-7" }), 100 * SECOND)

  local gone = registry.missing(state, 500 * SECOND)
  expect.equal(#gone, 1, "only the quiet one")
  expect.equal(gone[1].id, 7, "miner-7")
  expect.equal(gone[1].location.x, 138, "and where it was")
  expect.contains(registry.describe(gone[1]), "138, -59, -1176", "described for a log line")
end)

it("a device that vanished before it was ever located is still reported", function()
  -- "We do not know where miner-9 is" answers a different question than "there
  -- is no miner-9", and the second one is what silence looks like if the list
  -- only contains devices with coordinates.
  local state = registry.empty()
  registry.observe(state, 9, snapshot({ label = "miner-9", world = "nil" }), 0)

  local gone = registry.missing(state, 300 * SECOND)
  expect.equal(#gone, 1, "listed")
  expect.equal(gone[1].location, nil, "with no position")
  expect.contains(registry.describe(gone[1]), "unknown position", "and said so")
end)

it("forgetting a device removes it entirely", function()
  local state = registry.empty()
  registry.observe(state, 7, snapshot(), 0)
  expect.truthy(registry.forget(state, 7), "the old record comes back")
  expect.equal(registry.get(state, 7), nil, "and it is gone")
  expect.equal(#registry.list(state, 0), 0, "with nothing left in the roster")
end)

it("the registry touches no clock of its own", function()
  -- The lesson of D027, made a test rather than an intention:
  -- `domain/mine/registry.lua` was moved into `domain/` without being
  -- de-globalised and is still the only entry in the layering check's allow
  -- list. Everything here takes `now` as an argument, so a spec can place two
  -- heartbeats a fortnight apart without waiting.
  local state = registry.empty()
  registry.observe(state, 7, snapshot(), 0)
  local fortnight = 14 * 24 * 60 * 60 * SECOND
  expect.equal(registry.health(registry.get(state, 7), fortnight), "offline", "no real time passed")
end)

it("a heartbeat keeps whatever else has been attached to the record", function()
  -- The same bug as the location one, one module over. `domain/fleet/desired.lua`
  -- attaches `desired` and `observed` to a registry record, and the first version
  -- of `observe` built a fresh table each heartbeat - so an order set while a
  -- device was away vanished the moment it checked in, which is exactly the
  -- failure desired state exists to fix.
  --
  -- Copying fields forward by name would work until somebody added a seventh and
  -- forgot. Mutating in place cannot have that bug.
  local state = registry.empty()
  local record = registry.observe(state, 7, snapshot(), 1000 * SECOND)
  record.desired = { mode = "recall", generation = 41 }
  record.somethingLater = "a field nobody has written yet"

  registry.observe(state, 7, snapshot(), 1030 * SECOND)

  local after = registry.get(state, 7)
  expect.equal(after.desired.mode, "recall", "the order survived")
  expect.equal(after.somethingLater, "a field nobody has written yet", "and so would anything else")
  expect.equal(after, record, "because it is the same table")
end)
