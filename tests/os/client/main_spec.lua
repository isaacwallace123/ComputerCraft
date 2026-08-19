local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")
local SECOND = fleet.SECOND

local client = require("os.client.main")
local discovery = require("os.server.services.discovery")
local registry = require("domain.fleet.registry")

local fakeClock = fleet.clock
local fakePorts = fleet.ports
local heartbeat = fleet.heartbeat
local serverContext = fleet.server

---------------------------------------------------------------------------
-- The client: a mirror that admits how old it is
---------------------------------------------------------------------------

it("a client mirrors the server and knows how stale the copy is", function()
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  local clock = fakeClock(1000 * SECOND)
  local machine = client.boot(fakePorts(clock))

  expect.equal(client.staleness(machine.context, clock.port.now()), math.huge, "never synced")

  local reply = assert(discovery.handle(ctx, 1, { kind = client.REQUEST }))
  expect.truthy(client.absorb(machine.context, reply), "absorbed")
  expect.equal(client.staleness(machine.context, clock.port.now()), 0, "and it is fresh")

  local rows = client.rows(machine.context, clock.port.now())
  expect.equal(#rows, 1, "one device in the mirror")
  expect.equal(rows[1].id, 7, "and it is the one that reported")
end)

it("a device the server has forgotten does not live on in the client", function()
  -- The mirror replaces rather than merges. "This turtle no longer exists" is
  -- exactly the kind of fact a dashboard must not quietly discard.
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  local clock = fakeClock(1000 * SECOND)
  local machine = client.boot(fakePorts(clock))
  client.absorb(machine.context, assert(discovery.handle(ctx, 1, { kind = client.REQUEST })))
  expect.equal(#client.rows(machine.context, clock.port.now()), 1, "seen once")

  registry.forget(ctx.state.fleet, 7)
  client.absorb(machine.context, assert(discovery.handle(ctx, 1, { kind = client.REQUEST })))
  expect.equal(#client.rows(machine.context, clock.port.now()), 0, "and gone when it is gone")
end)

it("a client that has lost its server keeps drawing, with the ages ticking up", function()
  -- Strictly more useful than a blank screen, and only honest because the
  -- staleness is on the record rather than implied.
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  local clock = fakeClock(1000 * SECOND)
  local machine = client.boot(fakePorts(clock))
  client.absorb(machine.context, assert(discovery.handle(ctx, 1, { kind = client.REQUEST })))

  clock.advance(5 * 60)
  expect.equal(client.staleness(machine.context, clock.port.now()), 300, "five minutes behind")

  local rows = client.rows(machine.context, clock.port.now())
  expect.equal(rows[1].health, "offline", "and the row says so itself")

  expect.truthy(machine.supervisor:healthy(), "the client is not broken, just alone")
end)

it("a client refuses nonsense without losing what it had", function()
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  local clock = fakeClock(1000 * SECOND)
  local machine = client.boot(fakePorts(clock))
  client.absorb(machine.context, assert(discovery.handle(ctx, 1, { kind = client.REQUEST })))

  expect.falsy(client.absorb(machine.context, { kind = "mirror" }), "no fleet in it")
  expect.falsy(client.absorb(machine.context, nil), "no message at all")
  expect.equal(#client.rows(machine.context, clock.port.now()), 1, "and the mirror survived")
end)
