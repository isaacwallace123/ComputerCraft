local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local devicesApp = require("apps.fleet.app")
local devicesView = require("apps.fleet.view")
local discovery = require("os.server.services.discovery")
local jobs = require("domain.turtle.jobs")
local registry = require("domain.fleet.registry")

local heartbeat = fleet.heartbeat
local serverContext = fleet.server

---------------------------------------------------------------------------
-- The Devices app: reads a mirror, writes a goal, owns nothing
---------------------------------------------------------------------------

it("the quietest device is first, because that is the one worth seeing", function()
  -- Â§6: a roster sorted by name buries the one device that has stopped
  -- reporting among nine that are fine.
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())
  ctx._clock.advance(600)
  discovery.handle(ctx, 8, heartbeat())
  discovery.handle(ctx, 9, heartbeat())

  local rows = devicesApp.rows(ctx.state, ctx.clock.now())
  expect.equal(#rows, 3, "all three")
  expect.equal(rows[1].id, 7, "the quiet one first")
  expect.truthy(rows[1].since > rows[2].since, "and the order is by age")
end)

it("a device that has gone quiet does not claim to still be mining", function()
  -- "mining" on a device nobody has heard from in twenty minutes is a claim the
  -- server cannot support, and is exactly how a dashboard misleads somebody.
  local ctx = serverContext()
  discovery.handle(ctx, 7, { kind = "status", snapshot = { phase = "mining" } })

  local row = devicesApp.row(registry.get(ctx.state.fleet, 7), ctx.clock.now())
  expect.equal(row.phase, "mining", "while it is reporting")

  ctx._clock.advance(20 * 60)
  row = devicesApp.row(registry.get(ctx.state.fleet, 7), ctx.clock.now())
  expect.equal(row.phase, "offline", "and not once it has stopped")
  expect.falsy(row.online, "with the flag agreeing")
end)

it("a button press sets a goal for the whole fleet rather than sending an order", function()
  -- The difference section 5 exists to make: a press dropped by a radio is
  -- retried by reconcile, and the page has no "sent" state because "sent" was
  -- never the honest word for it.
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())
  discovery.handle(ctx, 8, heartbeat({ snapshot = { label = "miner-8" } }))

  local reply = assert(discovery.handle(ctx, 1, devicesApp.intent("recall")))
  expect.truthy(reply.ok, "accepted")
  expect.equal(reply.changed, 2, "and it changed both of them")
  expect.equal(registry.get(ctx.state.fleet, 7).desired.mode, "recall")
  expect.equal(registry.get(ctx.state.fleet, 8).desired.mode, "recall", "as a unit")
end)

it("a device that registers afterwards is told what everybody else was told", function()
  -- The reason the server keeps the goal instead of fanning it out once. A
  -- turtle that boots a minute after somebody pressed Deploy used to sit parked
  -- forever, and nothing on any screen said why - the order it missed lived only
  -- in the goals of the devices that happened to be listening.
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())
  discovery.handle(ctx, 1, devicesApp.intent("recall"))

  discovery.handle(ctx, 9, heartbeat({ snapshot = { label = "miner-9" } }))
  expect.equal(registry.get(ctx.state.fleet, 9).desired.mode, "recall", "it caught up on arrival")
end)

it("pressing the same button twice is not a failure", function()
  -- Reporting it as one would make a second click on Recall look like something
  -- went wrong when the correct answer is "it is already recalled".
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  discovery.handle(ctx, 1, devicesApp.intent("recall"))
  local again = assert(discovery.handle(ctx, 1, devicesApp.intent("recall")))

  expect.truthy(again.ok, "still ok")
  expect.equal(again.changed, 0, "but nothing changed")
  expect.equal(registry.get(ctx.state.fleet, 7).desired.generation, 1, "and no new generation")
end)

it("an order to an empty fleet changes nothing and invents nobody", function()
  -- The whole point of section 6 is telling "there is no miner-7" from "we do
  -- not know where miner-7 is". A goal is kept for whoever turns up; it never
  -- creates a record, because a device on the roster that does not exist is the
  -- one thing a fleet dashboard must not show.
  local ctx = serverContext()
  local reply = assert(discovery.handle(ctx, 1, devicesApp.intent("recall")))

  expect.truthy(reply.ok, "accepted - there is simply nobody yet")
  expect.equal(reply.changed, 0)
  expect.equal(#registry.list(ctx.state.fleet, ctx.clock.now()), 0, "with nothing invented")
end)

it("a nonsense mode is refused loudly", function()
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  expect.falsy(devicesApp.intent("explode"), "not even built")

  local reply = assert(discovery.handle(ctx, 1, { kind = "want", mode = "explode" }))
  expect.falsy(reply.ok, "and the server refuses it too")
end)
