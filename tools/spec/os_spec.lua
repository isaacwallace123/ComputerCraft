--- Roles, and a server driven end to end with no world.
---
--- The point of the last five phases arriving as domain modules is that this
--- file can exist: a heartbeat goes in, a registry entry and a desired-state
--- reply come out, and nothing anywhere is a Minecraft.

local expect = require("support.expect")
local it = require("support.spec").it

local desired = require("domain.fleet.desired")
local discovery = require("os.server.services.discovery")
local registry = require("domain.fleet.registry")
local roles = require("os.roles")
local server = require("os.server.main")

local SECOND = 1000

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------

it("today's roles map onto the four operating systems", function()
  expect.equal(roles.roleOf({ role = "miner" }), roles.MINER, "miner")
  expect.equal(roles.roleOf({ role = "controller" }), roles.MOBILE, "controller becomes mobile")
  expect.equal(roles.roleOf({ role = "gps" }), roles.SERVER, "a gps host is already a server")
  expect.equal(roles.roleOf({ role = "utility" }), roles.CLIENT, "utility holds no authority")
end)

it("fleet becomes a server, and a client beside it when there is a screen", function()
  -- The awkward one. §2 splits `fleet` into a server that holds authoritative
  -- state and a client that draws it, and one machine was doing both.
  expect.equal(roles.roleOf({ role = "fleet" }), roles.SERVER, "the brain half wins")

  local plan = roles.plan({ role = "fleet" }, { screen = true, modem = true, located = true })
  expect.equal(plan.role, roles.SERVER, "primary")
  expect.truthy(plan.client, "with a client beside it")

  -- Mapping it the other way round would mean a base that lost its monitor
  -- stopped being the fleet's brain.
  local headless = roles.plan({ role = "fleet" }, { modem = true, located = true })
  expect.equal(headless.role, roles.SERVER, "still the brain")
  expect.falsy(headless.client, "with nothing to draw on")
end)

it("an ICOS 2 role reads back unchanged", function()
  local plan = roles.plan({ role = "miner" }, { turtle = true })
  expect.falsy(plan.migrated, "a native role is not a migration")

  plan = roles.plan({ role = "controller" }, { pocket = true, modem = true })
  expect.truthy(plan.migrated, "but an ICOS 1 one is")
end)

it("an unreadable role becomes the harmless one", function()
  -- A client shows a screen and is wrong harmlessly. A miner starts driving a
  -- turtle and a server starts answering for the fleet.
  expect.equal(roles.roleOf(nil), roles.CLIENT, "no node at all")
  expect.equal(roles.roleOf({}), roles.CLIENT, "no role")
  expect.equal(roles.roleOf({ role = "banana" }), roles.CLIENT, "a role from the future")
end)

it("a machine is checked against what it claims to be", function()
  -- At boot, because "this turtle has no modem" is a sentence somebody can act
  -- on and "attempt to index a nil value" at three in the morning is not.
  local ok, why = roles.check(roles.MINER, { turtle = false })
  expect.falsy(ok, "a computer cannot be a miner")
  expect.contains(why, "turtle", "and says so")

  ok, why = roles.check(roles.SERVER, { modem = false, located = true })
  expect.falsy(ok, "a server with no modem")
  expect.contains(why, "modem", "named")

  ok, why = roles.check(roles.SERVER, { modem = true, located = false })
  expect.falsy(ok, "a server that does not know where it is cannot host GPS")
  expect.contains(why, "where it is", "named")

  expect.truthy(roles.check(roles.SERVER, { modem = true, located = true }), "and a real one passes")
end)

it("a handheld with no modem is warned, not refused", function()
  -- D019: setup offers this role without a modem and fleet traffic stays offline
  -- until one is attached. A handheld with no modem is still a usable handheld.
  local ok, note = roles.check(roles.MOBILE, { pocket = true, modem = false })
  expect.truthy(ok, "allowed")
  expect.contains(note, "modem", "with a warning")

  expect.falsy(roles.check(roles.MOBILE, { pocket = false }), "but a computer is not a handheld")
end)

---------------------------------------------------------------------------
-- A server, driven
---------------------------------------------------------------------------

