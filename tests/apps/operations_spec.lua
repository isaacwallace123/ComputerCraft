--- Placing the mine, and starting the fleet on it.

local expect = require("support.expect")
local fleet = require("support.fleet")
local it = require("support.spec").it

local discovery = require("os.server.services.discovery")
local leases = require("os.server.services.leases")
local operations = require("apps.operations.app")
local plan = require("domain.mine.plan")

it("placing the mine sets three fields in one message", function()
  -- A mine that moved its X and then its Z would exist at a corner it was never
  -- meant to occupy for as long as the round trip took, and every turtle asking
  -- for a sector in between would be given one there.
  local ctx = fleet.server()
  local reply = assert(leases.handle(ctx, 1, operations.place(100, 64, -200)))

  expect.truthy(reply.ok, "accepted")
  expect.truthy(reply.plan.configured, "the mine exists now")
  expect.equal(reply.plan.centreX, 100, "at the x")
  expect.equal(reply.plan.centreZ, -200, "and the z")
  expect.equal(reply.plan.surfaceY, 64, "and the surface")
  expect.truthy(reply.capacity > 0, "with sectors to work")
end)

it("a fleet cannot deploy onto a mine that is not there", function()
  -- leases.claim refuses every request until a plan is configured, so a base
  -- with no mine is a base whose turtles all park saying so.
  local ctx = fleet.server()
  local text = operations.summary(ctx.state)
  expect.contains(text, "no mine placed", "and the page says so first")

  local refused = assert(leases.handle(ctx, 7, fleet.request("claim", { workKey = "w" })))
  expect.falsy(refused.ok, "the turtle is refused")
end)

it("changing the grid clears the sector map, and says that it did", function()
  -- Sector 7 under a 48-block grid is not the same ground as sector 7 under a
  -- 64-block one. Keeping the progress would mean turtles resuming shafts that
  -- are no longer where the record says - two turtles in one hole by
  -- arithmetic rather than by a race.
  local ctx = fleet.server()
  leases.handle(ctx, 1, operations.place(0, 64, 0))

  local claim = assert(leases.handle(ctx, 7, fleet.request("claim", { workKey = "w" })))
  expect.truthy(claim.ok, "a sector was leased")
  expect.truthy(next(ctx.state.mine.sectors), "so the map has something in it")

  local reply = assert(leases.handle(ctx, 1, operations.intent("cellSize", 64)))
  expect.truthy(reply.ok, "accepted")
  expect.truthy(reply.regridded, "and reported as a regrid")
  expect.falsy(next(ctx.state.mine.sectors), "with the map cleared")
end)

it("re-sending a value that has not changed does not clear anything", function()
  -- The page sends a field on every stepper press, so a person who nudges a
  -- number up and back down would otherwise wipe the map for no change at all.
  local ctx = fleet.server()
  leases.handle(ctx, 1, operations.place(0, 64, 0))
  leases.handle(ctx, 7, fleet.request("claim", { workKey = "w" }))

  local same =
    assert(leases.handle(ctx, 1, operations.intent("cellSize", ctx.state.mine.plan.cellSize)))
  expect.truthy(same.ok, "accepted")
  expect.falsy(same.regridded, "nothing moved")
  expect.truthy(next(ctx.state.mine.sectors), "and the map survived")
end)

it("a number outside the world is refused with the range", function()
  -- Checked on the server rather than in the page, because the page is not the
  -- only thing that can send one of these.
  local ctx = fleet.server()

  local high = assert(leases.handle(ctx, 1, operations.intent("surfaceY", 5000)))
  expect.falsy(high.ok, "refused")
  expect.contains(high.message, "surfaceY", "naming the field")

  local inverted =
    assert(leases.handle(ctx, 1, { kind = "mineplan", set = { minRing = 6, maxRing = 2 } }))
  expect.falsy(inverted.ok, "an inside-out mine is refused too")
  expect.contains(inverted.message, "inner ring", "and says which way round")
end)

it("only parked, reporting turtles are counted as deployable", function()
  -- A goal set on a device silent for twenty minutes shows as pending forever
  -- and tells nobody anything. The count on the button is the number of turtles
  -- that will actually move.
  local ctx = fleet.server()
  fleet.parked(ctx, 7, { parkKind = "idle" })
  discovery.handle(ctx, 8, fleet.heartbeat())

  expect.equal(#operations.deployable(ctx.state, ctx.clock.now()), 1, "one parked and online")

  ctx._clock.advance(20 * 60)
  expect.equal(#operations.deployable(ctx.state, ctx.clock.now()), 0, "and none once it is quiet")
end)

it("the mine rides on the mirror, so a client can draw it", function()
  local ctx = fleet.server()
  leases.handle(ctx, 1, operations.place(0, 64, 0))

  local mirror = assert(discovery.handle(ctx, 1, { kind = discovery.MIRROR }))
  expect.truthy(mirror.mine, "carried")
  expect.truthy(mirror.mine.plan.configured, "with the plan on it")
  expect.equal(plan.capacity(mirror.mine.plan), plan.capacity(ctx.state.mine.plan), "the same mine")
end)
