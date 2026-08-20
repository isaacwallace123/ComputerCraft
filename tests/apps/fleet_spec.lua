local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")
local page = require("support.page")

local desired = require("domain.fleet.desired")
local discovery = require("os.server.services.discovery")
local fleetApp = require("apps.fleet.app")
local appRegistry = require("apps.registry")
local registry = require("domain.fleet.registry")

local context = fleet.context
local heartbeat = fleet.heartbeat
local optionsPassedTo = page.optionsPassedTo

---------------------------------------------------------------------------
-- The Fleet page
---------------------------------------------------------------------------

it("a device that has gone quiet is not shown as still mining", function()
  -- Its last word was "mining" and it has not been heard from since. Showing
  -- that as current is how three missing miners looked like three busy ones.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat())

  local working = fleetApp.rows(ctx.state, ctx.clock.now())
  expect.equal(working[1].phase, "mining", "while it is talking")

  ctx._clock.advance(5 * 60)
  local quiet = fleetApp.rows(ctx.state, ctx.clock.now())
  expect.equal(quiet[1].phase, "offline", "and offline once it is not")
  expect.falsy(quiet[1].online, "marked offline")
end)

it("the fleet list is stable, unlike the devices list", function()
  -- Devices sorts by staleness because it is the page you open when something
  -- is wrong. This is the page you leave open, and rows that reorder themselves
  -- while somebody is glancing at a wall monitor make it unreadable.
  local ctx = context()
  discovery.handle(ctx, 2, heartbeat({ snapshot = { label = "miner-9", phase = "mining" } }))
  discovery.handle(ctx, 3, heartbeat({ snapshot = { label = "miner-10", phase = "mining" } }))

  local before = fleetApp.rows(ctx.state, ctx.clock.now())
  expect.equal(before[1].label, "miner-9", "natural order, so 10 follows 9")
  expect.equal(before[2].label, "miner-10", "and not before it")

  -- One goes quiet. The order must not change.
  ctx._clock.advance(5 * 60)
  discovery.handle(ctx, 3, heartbeat({ snapshot = { label = "miner-10", phase = "mining" } }))
  local after = fleetApp.rows(ctx.state, ctx.clock.now())
  expect.equal(after[1].label, "miner-9", "same row")
  expect.equal(after[2].label, "miner-10", "same order")
end)

it("no fuel reading shows an empty meter, not a full one", function()
  -- The floor is chosen to be honest rather than flattering: a meter that
  -- defaulted to full would hide the turtle that is about to strand itself.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat({ snapshot = { label = "miner-7", phase = "mining" } }))
  expect.equal(fleetApp.rows(ctx.state, ctx.clock.now())[1].fuel, 0, "empty")
end)

it("a device with an order it cannot hear is flagged, which it cannot report itself", function()
  -- The device cannot say "I have stopped talking to you". Only the base knows.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat())
  desired.want(registry.get(ctx.state.fleet, 7), "recall", nil, ctx.clock.now())

  expect.falsy(fleetApp.rows(ctx.state, ctx.clock.now())[1].alert, "not yet - it is still talking")
  ctx._clock.advance(20 * 60)
  expect.truthy(fleetApp.rows(ctx.state, ctx.clock.now())[1].alert, "flagged once it goes quiet")
end)

--- Capture what an app hands its view, rather than what the view built.
---
--- `mount` returns a node tree, so asserting `page.onDeploy` on its return is
--- always nil and always passes - which is how the first version of the test

it("a read-only surface gets no actions at all", function()
  -- D020 is a safety boundary: a wall monitor must not be able to send
  -- commands. It was open. `readOnly and nil or fn` reads like a guard and is
  -- not one - `true and nil` is nil, and `nil or fn` is fn - so every callback
  -- was passed on every surface, in three apps, since each was written.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat())
  ctx.transport = { broadcast = function() end, send = function() end }

  local pairsToCheck = {
    { require("apps.fleet.app"), require("apps.fleet.view"), "fleet" },
    { require("apps.devices.app"), require("apps.devices.view"), "devices" },
  }

  for _, entry in ipairs(pairsToCheck) do
    local passed = assert(optionsPassedTo(entry[1], entry[2], ctx, { readOnly = true }))
    for _, name in ipairs({ "onDeploy", "onRecall", "onStop", "onJob", "onSetting" }) do
      expect.equal(passed[name], nil, entry[3] .. " passes no " .. name)
    end
  end
end)

it("an interactive surface does get them", function()
  -- The other half. A guard that removed the actions everywhere would pass the
  -- test above and leave the page useless.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat())
  ctx.transport = { broadcast = function() end, send = function() end }

  local passed =
    assert(optionsPassedTo(require("apps.fleet.app"), require("apps.fleet.view"), ctx, {}))
  expect.truthy(passed.onRecall, "recall is available where somebody can press it")
  expect.truthy(passed.onDeploy, "and so is deploy")
end)

it("a fleet action asks the server for a goal, never the device for an action", function()
  -- D018 and section 5 together: an app that sent orders to devices would be an
  -- app whose being closed changed what the fleet was doing.
  local message = assert(fleetApp.intent(7, "recall"), "built a message")
  expect.equal(message.kind, "want", "asks the server to want it")
  expect.equal(message.id, 7, "of that device")
  expect.equal(fleetApp.intent(7, "explode"), nil, "and refuses a mode that does not exist")
end)

it("the fleet page is allowed on a monitor, and devices actions are not forced on it", function()
  -- D020 as a registry entry rather than as a branch: this is the page meant to
  -- be left on a wall, and `readOnly` is what the shell hands a surface with no
  -- keyboard.
  local entry = appRegistry.find("fleet") or {}
  local surfaces = {}
  for _, name in ipairs(entry.surfaces or {}) do
    surfaces[name] = true
  end
  expect.truthy(surfaces.monitor, "it may appear on a monitor")

  -- And its identity lives in one place. There used to be an `app.manifest`
  -- saying the same thing, which is two descriptions of one app and therefore
  -- one of them eventually wrong.
  expect.equal(fleetApp.manifest, nil, "the module describes nothing about itself")
end)
