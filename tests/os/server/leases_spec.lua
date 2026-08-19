local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local discovery = require("os.server.services.discovery")
local leases = require("os.server.services.leases")
local registry = require("domain.fleet.registry")

local mined = fleet.mined
local request = fleet.request
local serverContext = fleet.server

---------------------------------------------------------------------------
-- Leases: two turtles are never sent down the same shaft
---------------------------------------------------------------------------

it("a sector goes to one turtle and the next one gets a different sector", function()
  local ctx = mined()

  local first = assert(leases.handle(ctx, 7, request("claim", { workKey = "w", requestId = 1 })))
  expect.truthy(first.ok, "claimed")
  expect.equal(first.requestId, 1, "answering the right request")

  local second = assert(leases.handle(ctx, 8, request("claim", { workKey = "w", requestId = 2 })))
  expect.truthy(second.ok, "claimed")

  -- The whole reason this is a service. D018: this used to stop working when
  -- somebody closed the Fleet page.
  expect.truthy(first.sector ~= second.sector, "and never the same hole")
end)

it("an unconfigured mine says so instead of going quiet", function()
  -- A turtle waits about three seconds and then falls back to its cached plan,
  -- so "no" arriving promptly beats a correct answer arriving too late.
  local ctx = serverContext()
  local reply = assert(leases.handle(ctx, 7, request("claim", { workKey = "w", requestId = 4 })))
  expect.falsy(reply.ok, "refused")
  expect.contains(reply.message, "mine here", "and tells somebody how to fix it")
end)

it("a claim is written immediately and a report is not", function()
  -- The trade in the file header: a lost report costs re-counted footage, a
  -- lost claim is two turtles in one hole.
  local ctx = mined()
  local writes = 0
  ctx.storage.write = function()
    writes = writes + 1
    return true
  end

  local claim = assert(leases.handle(ctx, 7, request("claim", { workKey = "w" })))
  expect.equal(writes, 1, "the claim hit the disk")

  for _ = 1, 10 do
    leases.handle(ctx, 7, request("report", { sector = claim.sector, workKey = "w", blocks = 3 }))
  end
  expect.equal(writes, 1, "ten reports did not")
  expect.truthy(ctx.dirty.mine, "they were marked instead")
end)

it("an open shaft head is written the moment it is reported", function()
  -- The one fact here nothing in the world will re-report: the turtle that saw
  -- the hole has moved on, and the hole is still there.
  local ctx = mined()
  local writes = 0
  ctx.storage.write = function()
    writes = writes + 1
    return true
  end

  local reply =
    assert(leases.handle(ctx, 7, request("surface", { sector = 2, state = "open", headY = 71 })))
  expect.truthy(reply.ok, "recorded")
  expect.equal(writes, 1, "and persisted at once")
  expect.equal(#require("domain.mine.registry").exposed(ctx.state.mine), 1, "one open head")
end)

it("a claim tells a replacement turtle what the last one found", function()
  local ctx = mined()
  leases.handle(ctx, 7, request("surface", { sector = 2, state = "open", headY = 71 }))
  leases.handle(ctx, 7, request("release", { sector = 2 }))

  local reply = assert(leases.handle(ctx, 9, request("claim", { workKey = "w", sector = 2 })))
  expect.equal(reply.sector, 2, "the same sector")
  expect.equal(reply.surface.state, "open", "and it knows before it arrives")
end)

it("a heartbeat renews a lease without a disk write, and parking gives it back", function()
  local ctx = mined()
  local claim = assert(leases.handle(ctx, 7, request("claim", { workKey = "w" })))

  local snapshot = { sector = claim.sector, workKey = "w" }
  expect.falsy(leases.renew(ctx, 7, snapshot), "a fresh lease needs no renewal")

  -- Renewal only bites once the lease is actually getting old, which is what
  -- stops a two-second heartbeat becoming a two-second disk write.
  ctx._clock.advance(45)
  expect.truthy(leases.renew(ctx, 7, snapshot), "an ageing one does")

  ctx._clock.advance(45)
  snapshot.parked = true
  expect.falsy(leases.renew(ctx, 7, snapshot), "and a parked turtle stops asking")
end)

it("a lease whose holder went quiet is swept up", function()
  local ctx = mined()
  local claim = assert(leases.handle(ctx, 7, request("claim", { workKey = "w" })))

  expect.equal(leases.sweep(ctx), 0, "nothing to sweep yet")

  ctx._clock.advance(20 * 60)
  expect.equal(leases.sweep(ctx), 1, "the lease expired")

  local other =
    assert(leases.handle(ctx, 8, request("claim", { workKey = "w", sector = claim.sector })))
  expect.equal(other.sector, claim.sector, "and the sector went back into the pool")
end)

it("one status heartbeat reaches both services", function()
  -- Only one loop can call receive, because receiving consumes. So discovery
  -- owns the radio and everything else registers a handler - and a heartbeat is
  -- a device report to one service and a lease renewal to the other.
  local ctx = mined()
  local claim = assert(leases.handle(ctx, 7, request("claim", { workKey = "w" })))
  ctx._clock.advance(45)

  local replies = discovery.dispatch(ctx, 7, {
    kind = "status",
    snapshot = { sector = claim.sector, workKey = "w", world = { x = 1, y = 2, z = 3 } },
  })

  expect.equal(#replies, 1, "one answer went back")
  expect.equal(replies[1].kind, "desired", "from discovery")
  expect.truthy(registry.get(ctx.state.fleet, 7), "the device was recorded")
  expect.truthy(ctx.dirty.mine, "and the lease was renewed")
end)

it("a mine request is answered by leases and ignored by discovery", function()
  local ctx = mined()
  local replies = discovery.dispatch(ctx, 7, request("claim", { workKey = "w", requestId = 3 }))

  expect.equal(#replies, 1, "exactly one reply")
  expect.equal(replies[1].kind, "mine_result", "and it came from leases")
  expect.equal(replies[1].requestId, 3, "matched to the request")
end)
