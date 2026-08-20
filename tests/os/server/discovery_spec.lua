local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")
local SECOND = fleet.SECOND

local desired = require("domain.fleet.desired")
local discovery = require("os.server.services.discovery")
local registry = require("domain.fleet.registry")
local wire = require("domain.protocol.message")

local context = fleet.context
local heartbeat = fleet.heartbeat

---------------------------------------------------------------------------
-- A server, driven
---------------------------------------------------------------------------

it("a heartbeat is recorded and answered", function()
  local ctx = context()
  local reply = assert(discovery.handle(ctx, 7, heartbeat()), "answered")
  expect.equal(reply.kind, "desired", "with a desired-state reply")

  local record = registry.get(ctx.state.fleet, 7)
  expect.truthy(record, "and the device was recorded")
  expect.equal(record.location.x, 138, "with where it is")
end)

it("a message that is not ours is left alone", function()
  local ctx = context()
  expect.equal(discovery.handle(ctx, 7, "hello"), nil, "not a table")
  expect.equal(discovery.handle(ctx, 7, {}), nil, "no kind")
  expect.equal(discovery.handle(ctx, 7, { kind = "mine" }), nil, "somebody else's protocol")
  expect.equal(registry.get(ctx.state.fleet, 7), nil, "and nothing was recorded")
end)

it("the version gate sits in dispatch, so no handler can forget it", function()
  -- One gate rather than one per handler. A handler that had to check is a
  -- handler that could forget, and the answer does not vary by handler.
  local ctx = context()
  local seen = 0
  ctx.handlers = {
    function()
      seen = seen + 1
      return nil
    end,
  }

  expect.equal(#discovery.dispatch(ctx, 7, "hello"), 0, "a non-table gets nothing")
  expect.equal(#discovery.dispatch(ctx, 7, { kind = "status", v = 0 }), 0, "nor an impossible one")
  expect.equal(seen, 0, "and no handler was reached")

  expect.equal(#discovery.dispatch(ctx, 7, heartbeat()), 1, "a real message is answered")
  expect.equal(seen, 1, "and handlers ran")
end)

it("every reply leaving the server is stamped", function()
  -- Stamped once on the way out rather than at each `return` inside a handler:
  -- six handlers returning a table literal is six chances to omit a field whose
  -- absence means "pre-versioning build", which is a wrong answer that looks
  -- like a right one.
  local ctx = context()
  ctx.handlers = {
    function()
      return { kind = "extra" }
    end,
  }

  local replies = discovery.dispatch(ctx, 7, heartbeat())
  expect.equal(#replies, 2, "both the reply and the handler's")
  for _, reply in ipairs(replies) do
    expect.equal(reply.v, wire.VERSION, reply.kind .. " carries the wire version")
    expect.truthy(reply.build ~= nil, reply.kind .. " carries the build")
  end
end)

it("a device from ahead of the base is heard, not refused", function()
  -- The updater upgrades machines one at a time, so a turtle running a newer
  -- build than the base it reports to is the normal case during a rollout. A
  -- server that refused it would go blind to exactly the devices that upgraded
  -- first.
  local ctx = context()
  local ahead = heartbeat({ v = wire.VERSION + 1, build = "9.9.9" })

  expect.truthy(discovery.handle(ctx, 7, ahead), "answered")
  local record = registry.get(ctx.state.fleet, 7)
  expect.equal(record.build, "9.9.9", "and which build it is on was recorded")
  expect.equal(record.protocol, wire.VERSION + 1, "along with what it speaks")
end)

it("a device that stops reporting its build keeps the last one known", function()
  -- The same retention rule as the position, for the same reason: during a
  -- rollout "which devices are still on the old build" is the question being
  -- asked, and a heartbeat that happened to omit the field would answer it with
  -- a blank.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat({ build = "1.2.11" }))
  discovery.handle(ctx, 7, heartbeat())

  expect.equal(registry.get(ctx.state.fleet, 7).build, "1.2.11", "retained")
end)

it("an order set while a device is away is delivered when it returns", function()
  -- The whole desired-state model, exercised through the service that carries
  -- it: the failure Â§1 opens with is a recall that does nothing because the
  -- turtle was in an unloaded chunk.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat())

  local record = registry.get(ctx.state.fleet, 7)
  desired.want(record, "recall", nil, ctx.clock.now())
  expect.equal(desired.status(record, ctx.clock.now()), "pending", "asked for, not yet applied")

  -- Twenty minutes of silence. Nothing is retried, because nothing was sent.
  ctx._clock.advance(20 * 60)
  expect.equal(desired.status(record, ctx.clock.now()), "unreachable", "and plainly gone")

  -- It comes back. The order is in the reply because it was never a message.
  local reply = assert(discovery.handle(ctx, 7, heartbeat()))
  expect.equal(reply.desired.mode, "recall", "the order was waiting")

  -- The turtle's side, kept faithful to what `os/turtle/agent.lua` actually
  -- persists: the generation *and* the run of numbering it was minted under.
  -- Reporting the number alone would be a device claiming a count without
  -- saying whose count it is, which is the thing that made four turtles ignore
  -- recall from a rebuilt server.
  local turtle = { applied = 0 }
  local accepted = assert(desired.apply(turtle, reply.desired), "the turtle takes it")
  turtle.applied, turtle.epoch = accepted.generation, accepted.epoch

  local caughtUp = heartbeat({ applied = desired.report(turtle, "recall") })
  discovery.handle(ctx, 7, caughtUp)

  expect.equal(desired.status(record, ctx.clock.now()), "converged", "converged")
end)

it("a device running an older build is always behind, which is correct", function()
  -- It reports no applied generation because it does not know how to. Treating
  -- that as "caught up" would mark a fleet converged that had never heard of
  -- desired state.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat({ applied = nil }))
  local record = registry.get(ctx.state.fleet, 7)

  desired.want(record, "park", nil, ctx.clock.now())
  discovery.handle(ctx, 7, heartbeat({ applied = nil }))
  expect.equal(desired.status(record, ctx.clock.now()), "pending", "never converges on its own")
end)

it("a turtle that loses its origin does not lose its last known position", function()
  -- The phase 2 bug, now reachable through the service that would have caused
  -- it: `legacy/fleet/roster.lua` replaces the whole record, so a heartbeat with no
  -- world erases the last position the base knew.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat())

  ctx._clock.advance(30)
  local lost = heartbeat()
  lost.snapshot.world = nil
  discovery.handle(ctx, 7, lost)

  local record = registry.get(ctx.state.fleet, 7)
  expect.equal(record.location.x, 138, "still known")
  expect.equal(record.locatedAt, 1000 * SECOND, "and dated to when it was true")
end)
