--- Sector physical state lives at the base, not in one turtle's job file.
---
--- Driven with an explicit clock and an in-memory state, because the module
--- under test now has neither of its own: `now` is an argument and reading
--- `.mine` belongs to the caller. Before that this spec needed a simulated
--- world just to give the registry a file to load and a clock to stamp with,
--- which is a lot of machinery to test arithmetic about sectors.

local expect = require("support.expect")
local it = require("support.spec").it

--- A fixed instant. Every stamp in one test is taken from it, which is the
--- property the module now enforces rather than hopes for - a lease compared
--- against a different clock than it was stamped with is how two turtles ended
--- up in one shaft.
local NOW = 1700000000 * 1000

local function newRegistry()
  local plan = require("domain.mine.plan")
  local registry = require("domain.mine.registry")
  local state = registry.empty()
  state.plan = plan.normalise({
    configured = true,
    centreX = 0,
    centreZ = 0,
    surfaceY = 64,
    cellSize = 16,
    maxRing = 2,
    minRing = 1,
  })
  return registry, state
end

--- How many sectors have a record on disk.
local function stored(state)
  local count = 0
  for _ in pairs(state.sectors) do
    count = count + 1
  end
  return count
end

it("a claim records the sector it leased, and not the whole plan", function()
  local registry, state = newRegistry()
  local plan = require("domain.mine.plan")

  local capacity = plan.capacity(state.plan)
  expect.truthy(capacity >= 20, "a plan with room to notice the difference")

  registry.claim(state, 7, "rare@-59", 0, 0, NOW)

  -- The finding this pins. `entry` is get-or-create and four scan loops called
  -- it while only reading, so the first claim on a fresh mine wrote a record for
  -- every sector in the plan - each with an empty work entry and
  -- `surface = unknown`. A live base's `.mine` was 10,626 bytes of forty-eight
  -- such records with **zero holders** between them.
  --
  -- It is not only disk. `leases` flushes the whole file on every claim, surface
  -- report and release, so the write was an order of magnitude larger than the
  -- fact it was recording - on a computer that had just run out of space.
  expect.equal(stored(state), 1, "one sector leased, one record written")
end)

it("scanning past unworked sectors does not bring them into existence", function()
  local registry, state = newRegistry()

  -- Exhaust the first sector, forcing the allocator to walk the whole plan
  -- looking for somewhere else. Every sector it passes over is a candidate and
  -- has no record, which is exactly the scan that used to materialise them all.
  registry.claim(state, 7, "rare@-59", 1, 0, NOW)
  registry.report(state, 7, 1, "rare@-59", 0, 0, true, NOW)
  registry.release(state, 7, 1)

  local before = stored(state)
  registry.claim(state, 8, "rare@-59", 0, 0, NOW)

  expect.equal(stored(state), before + 1, "one more record, for the one it took")
end)

it("a second turtle's claim releases the first's without touching anything else", function()
  local registry, state = newRegistry()

  registry.claim(state, 7, "rare@-59", 1, 0, NOW)
  local afterFirst = stored(state)

  -- One turtle holds one shaft, so taking a new sector gives up the old one -
  -- and finding the old one is a walk over what is held rather than over the
  -- plan, because a sector nobody has claimed cannot be holding anything.
  registry.claim(state, 7, "rare@-59", 2, 0, NOW)

  expect.equal(stored(state), afterFirst + 1, "only the newly leased sector was added")
  expect.falsy(state.sectors["1"].holder, "and the old lease was given up")
  expect.equal(state.sectors["2"].holder, 7, "for the new one")
end)

