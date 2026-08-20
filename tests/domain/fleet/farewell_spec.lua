--- Telling a planned shutdown from a machine that fell in lava.

local expect = require("support.expect")
local fleet = require("support.fleet")
local it = require("support.spec").it

local devicesApp = require("apps.fleet.app")
local discovery = require("os.server.services.discovery")
local registry = require("domain.fleet.registry")

it("a device that said goodbye reads as off, not offline", function()
  -- §6's subject is telling "we do not know where miner-7 is" from "there is no
  -- miner-7". A planned shutdown was the case it was missing: powered down for
  -- maintenance looked identical to fell in lava, so the dashboard raised the
  -- same alarm for both - which is how somebody learns to ignore the alarm.
  local ctx = fleet.server()
  discovery.handle(ctx, 7, fleet.heartbeat())

  local record = registry.get(ctx.state.fleet, 7)
  expect.equal(registry.health(record, ctx.clock.now()), "online", "reporting")

  discovery.handle(ctx, 7, { kind = discovery.FAREWELL })
  expect.equal(registry.health(record, ctx.clock.now()), "off", "and switched off on purpose")

  -- The distinction has to survive time passing, or it is only true for a
  -- minute and the page goes back to lying afterwards.
  ctx._clock.advance(30 * 60)
  expect.equal(registry.health(record, ctx.clock.now()), "off", "still off half an hour later")
end)

it("a device that comes back is not off any more", function()
  -- Nothing clears the flag, on purpose. Comparing the farewell against the
  -- last heartbeat means there is no bookkeeping to forget - and bookkeeping
  -- like that gets forgotten exactly once.
  local ctx = fleet.server()
  discovery.handle(ctx, 7, fleet.heartbeat())
  discovery.handle(ctx, 7, { kind = discovery.FAREWELL })

  ctx._clock.advance(60)
  discovery.handle(ctx, 7, fleet.heartbeat())

  local record = registry.get(ctx.state.fleet, 7)
  expect.equal(registry.health(record, ctx.clock.now()), "online", "back on")
end)

it("the Devices page says shut down rather than offline", function()
  local ctx = fleet.server()
  discovery.handle(ctx, 7, { kind = "status", snapshot = { phase = "mining" } })
  discovery.handle(ctx, 7, { kind = discovery.FAREWELL })

  local row = devicesApp.row(registry.get(ctx.state.fleet, 7), ctx.clock.now())
  expect.equal(row.phase, "shut down", "and does not claim it is still mining")
end)

it("a farewell from a device nobody knows is not an error", function()
  -- A machine that was never on this base's roster can still be switched off.
  -- Inventing a record for it would put a device on the page that does not
  -- exist, which is the one thing a fleet dashboard must never do.
  local ctx = fleet.server()
  expect.falsy(discovery.handle(ctx, 99, { kind = discovery.FAREWELL }), "no reply")
  expect.falsy(registry.get(ctx.state.fleet, 99), "and nothing invented")
end)

it("saying goodbye is answered with silence", function()
  -- The device is already powering down. A reply would be a message into a
  -- machine that is gone, which is how a server collects undeliverable replies.
  local ctx = fleet.server()
  discovery.handle(ctx, 7, fleet.heartbeat())
  expect.falsy(discovery.handle(ctx, 7, { kind = discovery.FAREWELL }), "nothing sent back")
end)
