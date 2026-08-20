local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local bridge = require("os.server.services.bridge")
local desired = require("domain.fleet.desired")
local discovery = require("os.server.services.discovery")
local leases = require("os.server.services.leases")
local reconcile = require("os.server.services.reconcile")
local registry = require("domain.fleet.registry")
local wire = require("domain.protocol.message")

local bridgeContext = fleet.bridge
local configuredMine = fleet.mine
local heartbeat = fleet.heartbeat
local legacy = fleet.legacy
local legacySnapshot = fleet.legacySnapshot
local serverContext = fleet.server

---------------------------------------------------------------------------
-- The bridge: an ICOS 1 fleet under an ICOS 2 server
---------------------------------------------------------------------------

it("the two protocols are different, which is the whole reason this exists", function()
  -- Not a tautology. The dual run in Â§12 sends the old *message shape* on the
  -- new *protocol name*, which reaches only devices that already speak ICOS 2 -
  -- so it protected nobody, and this is the assertion that says why a bridge is
  -- needed at all.
  expect.truthy(wire.NAME ~= wire.LEGACY_NAME, "ICOS 1 and ICOS 2 are on separate protocols")
  expect.equal(bridge.PROTOCOL, wire.LEGACY_NAME, "and the bridge listens on the old one")
  expect.equal(discovery.PROTOCOL, wire.NAME, "while discovery listens on the new one")
end)

it("an ICOS 1 heartbeat puts the device in the registry", function()
  -- Without this the fleet vanishes from its own base the moment the server is
  -- switched over: no registry, so no Devices page, so no recall.
  local ctx = bridgeContext()
  bridge.handle(ctx, 3, legacy("hello", legacySnapshot()), ctx.toCommand)

  local record = registry.get(ctx.state.fleet, 3)
  expect.truthy(record, "recorded")
  expect.equal(record.location.x, 12, "with where it is")
  expect.truthy(record.legacy, "and marked as a device that cannot speak the new protocol")
end)

it("a pending order reaches an ICOS 1 device as an ICOS 1 command", function()
  local ctx = bridgeContext()
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)

  local record = registry.get(ctx.state.fleet, 3)
  desired.want(record, "recall", nil, ctx.clock.now())

  local out = bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  expect.equal(#out, 1, "one message back")
  expect.equal(out[1].kind, "command", "in the envelope ICOS 1 acts on")
  expect.equal(out[1].body.action, "recall", "carrying the order it understands")
end)

it("a converged ICOS 1 device is told nothing", function()
  local ctx = bridgeContext()
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  local quiet = bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  expect.equal(#quiet, 0, "silent")
end)

it("an ICOS 1 device converges on its command result, not on being sent one", function()
  -- ICOS 1 reports no applied generation, so it can never converge the way an
  -- ICOS 2 device does and would be commanded forever. Its acknowledgement is
  -- the same information by a different route. Marking it converged when the
  -- command went out would be the "sent" status Â§5 exists to abolish.
  local ctx = bridgeContext()
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  local record = registry.get(ctx.state.fleet, 3)
  desired.want(record, "recall", nil, ctx.clock.now())

  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  expect.equal(desired.status(record, ctx.clock.now()), "pending", "still pending once sent")

  bridge.handle(ctx, 3, legacy("command_result", { action = "recall", ok = true }), ctx.toCommand)
  expect.equal(desired.status(record, ctx.clock.now()), "converged", "converged on the result")
end)

it("a refused command stays pending", function()
  -- "recall this turtle before changing its job" is a real answer an ICOS 1
  -- turtle gives, and treating it as convergence would hide an order that was
  -- never carried out.
  local ctx = bridgeContext()
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  local record = registry.get(ctx.state.fleet, 3)
  desired.want(record, "deploy", { job = "quarry" }, ctx.clock.now())
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)

  bridge.handle(
    ctx,
    3,
    legacy("command_result", { action = "assign_job", ok = false, message = "recall first" }),
    ctx.toCommand
  )
  expect.equal(desired.status(record, ctx.clock.now()), "pending", "not converged")
  expect.falsy(record.lastResult.ok, "and the refusal is on the record")
end)

it("an order set while an acknowledgement was in flight stays pending", function()
  -- The generation that was *sent* is what a result acknowledges. Using the
  -- currently wanted one would let a reply to the old order mark the new one
  -- applied, which is the reordering hazard D004's best-effort radio makes real.
  local ctx = bridgeContext()
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  local record = registry.get(ctx.state.fleet, 3)

  desired.want(record, "recall", nil, ctx.clock.now())
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)

  ctx._clock.advance(1)
  desired.want(record, "update", nil, ctx.clock.now())
  bridge.handle(ctx, 3, legacy("command_result", { action = "recall", ok = true }), ctx.toCommand)

  expect.equal(desired.status(record, ctx.clock.now()), "pending", "the newer order is untouched")
end)

