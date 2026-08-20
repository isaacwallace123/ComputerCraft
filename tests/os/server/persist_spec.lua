local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local discovery = require("os.server.services.discovery")
local persist = require("os.server.services.persist")
local server = require("os.server.main")

local fakeClock = fleet.clock
local fakePorts = fleet.ports
local heartbeat = fleet.heartbeat
local serverContext = fleet.server

---------------------------------------------------------------------------
-- Persist: a service whose job is mostly not writing
---------------------------------------------------------------------------

it("the registry is batched and the drop-offs are not", function()
  -- The test is not importance, it is whether anything else in the world holds a
  -- copy. A registry is rebuilt by the devices themselves within a minute; a
  -- drop-off list exists nowhere but this disk.
  local ctx = serverContext()
  ctx.storage = {
    write = function()
      return true
    end,
  }
  ctx.serialise = {
    encode = function()
      return ""
    end,
  }

  persist.mark(ctx, "fleet")
  persist.mark(ctx, "depots")

  local due = persist.due(ctx, ctx.clock.now())
  expect.equal(#due, 2, "both are due on a fresh server")

  persist.pass(ctx, ctx.clock.now())
  persist.mark(ctx, "fleet")
  persist.mark(ctx, "depots")

  due = persist.due(ctx, ctx.clock.now())
  expect.equal(#due, 1, "only one is due immediately after")
  expect.equal(due[1], "depots", "and it is the one nothing else remembers")

  ctx._clock.advance(6)
  expect.equal(#persist.due(ctx, ctx.clock.now()), 2, "the registry follows on its interval")
end)

it("a heartbeat marks the registry dirty rather than writing it", function()
  -- Ten turtles at one heartbeat every two seconds is five disk writes a second,
  -- and a CC write is a real file operation on the host.
  local ctx = serverContext()
  local writes = 0
  ctx.storage = {
    write = function()
      writes = writes + 1
      return true
    end,
  }
  ctx.serialise = {
    encode = function()
      return ""
    end,
  }

  for _ = 1, 20 do
    discovery.handle(ctx, 7, heartbeat())
  end
  expect.equal(writes, 0, "twenty heartbeats, no writes")
  expect.truthy(ctx.dirty.fleet, "but the registry is marked")

  persist.pass(ctx, ctx.clock.now())
  expect.equal(writes, 1, "and one write covers all of them")
end)

it("a server runs discovery, reconcile and persist", function()
  local clock = fakeClock(0)
  local machine = server.boot(fakePorts(clock))
  machine.supervisor:step()

  expect.equal(machine.supervisor:running(), #server.services(), "all of them")
  expect.truthy(machine.supervisor:healthy(), "and healthy")

  local critical = {}
  for _, row in ipairs(machine.supervisor:health()) do
    critical[row.id] = row.critical
  end
  expect.truthy(critical.discovery, "a deaf server is not a server")
  expect.truthy(critical.persist, "and one that has stopped writing looks fine until it reboots")
  -- Marking this critical would take a whole machine down over a latency
  -- problem: a server whose reconcile died still records heartbeats and still
  -- answers devices that ask.
  expect.falsy(critical.reconcile, "but a slow convergence is not an outage")
end)
