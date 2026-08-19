local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")
local SECOND = fleet.SECOND

local client = require("os.client.main")
local discovery = require("os.server.services.discovery")
local mobile = require("os.mobile.main")

local context = fleet.context
local fakeClock = fleet.clock
local fakePorts = fleet.ports
local heartbeat = fleet.heartbeat
local serverContext = fleet.server

---------------------------------------------------------------------------
-- The mobile: a client that goes out of range as a matter of course
---------------------------------------------------------------------------

it("a handheld backs off while it is out of range, and does not report broken", function()
  -- Out of range is this machine's normal condition, not a fault. A handheld
  -- that reported unhealthy for walking into a cave would be reporting the
  -- world rather than itself.
  expect.equal(mobile.backoff(0), mobile.SYNC, "answering: the normal interval")
  expect.truthy(mobile.backoff(1) > mobile.SYNC, "one miss, longer")
  expect.truthy(mobile.backoff(2) > mobile.backoff(1), "two misses, longer again")
  expect.equal(mobile.backoff(50), mobile.MAX_BACKOFF, "and capped, not doubling all night")
end)

it("a handheld is a client underneath, so a page written once runs on both", function()
  local ctx = serverContext()
  discovery.handle(ctx, 7, heartbeat())

  local clock = fakeClock(1000 * SECOND)
  local machine = mobile.boot(fakePorts(clock))

  client.absorb(machine.context, assert(discovery.handle(ctx, 1, { kind = mobile.REQUEST })))

  local rows = client.rows(machine.context, clock.port.now())
  expect.equal(#rows, 1, "the same rows")
  expect.equal(client.staleness(machine.context, clock.port.now()), 0, "and the same staleness")
end)

it("a handheld runs one sync loop, not two", function()
  -- It reuses the client's context wholesale, and the failure mode of doing
  -- that carelessly is two radios asking the same question every few seconds.
  local clock = fakeClock(0)
  local machine = mobile.boot(fakePorts(clock), {
    -- A draw that actually loops. The default is a no-op, and a service that
    -- returns is a fault - which is right, and would have made this test pass
    -- for the wrong reason by counting a service that had already fallen over.
    draw = function(context)
      while true do
        context.clock.sleep(1)
        coroutine.yield()
      end
    end,
  })
  machine.supervisor:step()

  local ids = {}
  for _, row in ipairs(machine.supervisor:health()) do
    expect.falsy(ids[row.id], "no service registered twice: " .. row.id)
    ids[row.id] = true
  end
  expect.equal(machine.supervisor:running(), #mobile.services(), "exactly the mobile's services")
  expect.truthy(machine.supervisor:healthy(), "and healthy")
end)