local function fakeClock(start)
  local self = { time = start or 0 }
  self.port = {
    now = function()
      return self.time
    end,
    sleep = function() end,
  }
  function self.advance(seconds)
    self.time = self.time + seconds * SECOND
  end
  return self
end

local function heartbeat(overrides)
  local message = {
    kind = discovery.STATUS,
    applied = { generation = 0, mode = "mining" },
    snapshot = {
      label = "miner-7",
      phase = "mining",
      job = "rare",
      fuel = 51000,
      world = { x = 138, y = -59, z = -1176 },
    },
  }
  for key, value in pairs(overrides or {}) do
    message[key] = value
  end
  return message
end

local function context()
  local clock = fakeClock(1000 * SECOND)
  return {
    clock = clock.port,
    state = server.state(),
    _clock = clock,
  }
end

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

it("an order set while a device is away is delivered when it returns", function()
  -- The whole desired-state model, exercised through the service that carries
  -- it: the failure §1 opens with is a recall that does nothing because the
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

  local accepted = assert(desired.apply(0, reply.desired), "the turtle takes it")
  local caughtUp = heartbeat({ applied = desired.report(accepted.generation, "recall") })
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
  -- it: `fleet/roster.lua` replaces the whole record, so a heartbeat with no
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

---------------------------------------------------------------------------
-- Booting one
---------------------------------------------------------------------------

--- Storage and a serialiser, over plain tables.
local function fakePorts(clock)
  local files = {}
  return {
    clock = clock.port,
    storage = {
      read = function(path)
        return files[path]
      end,
      write = function(path, text)
        files[path] = text
        return true
      end,
      list = function()
        return {}
      end,
      delete = function(path)
        files[path] = nil
        return true
      end,
    },
    transport = {
      send = function()
        return true
      end,
      broadcast = function() end,
      -- Yields when there is nothing, exactly as `rednet.receive` does. A fake
      -- that returned immediately would make a service loop spin without ever
      -- handing control back, and `coroutine.resume` would never return - which
      -- is a hung test rather than a failing one, and no supervisor can preempt
      -- its way out of that.
      receive = function()
        if coroutine.isyieldable() then
          coroutine.yield()
        end
        return nil
      end,
      id = function()
        return 1
      end,
    },
    -- Serialisation is a port here rather than `textutils`, because `os/` is a
    -- composition layer and reaching for a CC global would make the whole server
    -- untestable for the sake of one function.
    serialise = {
      encode = function(value)
        local parts = {}
        for key, entry in pairs(value) do
          parts[#parts + 1] = tostring(key) .. "=" .. tostring(entry)
        end
        return table.concat(parts, ";")
      end,
      decode = function()
        return {}
      end,
    },
    files = files,
  }
end

it("a server boots its services and reports healthy", function()
  local clock = fakeClock(0)
  local ports = fakePorts(clock)
  local machine = server.boot(ports)

  machine.supervisor:step()
  expect.truthy(machine.supervisor:healthy(), "healthy")
  expect.equal(machine.supervisor:running(), #server.services(), "with everything running")

  local health = machine.supervisor:health()
  expect.equal(health[1].id, "discovery", "discovery among them")
  expect.truthy(health[1].critical, "and marked critical, because a deaf server is not a server")
end)

it("a server with no saved state starts empty rather than refusing", function()
  local clock = fakeClock(0)
  local machine = server.boot(fakePorts(clock))

  expect.truthy(machine.state.fleet, "a registry")
  expect.truthy(machine.state.depots, "and a drop-off list")
  expect.equal(#machine.state.depots.depots, 0, "both empty")
end)

it("state is written to separate files, so a busy one cannot corrupt a quiet one", function()
  -- The registry changes on every heartbeat and the drop-off list perhaps
  -- monthly. One file would mean rewriting the depots ten times a minute.
  local clock = fakeClock(0)
  local ports = fakePorts(clock)
  local machine = server.boot(ports)

  server.save(ports, machine.state)
  expect.truthy(ports.files[server.PATHS.fleet], "the registry has its own file")
  expect.truthy(ports.files[server.PATHS.depots], "and so do the depots")
  expect.falsy(server.PATHS.fleet == ".fleet", "and neither is the ICOS 1 roster")
end)
