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

it("the list is ordered by name and stays there while devices change", function()
  -- This list used to lead with the stalest device. In a live fleet that key -
  -- seconds since the last heartbeat - moves continuously on every row, so two
  -- rows swap past each other every time one of them checks in. With a
  -- heartbeat every couple of seconds the list never stops reordering, under
  -- the cursor, between reading a row and clicking it.
  local ctx = context()
  discovery.handle(ctx, 2, heartbeat({ snapshot = { label = "miner-9", phase = "mining" } }))
  discovery.handle(ctx, 3, heartbeat({ snapshot = { label = "miner-10", phase = "mining" } }))

  local before = fleetApp.rows(ctx.state, ctx.clock.now())
  expect.equal(before[1].label, "miner-9", "natural order, so 9 comes before 10")
  expect.equal(before[2].label, "miner-10", "and not after it, the way plain string order would have it")

  -- miner-9 checks in and miner-10 does not, so miner-10 is now the stalest -
  -- which is exactly what used to drag it to the top of the list.
  ctx._clock.advance(30)
  discovery.handle(ctx, 2, heartbeat({ snapshot = { label = "miner-9", phase = "mining" } }))

  local after = fleetApp.rows(ctx.state, ctx.clock.now())
  expect.equal(after[1].label, "miner-9", "same row")
  expect.equal(after[2].label, "miner-10", "same order - the news does not move the furniture")
end)

it("a device with no label at all still sorts somewhere fixed", function()
  -- A turtle that has never been named reports no label, and sorting nil is an
  -- error rather than a bad order. It falls back to its id.
  local ctx = context()
  discovery.handle(ctx, 4, heartbeat({ snapshot = { label = "miner-4", phase = "mining" } }))
  discovery.handle(ctx, 11, heartbeat({ snapshot = { phase = "mining" } }))

  local rows = fleetApp.rows(ctx.state, ctx.clock.now())
  expect.equal(#rows, 2, "both are listed")
  expect.truthy(fleetApp.sortKey(rows[1]) < fleetApp.sortKey(rows[2]), "and the order is decidable")
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

  local passed = assert(
    optionsPassedTo(require("apps.fleet.app"), require("apps.fleet.view"), ctx, { readOnly = true })
  )
  for _, name in ipairs({ "onDeploy", "onRecall", "onStop" }) do
    expect.equal(passed[name], nil, "fleet passes no " .. name)
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

it("an order is for the fleet, and carries no device at all", function()
  -- D018 and section 5 together: an app that sent orders to devices would be an
  -- app whose being closed changed what the fleet was doing.
  local message = assert(fleetApp.intent("recall"), "built a message")
  expect.equal(message.kind, "want", "asks the server to want it")

  -- The absence is the design. Turtles are dispatched, fuelled, assigned ground
  -- and recalled as a unit, so an order names the mode and nothing else - and
  -- the server keeps it, which is what makes a turtle that boots a minute later
  -- do what everybody else was told.
  expect.equal(message.id, nil, "of everybody")
  expect.equal(fleetApp.intent("explode"), nil, "and it refuses a mode that does not exist")
end)

it("the fleet page is allowed on a monitor, and its actions are not forced on it", function()
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

it("a screen is not on the fleet roster, because it takes no orders", function()
  -- The roster is every machine that talks to the server, which since clients
  -- started introducing themselves includes the screens - and a screen on a page
  -- with Deploy and Recall on it is a row somebody will eventually click and
  -- expect something from.
  --
  -- The test is the one the server already uses to decide who gets a goal.
  -- A server context rather than the bare one: answering a mirror reaches the
  -- policy service, which reads the disk.
  local ctx = fleet.server()
  discovery.handle(ctx, 7, heartbeat())
  discovery.handle(ctx, 9, {
    kind = "mirror",
    snapshot = { label = "screen", role = "client", orders = false },
  })

  local rows = fleetApp.rows(ctx.state, ctx.clock.now())
  expect.equal(#rows, 1, "the turtle, and only the turtle")
  expect.equal(rows[1].label, "miner-7")
end)

it("a device that predates the field is still on the roster", function()
  -- Absent means yes. Every turtle in the world was built before anything said
  -- whether it took orders, and a missing field must not quietly empty the page.
  local ctx = context()
  discovery.handle(ctx, 7, heartbeat())
  expect.equal(#fleetApp.rows(ctx.state, ctx.clock.now()), 1)
end)

it("the status column says parked, and why is a sentence for the panel", function()
  -- The column is twelve cells and `parked: setup` arrives in it as
  -- `parked: setu` - a word cut in half, on every row, saying less than the word
  -- it was cut from.
  local ctx = context()
  discovery.handle(
    ctx,
    7,
    heartbeat({
      snapshot = {
        label = "miner-7",
        parked = true,
        parkKind = "setup",
        parkReason = "run `commands/locate` on this turtle before posting it",
      },
    })
  )

  local row = fleetApp.rows(ctx.state, ctx.clock.now())[1]
  expect.equal(row.phase, "parked")
  expect.contains(row.parkReason, "commands/locate", "and the reason is kept for the panel")
end)