it("the same order is not resent on every two-second heartbeat", function()
  local ctx = bridgeContext()
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  desired.want(registry.get(ctx.state.fleet, 3), "recall", nil, ctx.clock.now())

  local first = bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  expect.equal(#first, 1, "sent")

  ctx._clock.advance(2)
  local soon = bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  expect.equal(#soon, 0, "throttled")

  ctx._clock.advance(bridge.EVERY)
  local again = bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  expect.equal(#again, 1, "resent once the throttle has elapsed")
end)

it("a goal with no ICOS 1 equivalent is not faked", function()
  -- `park` has no old command. Sending nothing and recording nothing leaves the
  -- device honestly pending; inventing a command for a build that would not
  -- understand it is a message into the void that looks like delivery.
  local ctx = bridgeContext()
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  local record = registry.get(ctx.state.fleet, 3)
  desired.want(record, "park", nil, ctx.clock.now())

  local out = bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  expect.equal(#out, 0, "nothing sent")
  expect.equal(desired.status(record, ctx.clock.now()), "pending", "and it stays pending")
end)

it("an ICOS 1 mine request is answered in an ICOS 1 envelope", function()
  -- The fleet stops being able to ask where to dig if this does not work, which
  -- is the half of the outage that would not have shown up on the dashboard.
  local ctx = configuredMine(bridgeContext())

  local out = bridge.handle(
    ctx,
    3,
    legacy("mine", { action = "claim", workKey = "rare@-59", requestId = 9 }),
    ctx.toCommand
  )

  expect.equal(#out, 1, "answered")
  expect.equal(out[1].kind, "mine_result", "with the kind ICOS 1 listens for")
  expect.truthy(out[1].body.ok, "granted")
  expect.truthy(out[1].body.sector, "and it names a sector")
end)

it("a mine can be configured over the wire, which is the only way ICOS 2 gets one", function()
  -- Until this existed an ICOS 2 base could lease sectors from a plan but had
  -- no way to be given one - `mine at` lived in the ICOS 1 console and nowhere
  -- else. An in-world test found it the direct way: every deploy refused with
  -- "no mine configured at base".
  local ctx = bridgeContext()
  expect.falsy(ctx.state.mine.plan.configured, "no mine to begin with")

  local reply = leases.handle(ctx, 7, {
    kind = leases.MINE,
    body = { action = "configure", centreX = 50, centreZ = 50, surfaceY = 64, requestId = 1 },
  })

  expect.truthy(reply and reply.ok, "accepted")
  expect.truthy(ctx.state.mine.plan.configured, "and the server has a mine")
  expect.equal(ctx.state.mine.plan.centreX, 50, "where it was told")
end)

it("an ICOS 1 console can configure an ICOS 2 server", function()
  -- The payoff of `configure` being a `mine` action rather than a message of
  -- its own: it crosses the bridge unaltered, so the migration is reversible in
  -- both directions rather than only forwards.
  local ctx = bridgeContext()

  local out = bridge.handle(
    ctx,
    7,
    legacy("mine", { action = "configure", centreX = -120, centreZ = 64, surfaceY = 70 }),
    ctx.toCommand
  )

  expect.equal(#out, 1, "answered")
  expect.equal(out[1].kind, "mine_result", "in the envelope ICOS 1 reads")
  expect.truthy(ctx.state.mine.plan.configured, "and the mine was placed")
  expect.equal(ctx.state.mine.plan.centreX, -120, "at the coordinates given")
end)

it("moving a configured mine reports that it discarded the progress", function()
  -- Somebody needs to be told that a day of sector progress was thrown away on
  -- purpose, and the console is where they will be standing when it happens.
  local ctx = bridgeContext()
  leases.handle(ctx, 7, {
    kind = leases.MINE,
    body = { action = "configure", centreX = 0, centreZ = 0, surfaceY = 64 },
  })

  local reply = assert(
    leases.handle(ctx, 7, {
      kind = leases.MINE,
      body = { action = "configure", centreX = 500, centreZ = 500, surfaceY = 64 },
    }),
    "answered"
  )

  expect.truthy(reply.moved, "said so")
end)

it("an ICOS 1 heartbeat renews the lease it already holds", function()
  -- Otherwise every turtle loses its sector fifteen minutes after the server
  -- starts, and two of them are sent down one shaft.
  local ctx = configuredMine(bridgeContext())
  bridge.handle(
    ctx,
    3,
    legacy("mine", { action = "claim", workKey = "rare@-59", sector = 4 }),
    ctx.toCommand
  )

  ctx._clock.advance(60)
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)

  local held = ctx.state.mine.sectors["4"]
  expect.truthy(held and held.holder == 3, "still held by the same turtle")
  expect.equal(held.leasedAt, ctx.clock.now(), "with the lease renewed from the heartbeat")
end)

it("rubbish on the old protocol is dropped, not raised", function()
  local ctx = bridgeContext()
  expect.equal(#bridge.handle(ctx, 3, "hello", ctx.toCommand), 0, "not a table")
  expect.equal(#bridge.handle(ctx, 3, { body = {} }, ctx.toCommand), 0, "no kind")
  expect.equal(#bridge.handle(ctx, 3, legacy("status", nil), ctx.toCommand), 0, "no snapshot")
  expect.equal(#bridge.handle(ctx, 3, legacy("fleet_sync", {}), ctx.toCommand), 0, "not ours")
  expect.equal(registry.get(ctx.state.fleet, 3), nil, "and nothing was recorded")
end)

it("reconcile leaves legacy devices to the bridge", function()
  -- A nudge from `reconcile` goes out on the new protocol, which an ICOS 1
  -- device is not listening to. Including one here would count an order as
  -- delivered that was never heard.
  local ctx = bridgeContext()
  bridge.handle(ctx, 3, legacy("status", legacySnapshot()), ctx.toCommand)
  discovery.handle(ctx, 7, heartbeat())

  desired.want(registry.get(ctx.state.fleet, 3), "recall", nil, ctx.clock.now())
  desired.want(registry.get(ctx.state.fleet, 7), "recall", nil, ctx.clock.now())

  local due = reconcile.due(ctx, ctx.clock.now())
  expect.equal(#due, 1, "only the ICOS 2 device")
  expect.equal(due[1].id, 7, "and it is the right one")
end)

it("only devices that are behind and reachable are nudged", function()
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())
  discovery.handle(ctx, 8, heartbeat())

  expect.equal(#reconcile.due(ctx, ctx.clock.now()), 0, "nothing is behind yet")

  desired.want(registry.get(ctx.state.fleet, 7), "recall", nil, ctx.clock.now())
  local due = reconcile.due(ctx, ctx.clock.now())
  expect.equal(#due, 1, "only the one with an outstanding order")
  expect.equal(due[1].id, 7, "and it is the right one")

  -- A device that has gone quiet cannot hear a nudge, so sending one is only
  -- noise. It will reconcile on its own when it comes back, which is the point.
  ctx._clock.advance(300)
  expect.equal(#reconcile.due(ctx, ctx.clock.now()), 0, "an offline device is not nudged")
end)

it("a device is not nudged more often than the interval", function()
  local ctx = serverContext({ nudgeEvery = 6 })
  discovery.handle(ctx, 7, heartbeat())
  desired.want(registry.get(ctx.state.fleet, 7), "recall", nil, ctx.clock.now())

  expect.equal(reconcile.pass(ctx, ctx.clock.now()), 1, "nudged")
  expect.equal(reconcile.pass(ctx, ctx.clock.now()), 0, "not again immediately")

  ctx._clock.advance(7)
  expect.equal(reconcile.pass(ctx, ctx.clock.now()), 1, "and again once the interval has passed")
end)

it("a nudge carries both the new reply and the old command", function()
  -- Â§12's dual run. A turtle on the old build obeys the command and never
  -- reports an applied generation; one on the new build applies the generation
  -- and converges. Both are correct at once, so the fleet upgrades a turtle at
  -- a time.
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())
  desired.want(registry.get(ctx.state.fleet, 7), "recall", nil, ctx.clock.now())
  reconcile.pass(ctx, ctx.clock.now())

  expect.equal(#ctx._sent, 2, "two messages")
  expect.equal(ctx._sent[1].message.kind, "desired", "the goal")
  expect.equal(ctx._sent[2].message.command.action, "recall", "and the old command beside it")
end)

it("turning events off is what ends the dual run", function()
  local ctx = serverContext({ events = false })
  discovery.handle(ctx, 7, heartbeat())
  desired.want(registry.get(ctx.state.fleet, 7), "recall", nil, ctx.clock.now())
  reconcile.pass(ctx, ctx.clock.now())

  expect.equal(#ctx._sent, 1, "only the goal")
  expect.equal(ctx._sent[1].message.kind, "desired", "and it is the new one")
end)

it("a deploy carries its job, because the old protocol needs all three pieces", function()
  -- Â§5 collapses the set-job / configure / deploy dance into one record. A
  -- device on the old build still needs all of it, so the legacy command is the
  -- one that carries everything.
  local command =
    assert(reconcile.legacy({ mode = "deploy", job = "rare", settings = { targetY = -59 } }))
  expect.equal(command.action, "assign_job", "assigned rather than merely deployed")
  expect.equal(command.job, "rare", "with the job")
  expect.equal(command.settings.targetY, -59, "and the settings")

  expect.equal(assert(reconcile.legacy({ mode = "deploy" })).action, "deploy", "a bare deploy")
  -- The old protocol cannot say "stop when convenient", and inventing a command
  -- a build will not understand is a message into the void.
  expect.equal(reconcile.legacy({ mode = "park" }), nil, "park has no equivalent")
  expect.equal(reconcile.legacy(nil), nil, "and neither does no goal at all")
end)
