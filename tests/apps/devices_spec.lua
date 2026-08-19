local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local devicesApp = require("apps.devices.app")
local devicesView = require("apps.devices.view")
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

it("a button press sets a goal rather than sending an order", function()
  -- The difference Â§5 exists to make: a press dropped by a radio is retried by
  -- reconcile, and the page has no "sent" state because "sent" was never the
  -- honest word for it.
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  local reply = assert(discovery.handle(ctx, 1, devicesApp.intent({ id = 7 }, "recall")))
  expect.truthy(reply.ok, "accepted")
  expect.truthy(reply.changed, "and it changed something")
  expect.equal(registry.get(ctx.state.fleet, 7).desired.mode, "recall", "the goal is set")
end)

it("pressing the same button twice is not a failure", function()
  -- Reporting it as one would make a second click on Recall look like something
  -- went wrong when the correct answer is "it is already recalled".
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  discovery.handle(ctx, 1, devicesApp.intent({ id = 7 }, "recall"))
  local again = assert(discovery.handle(ctx, 1, devicesApp.intent({ id = 7 }, "recall")))

  expect.truthy(again.ok, "still ok")
  expect.falsy(again.changed, "but nothing changed")
  expect.equal(registry.get(ctx.state.fleet, 7).desired.generation, 1, "and no new generation")
end)

it("a device the server has never heard of is refused, not invented", function()
  -- The whole point of Â§6 is telling "there is no miner-7" from "we do not know
  -- where miner-7 is". Creating a record from a click destroys that.
  local ctx = serverContext()
  local reply = assert(discovery.handle(ctx, 1, devicesApp.intent({ id = 99 }, "recall")))

  expect.falsy(reply.ok, "refused")
  expect.contains(reply.message, "no such device", "and it says why")
  expect.falsy(registry.get(ctx.state.fleet, 99), "with nothing invented")
end)

it("a nonsense mode is refused loudly", function()
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  expect.falsy(devicesApp.intent({ id = 7 }, "explode"), "not even built")
  expect.falsy(devicesApp.intent(nil, "recall"), "nor with nothing selected")

  local reply = assert(discovery.handle(ctx, 1, { kind = "want", id = 7, mode = "explode" }))
  expect.falsy(reply.ok, "and the server refuses it too")
end)

it("the job picker offers what the catalogue lists, not a copy of it", function()
  -- It used to be a hard-coded list with a comment admitting it was a copy. A
  -- picker offering a job no turtle has produces a refusal somebody has to
  -- interpret, and it happened every time a job was added and the copy was not.
  expect.equal(#devicesView.JOBS, #jobs.list(), "same length")
  for index, entry in ipairs(jobs.list()) do
    expect.equal(devicesView.JOBS[index], entry.id, "same order: " .. entry.id)
  end
end)