it("registry records and reports an open shaft head", function()
  local registry, state = newRegistry()

  expect.equal(#registry.exposed(state), 0, "nothing exposed to begin with")

  expect.truthy(
    registry.surface(
      state,
      7,
      3,
      { state = "open", headY = 71, headOffset = 2, reason = "no cap block" },
      NOW
    ),
    "surface report accepted"
  )

  local exposed = registry.exposed(state)
  expect.equal(#exposed, 1, "one exposed sector")
  expect.equal(exposed[1].index, 3, "the right sector")
  expect.equal(exposed[1].headY, 71, "records the head height")
  expect.contains(exposed[1].reason, "cap block", "records why")

  registry.surface(state, 7, 3, { state = "sealed", headY = 71, headOffset = 2 }, NOW)
  expect.equal(#registry.exposed(state), 0, "sealing clears it")
end)

it("an exposed sector is leased out ahead of fresh ground", function()
  local registry, state = newRegistry()

  -- Sector 5 is finished, but its head was left open.
  registry.report(state, 1, 5, "rare@-59", 16, 10, true, NOW)
  registry.surface(state, 1, 5, { state = "open", headY = 64, headOffset = 0 }, NOW)

  local index = registry.claim(state, 2, "rare@-59", nil, 0, NOW)
  expect.equal(index, 5, "the open sector is handed out first, exhausted or not")
end)

it("a sealed exhausted sector is not handed out again", function()
  local registry, state = newRegistry()

  registry.report(state, 1, 5, "rare@-59", 16, 10, true, NOW)
  registry.surface(state, 1, 5, { state = "sealed", headY = 64, headOffset = 0 }, NOW)

  local index = registry.claim(state, 2, "rare@-59", nil, 0, NOW)
  expect.truthy(index ~= 5, "finished and shut means done, got " .. tostring(index))
end)

it("a turtle is told the head another turtle already found", function()
  local registry, state = newRegistry()
  registry.surface(state, 1, 4, { state = "sealed", headY = 78, headOffset = -3 }, NOW)

  local known = registry.surfaceOf(state, 4)
  expect.truthy(known, "the base remembers")
  expect.equal(known and known.headOffset, -3, "including where along the trunk")
  expect.equal(known and known.headY, 78, "and how high the ground was")

  expect.falsy(registry.surfaceOf(state, 9), "nothing invented for unvisited sectors")
end)

it("registry state written before physical tracking still loads", function()
  local registry, state = newRegistry()
  -- Exactly the shape ICOS v1.2.8 persisted: no `surface` key at all.
  state.sectors["2"] = { holder = nil, work = { ["rare@-59"] = { frontier = 4 } } }

  local rows = registry.summary(state, NOW)
  local found = false
  for _, row in ipairs(rows) do
    if row.index == 2 then
      found = true
      expect.equal(row.surface, "unknown", "an old record reads as unknown, not open")
    end
  end
  expect.truthy(found, "the old record still appears")
  expect.equal(#registry.exposed(state), 0, "and is not mistaken for a hole")
end)

---------------------------------------------------------------------------
-- Placing the mine
---------------------------------------------------------------------------

it("placing a mine latches configured, and tuning it later does not unplace it", function()
  local registry = require("domain.mine.registry")
  local state = registry.empty()

  local placed = registry.configure(state, { centreX = 50, centreZ = 50, surfaceY = 64 })
  expect.truthy(placed.configured, "placed")

  local tuned = registry.configure(state, { maxRing = 4 })
  expect.truthy(tuned.configured, "still placed after a change that names no centre")
end)

it("moving the mine throws away every frontier, and says so", function()
  -- Sector 7 is a different patch of world now. Keeping the old frontiers would
  -- send a turtle to resume a tunnel that does not exist.
  local registry, state = newRegistry()
  registry.report(state, 1, 3, "rare@-59", 5, 10, false, NOW)
  expect.truthy(state.sectors["3"], "progress recorded")

  local _, moved = registry.configure(state, { centreX = 900, centreZ = 900 })
  expect.truthy(moved, "reported as a move")
  expect.equal(next(state.sectors), nil, "and the sectors were cleared")
end)

it("the keep-out radius counts as moving the ground", function()
  -- The one that is not obvious: raising minRing shifts every sector outward
  -- along the spiral, so the numbers stay and the places change - the worst
  -- version of this bug, because nothing looks different.
  local registry, state = newRegistry()
  registry.report(state, 1, 3, "rare@-59", 5, 10, false, NOW)

  local _, moved = registry.configure(state, { minRing = 3 })
  expect.truthy(moved, "counts as a move")
  expect.equal(next(state.sectors), nil, "so the frontiers went with it")
end)

it("reshaping without moving the ground keeps the progress", function()
  -- A bigger mine is still the same mine. Clearing here would throw away a day
  -- of tunnels for a change that moved nothing.
  local registry, state = newRegistry()
  registry.report(state, 1, 3, "rare@-59", 5, 10, false, NOW)

  local _, moved = registry.configure(state, { maxRing = 5 })
  expect.falsy(moved, "nothing moved")
  expect.truthy(state.sectors["3"], "and the frontier survived")
end)
