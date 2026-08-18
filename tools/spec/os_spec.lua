--- Roles, and a server driven end to end with no world.
---
--- The point of the last five phases arriving as domain modules is that this
--- file can exist: a heartbeat goes in, a registry entry and a desired-state
--- reply come out, and nothing anywhere is a Minecraft.

local expect = require("support.expect")
local it = require("support.spec").it

local desired = require("domain.fleet.desired")
local discovery = require("os.server.services.discovery")
local leases = require("os.server.services.leases")
local logrotate = require("os.server.services.logrotate")
local miner = require("os.miner.main")
local gpsService = require("os.server.services.gps")
local policy = require("os.server.services.policy")
local policyRules = require("domain.fleet.policy")
local minePlan = require("domain.mine.plan")
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
local function fakePorts(clock, options)
  local files = {}
  options = options or {}
  return {
    clock = clock.port,
    locator = {
      gps = function()
        return nil
      end,
      saved = function()
        return options.position ~= false and { x = 10, y = 64, z = -3 } or nil
      end,
    },
    -- A constellation host that answers nobody, which is what a spec wants: the
    -- wire protocol belongs to CC and is exercised in the world, not here.
    beacon = {
      open = function()
        return options.modem ~= false, options.modem == false and "no wireless modem" or "back"
      end,
      answer = function()
        if coroutine.isyieldable() then
          coroutine.yield()
        end
        return false
      end,
      close = function() end,
    },
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

---------------------------------------------------------------------------
-- Reconcile: the acting half, and the bridge to the old protocol
---------------------------------------------------------------------------

local reconcile = require("os.server.services.reconcile")
local persist = require("os.server.services.persist")

--- A context with a recording transport, so a spec can read what went out.
local function serverContext(options)
  options = options or {}
  local clock = fakeClock(1000 * SECOND)
  local sent = {}
  return {
    clock = clock.port,
    state = server.state(),
    paths = server.PATHS,
    events = options.events,
    nudgeEvery = options.nudgeEvery,
    handlers = server.handlers(),
    storage = {
      write = function()
        return true
      end,
      read = function()
        return nil
      end,
    },
    serialise = {
      encode = function()
        return ""
      end,
      decode = function()
        return nil
      end,
    },
    transport = {
      send = function(id, message, protocol)
        sent[#sent + 1] = { id = id, message = message, protocol = protocol }
        return true
      end,
      broadcast = function() end,
      receive = function()
        return nil
      end,
      id = function()
        return 1
      end,
    },
    _clock = clock,
    _sent = sent,
  }
end

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
  -- §12's dual run. A turtle on the old build obeys the command and never
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
  -- §5 collapses the set-job / configure / deploy dance into one record. A
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

---------------------------------------------------------------------------
-- Persist: a service whose job is mostly not writing
---------------------------------------------------------------------------

it("the registry is batched and the drop-offs are not", function()
  -- The test is not importance, it is whether anything else in the world holds a
  -- copy. A registry is rebuilt by the devices themselves within a minute; a
  -- drop-off list exists nowhere but this disk.
  local ctx = serverContext()
  ctx.storage = { write = function() return true end }
  ctx.serialise = { encode = function() return "" end }

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
  ctx.storage = { write = function() writes = writes + 1 return true end }
  ctx.serialise = { encode = function() return "" end }

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

---------------------------------------------------------------------------
-- The miner: the half that has to obey a recall
---------------------------------------------------------------------------

local agent = require("os.miner.agent")

local function turtle()
  return agent.empty()
end

it("a turtle reports what it has applied, so the server can tell it has caught up", function()
  local state = turtle()
  state.applied, state.mode = 41, "recall"
  local beat = agent.heartbeat(state, { label = "miner-7" })

  expect.equal(beat.kind, "status", "an ordinary heartbeat")
  expect.equal(beat.applied.generation, 41, "carrying the applied generation")
  expect.equal(beat.snapshot.label, "miner-7", "beside the snapshot")
end)

it("a new order becomes an intent, and a repeat becomes nothing", function()
  local state = turtle()
  local reply = { kind = "desired", desired = { mode = "recall", generation = 41 } }

  local intent = assert(agent.receive(state, reply), "the first time")
  expect.equal(intent.mode, "recall", "recall")
  expect.equal(intent.source, "desired", "from the new protocol")

  agent.applied(state, intent)
  expect.equal(state.applied, 41, "recorded")
  expect.equal(agent.receive(state, reply), nil, "and the same reply again does nothing")
end)

it("everything that is not an order means carry on", function()
  -- D004 as a set of return values. A turtle that cannot reach the base keeps
  -- mining; one that receives nonsense keeps mining. Nothing here can produce a
  -- stopped turtle.
  local state = turtle()
  state.applied = 41

  expect.equal(agent.receive(state, nil), nil, "no message")
  expect.equal(agent.receive(state, "recall"), nil, "not a table")
  expect.equal(agent.receive(state, { kind = "mine_result" }), nil, "somebody else's message")
  expect.equal(agent.receive(state, { kind = "desired" }), nil, "an empty reply")
  expect.equal(
    agent.receive(state, { kind = "desired", desired = { mode = "recall", generation = 40 } }),
    nil,
    "an order that overtook a newer one"
  )
end)

it("a turtle takes orders from the old protocol too, during the rolling update", function()
  -- Turtles update before the base does: the updater deploys by manifest and a
  -- fleet upgrades a machine at a time, so there is a window where a new turtle
  -- is talking to an old server that has never heard of desired state. Ignoring
  -- commands in that window would mean ignoring recall, which is a safety
  -- control.
  local state = turtle()
  local intent = assert(agent.receive(state, { kind = "command", command = { action = "recall" } }))
  expect.equal(intent.mode, "recall", "obeyed")
  expect.equal(intent.source, "command", "by the old route")

  agent.applied(state, intent)
  expect.equal(state.applied, 0, "with no generation to record")

  -- Which means it reports as never converged, and that is the honest answer:
  -- it has applied nothing it could name.
  expect.equal(agent.heartbeat(state, {}).applied.generation, 0, "still generation zero")
end)

it("an assignment carries its job through either protocol", function()
  local state = turtle()

  local viaCommand = assert(agent.receive(state, {
    kind = "command",
    command = { action = "assign_job", job = "rare", settings = { targetY = -59 } },
  }))
  expect.equal(viaCommand.mode, "deploy", "an assignment is a deployment")
  expect.equal(viaCommand.job, "rare", "with the job")

  local viaDesired = assert(agent.receive(state, {
    kind = "desired",
    desired = { mode = "deploy", generation = 1, job = "rare", settings = { targetY = -59 } },
  }))
  expect.equal(viaDesired.job, "rare", "and the same either way")
  expect.equal(viaDesired.settings.targetY, -59, "settings included")
end)

it("a query is not an order", function()
  -- Turning a dashboard refresh into a mode would make looking at a fleet change
  -- what it was doing.
  local state = turtle()
  expect.equal(agent.fromCommand({ action = "status_request" }), nil, "a status request")
  expect.equal(agent.fromCommand({ action = "configure" }), nil, "and a configure")
end)

it("a turtle that rebooted does not carry out an order it already carried out", function()
  -- A recall that re-ran on every boot would be a turtle that could never be
  -- redeployed.
  local files = {}
  local ports = {
    storage = {
      read = function(path)
        return files[path]
      end,
      write = function(path, text)
        files[path] = text
        return true
      end,
    },
    serialise = {
      encode = function(value)
        return tostring(value.applied) .. "|" .. tostring(value.mode)
      end,
      decode = function(text)
        local applied, mode = text:match("^(%-?%d+)|(.*)$")
        return { applied = tonumber(applied), mode = mode }
      end,
    },
  }

  local state = turtle()
  local reply = { kind = "desired", desired = { mode = "recall", generation = 41 } }
  agent.applied(state, assert(agent.receive(state, reply)))
  agent.save(ports, state)

  -- Reboot: fresh state, read back from disk.
  local afterReboot = agent.load(ports)
  expect.equal(afterReboot.applied, 41, "it remembers")
  expect.equal(agent.receive(afterReboot, reply), nil, "and does not recall again")
end)

it("a turtle with no saved file takes the next order it sees", function()
  -- The safe direction: worst case it re-applies an order it had already
  -- applied, and every mode is idempotent precisely so that costs nothing.
  local ports = {
    storage = {
      read = function()
        return nil
      end,
    },
    serialise = { decode = function() end },
  }
  local state = agent.load(ports)
  expect.equal(state.applied, 0, "nothing applied")
  expect.truthy(agent.receive(state, { kind = "desired", desired = { mode = "park", generation = 1 } }), "takes it")
end)

it("a server and a turtle converge across the whole round trip", function()
  -- Both halves of phase 3 in one test: the server sets a goal, the turtle is
  -- away, the turtle returns, applies it, reports it, and the server agrees.
  local ctx = serverContext()
  local state = turtle()

  discovery.handle(ctx, 7, agent.heartbeat(state, { world = { x = 1, y = 2, z = 3 } }))
  local record = registry.get(ctx.state.fleet, 7)
  desired.want(record, "recall", nil, ctx.clock.now())

  ctx._clock.advance(20 * 60)
  expect.equal(desired.status(record, ctx.clock.now()), "unreachable", "gone")

  local reply = assert(discovery.handle(ctx, 7, agent.heartbeat(state, {})))
  local intent = assert(agent.receive(state, { kind = "desired", desired = reply.desired }))
  agent.applied(state, intent)

  discovery.handle(ctx, 7, agent.heartbeat(state, {}))
  expect.equal(desired.status(record, ctx.clock.now()), "converged", "converged")
  expect.equal(state.mode, "recall", "and the turtle knows what it is doing")
end)

---------------------------------------------------------------------------
-- Leases: two turtles are never sent down the same shaft
---------------------------------------------------------------------------

--- A server with a mine configured, since an unconfigured one refuses claims.
local function mined(options)
  local ctx = serverContext(options)
  ctx.state.mine.plan = minePlan.normalise({
    configured = true,
    centreX = 0,
    centreZ = 0,
    surfaceY = 64,
    cellSize = 16,
    maxRing = 2,
    minRing = 1,
  })
  return ctx
end

local function request(action, body)
  body = body or {}
  body.action = action
  return { kind = "mine", body = body }
end

it("a sector goes to one turtle and the next one gets a different sector", function()
  local ctx = mined()

  local first = assert(leases.handle(ctx, 7, request("claim", { workKey = "w", requestId = 1 })))
  expect.truthy(first.ok, "claimed")
  expect.equal(first.requestId, 1, "answering the right request")

  local second = assert(leases.handle(ctx, 8, request("claim", { workKey = "w", requestId = 2 })))
  expect.truthy(second.ok, "claimed")

  -- The whole reason this is a service. D018: this used to stop working when
  -- somebody closed the Fleet page.
  expect.truthy(first.sector ~= second.sector, "and never the same hole")
end)

it("an unconfigured mine says so instead of going quiet", function()
  -- A turtle waits about three seconds and then falls back to its cached plan,
  -- so "no" arriving promptly beats a correct answer arriving too late.
  local ctx = serverContext()
  local reply = assert(leases.handle(ctx, 7, request("claim", { workKey = "w", requestId = 4 })))
  expect.falsy(reply.ok, "refused")
  expect.contains(reply.message, "mine here", "and tells somebody how to fix it")
end)

it("a claim is written immediately and a report is not", function()
  -- The trade in the file header: a lost report costs re-counted footage, a
  -- lost claim is two turtles in one hole.
  local ctx = mined()
  local writes = 0
  ctx.storage.write = function()
    writes = writes + 1
    return true
  end

  local claim = assert(leases.handle(ctx, 7, request("claim", { workKey = "w" })))
  expect.equal(writes, 1, "the claim hit the disk")

  for _ = 1, 10 do
    leases.handle(ctx, 7, request("report", { sector = claim.sector, workKey = "w", blocks = 3 }))
  end
  expect.equal(writes, 1, "ten reports did not")
  expect.truthy(ctx.dirty.mine, "they were marked instead")
end)

it("an open shaft head is written the moment it is reported", function()
  -- The one fact here nothing in the world will re-report: the turtle that saw
  -- the hole has moved on, and the hole is still there.
  local ctx = mined()
  local writes = 0
  ctx.storage.write = function()
    writes = writes + 1
    return true
  end

  local reply = assert(
    leases.handle(ctx, 7, request("surface", { sector = 2, state = "open", headY = 71 }))
  )
  expect.truthy(reply.ok, "recorded")
  expect.equal(writes, 1, "and persisted at once")
  expect.equal(#require("domain.mine.registry").exposed(ctx.state.mine), 1, "one open head")
end)

it("a claim tells a replacement turtle what the last one found", function()
  local ctx = mined()
  leases.handle(ctx, 7, request("surface", { sector = 2, state = "open", headY = 71 }))
  leases.handle(ctx, 7, request("release", { sector = 2 }))

  local reply = assert(leases.handle(ctx, 9, request("claim", { workKey = "w", sector = 2 })))
  expect.equal(reply.sector, 2, "the same sector")
  expect.equal(reply.surface.state, "open", "and it knows before it arrives")
end)

it("a heartbeat renews a lease without a disk write, and parking gives it back", function()
  local ctx = mined()
  local claim = assert(leases.handle(ctx, 7, request("claim", { workKey = "w" })))

  local snapshot = { sector = claim.sector, workKey = "w" }
  expect.falsy(leases.renew(ctx, 7, snapshot), "a fresh lease needs no renewal")

  -- Renewal only bites once the lease is actually getting old, which is what
  -- stops a two-second heartbeat becoming a two-second disk write.
  ctx._clock.advance(45)
  expect.truthy(leases.renew(ctx, 7, snapshot), "an ageing one does")

  ctx._clock.advance(45)
  snapshot.parked = true
  expect.falsy(leases.renew(ctx, 7, snapshot), "and a parked turtle stops asking")
end)

it("a lease whose holder went quiet is swept up", function()
  local ctx = mined()
  local claim = assert(leases.handle(ctx, 7, request("claim", { workKey = "w" })))

  expect.equal(leases.sweep(ctx), 0, "nothing to sweep yet")

  ctx._clock.advance(20 * 60)
  expect.equal(leases.sweep(ctx), 1, "the lease expired")

  local other = assert(leases.handle(ctx, 8, request("claim", { workKey = "w", sector = claim.sector })))
  expect.equal(other.sector, claim.sector, "and the sector went back into the pool")
end)

it("one status heartbeat reaches both services", function()
  -- Only one loop can call receive, because receiving consumes. So discovery
  -- owns the radio and everything else registers a handler - and a heartbeat is
  -- a device report to one service and a lease renewal to the other.
  local ctx = mined()
  local claim = assert(leases.handle(ctx, 7, request("claim", { workKey = "w" })))
  ctx._clock.advance(45)

  local replies = discovery.dispatch(ctx, 7, {
    kind = "status",
    snapshot = { sector = claim.sector, workKey = "w", world = { x = 1, y = 2, z = 3 } },
  })

  expect.equal(#replies, 1, "one answer went back")
  expect.equal(replies[1].kind, "desired", "from discovery")
  expect.truthy(registry.get(ctx.state.fleet, 7), "the device was recorded")
  expect.truthy(ctx.dirty.mine, "and the lease was renewed")
end)

it("a mine request is answered by leases and ignored by discovery", function()
  local ctx = mined()
  local replies = discovery.dispatch(ctx, 7, request("claim", { workKey = "w", requestId = 3 }))

  expect.equal(#replies, 1, "exactly one reply")
  expect.equal(replies[1].kind, "mine_result", "and it came from leases")
  expect.equal(replies[1].requestId, 3, "matched to the request")
end)

---------------------------------------------------------------------------
-- Policy: an unattended fleet that fixes itself and never overrules a person
---------------------------------------------------------------------------

--- A device parked for the given reason, reporting right now.
local function parked(ctx, id, snapshot)
  snapshot.parked = true
  discovery.handle(ctx, id, { kind = "status", snapshot = snapshot })
  return registry.get(ctx.state.fleet, id)
end

it("a refuelled turtle is sent back to work", function()
  local ctx = serverContext()
  parked(ctx, 7, { parkKind = "fuel", fuel = 500, fuelRequired = 200 })

  local acted = policy.pass(ctx, ctx.clock.now())
  expect.equal(#acted, 1, "one recovery")
  expect.equal(acted[1].rule, "fuel", "the fuel rule")
  expect.equal(registry.get(ctx.state.fleet, 7).desired.mode, "deploy", "goal set, not a command")
end)

it("policy never overrules a person", function()
  -- The rule ICOS 1 stated in a comment and enforced by having no rule that
  -- happened to match. Here it is structural: a standing goal that is not
  -- `deploy` is somebody's decision, and no rule is even consulted.
  local ctx = serverContext()
  local record = parked(ctx, 7, { parkKind = "fuel", fuel = 500, fuelRequired = 200 })
  desired.want(record, "recall", nil, ctx.clock.now())

  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "a recalled turtle is left alone")
  expect.equal(record.desired.mode, "recall", "and stays recalled")

  -- And the guard is the thing being tested, not the absence of a matching rule.
  expect.falsy(policyRules.mayAct(record), "no rule may run against it")
end)

it("a recovery is not re-decided every pass", function()
  local ctx = serverContext()
  parked(ctx, 7, { parkKind = "error", detail = "depot full at 12,64,-3" })

  expect.equal(#policy.pass(ctx, ctx.clock.now()), 1, "acted once")
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "and not again immediately")

  -- The goal is unchanged rather than re-sent, which is the whole reason a
  -- generation compares by content: a policy loop must not bump it every pass.
  local record = registry.get(ctx.state.fleet, 7)
  expect.equal(record.desired.generation, 1, "one generation, not three")

  ctx._clock.advance(policyRules.COOLDOWN.depot + 1)
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "still nothing to say - the goal is right")
end)

it("only one turtle updates per pass", function()
  -- A rolling update that queues ten turtles at once is not rolling, it is a
  -- fleet that all stops at the same moment.
  local ctx = serverContext()
  ctx.version = "2.0.0"
  ctx.policy = policyRules.normalise({ updateParked = true })
  for id = 1, 4 do
    parked(ctx, id, { parkKind = "manual", version = "1.9.0" })
  end

  local acted = policy.pass(ctx, ctx.clock.now())
  expect.equal(#acted, 1, "one at a time")
  expect.equal(acted[1].mode, "update", "and it is an update")

  -- Deterministic, because `pairs` order would make it a different turtle every
  -- pass and a different order after every reboot.
  expect.equal(acted[1].id, 1, "the same turtle every time")
end)

it("updates stay opt-in and skip a turtle that is already in trouble", function()
  local ctx = serverContext()
  ctx.version = "2.0.0"
  parked(ctx, 7, { parkKind = "manual", version = "1.9.0" })
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "off by default")

  ctx.policy = policyRules.normalise({ updateParked = true })
  ctx.attempts = {}
  ctx.state.fleet = registry.empty()
  parked(ctx, 7, { parkKind = "error", detail = "stuck", version = "1.9.0" })
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "a broken turtle needs a person")
end)

it("a device that has gone quiet is not acted on from a stale snapshot", function()
  -- "Parked for fuel" twenty minutes ago is not evidence of anything now.
  local ctx = serverContext()
  parked(ctx, 7, { parkKind = "fuel", fuel = 500, fuelRequired = 200 })
  ctx._clock.advance(20 * 60)

  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "nothing decided from old news")
end)

it("policy can be switched off entirely", function()
  local ctx = serverContext()
  ctx.policy = policyRules.normalise({ enabled = false })
  parked(ctx, 7, { parkKind = "fuel", fuel = 500, fuelRequired = 200 })
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "and then it does nothing at all")
end)

---------------------------------------------------------------------------
-- GPS: the one service that must never be confidently wrong
---------------------------------------------------------------------------

it("the beacon serves what setup wrote down, never a GPS fix", function()
  -- A host announcing the wrong position makes `gps.locate` return a confident
  -- number, and a turtle that believes it is thirty blocks from where it is
  -- drives into a wall and keeps going. Serving a fix would also let a
  -- constellation bootstrap off its own error.
  local ctx = {
    locator = {
      saved = function()
        return { x = 10, y = 64, z = -3 }
      end,
      gps = function()
        return 999, 999, 999
      end,
    },
  }
  local position = assert(gpsService.position(ctx))
  expect.equal(position.x, 10, "from the saved record")
  expect.equal(position.z, -3, "and not from the constellation")
end)

it("a half-written position is refused with something a person can act on", function()
  local ctx = {
    locator = {
      saved = function()
        return { x = 10, z = -3 }
      end,
    },
  }
  local position, reason = gpsService.position(ctx)
  expect.falsy(position, "no position")
  expect.contains(reason, "where set", "and it says how to fix it")
end)

it("a server with no wireless modem says so and reports unhealthy", function()
  -- A service that is running and doing nothing is the worst of the three
  -- states: the health page would show green while nothing in the world could
  -- get a fix.
  local clock = fakeClock(0)
  local machine = server.boot(fakePorts(clock, { modem = false }))

  for _ = 1, 8 do
    machine.supervisor:step()
    clock.advance(60)
  end

  local healthy, why = machine.supervisor:healthy()
  expect.falsy(healthy, "not healthy")
  expect.contains(why, "gps", "and it names the service")
  expect.contains(machine.context.gpsReason, "wireless", "with the reason on the context")
end)

---------------------------------------------------------------------------
-- Logrotate: the machine that is never rebooted is the one that never trimmed
---------------------------------------------------------------------------

local function logContext(text)
  local files = { [logrotate.PATH] = text }
  return {
    storage = {
      read = function(path)
        return files[path]
      end,
      write = function(path, value)
        files[path] = value
        return true
      end,
    },
    files = files,
  }
end

it("a short log is left alone", function()
  local ctx = logContext("one\ntwo\nthree\n")
  expect.equal(logrotate.rotate(ctx), 0, "nothing to do")
  expect.equal(ctx.files[logrotate.PATH], "one\ntwo\nthree\n", "and it is untouched")
  expect.falsy(ctx.files[logrotate.PREVIOUS], "no previous generation invented")
end)

it("a full log is moved aside rather than truncated", function()
  -- When something breaks at 3am and is noticed at 9am, the interesting lines
  -- are the first ones after it started. Truncation keeps six hours of
  -- consequences and deletes the cause.
  local lines = {}
  for i = 1, logrotate.MAX_LINES do
    lines[i] = "line " .. i
  end
  local text = table.concat(lines, "\n") .. "\n"

  local ctx = logContext(text)
  expect.equal(logrotate.rotate(ctx), logrotate.MAX_LINES, "rotated the whole file")
  expect.equal(ctx.files[logrotate.PATH], "", "a fresh log")
  expect.contains(ctx.files[logrotate.PREVIOUS], "line 1", "and the cause survived")
  expect.contains(ctx.files[logrotate.PREVIOUS], "line " .. logrotate.MAX_LINES, "with the rest")
end)

it("a log that cannot be moved is not cleared", function()
  -- A full or read-only disk is exactly what this service exists for, and
  -- exactly when clearing the current log would destroy the evidence of it.
  local text = string.rep("line\n", logrotate.MAX_LINES)
  local ctx = logContext(text)
  ctx.storage.write = function(path, value)
    if path == logrotate.PREVIOUS then
      return false
    end
    ctx.files[path] = value
    return true
  end

  expect.equal(logrotate.rotate(ctx), 0, "reported as not done")
  expect.equal(ctx.files[logrotate.PATH], text, "and nothing was lost")
end)

it("a last line with no newline still counts", function()
  expect.equal(logrotate.lines("a\nb"), 2, "two lines")
  expect.equal(logrotate.lines("a\nb\n"), 2, "the same two")
  expect.equal(logrotate.lines(""), 0, "and an empty file is empty")
  expect.equal(logrotate.lines(nil), 0, "as is a missing one")
end)

---------------------------------------------------------------------------
-- The miner: a turtle that keeps mining when the radio stops
---------------------------------------------------------------------------

local function minerContext(options)
  options = options or {}
  local clock = fakeClock(1000 * SECOND)
  local ports = fakePorts(clock)
  local machine = miner.boot(ports, {
    node = options.node or { parked = true },
    snapshot = function()
      return options.node or { parked = true }
    end,
    runJob = options.runJob,
    runControls = options.runControls,
  })
  machine.clock = clock
  return machine
end

it("an order becomes a control flag the existing runtime already reads", function()
  local machine = minerContext({ node = { parked = true } })
  local goal = { mode = "deploy", generation = 4 }

  local outcome = assert(miner.orders(machine.context, { kind = "desired", desired = goal }))
  expect.truthy(outcome.applied, "applied")
  expect.truthy(machine.context.flags.deploy, "the flag miner/runtime.lua reads")
  expect.equal(machine.context.state.applied, 4, "and the generation was recorded")
end)

it("a job change on a running turtle waits instead of being lost", function()
  -- ICOS 1 replied "recall this turtle first" and dropped the order. Under
  -- desired state the goal stays on the server, the turtle keeps reporting a
  -- generation it has not applied, and the base shows it as pending.
  local machine = minerContext({ node = { parked = false } })
  local goal = { mode = "deploy", job = "rare", generation = 9 }

  local outcome = assert(miner.orders(machine.context, { kind = "desired", desired = goal }))
  expect.falsy(outcome.applied, "not yet")
  expect.falsy(machine.context.flags.assignment, "no half-applied assignment")
  expect.equal(machine.context.state.applied, 0, "and it still reports being behind")

  -- Park it, send the same goal again, and it lands.
  machine.context.node.parked = true
  outcome = assert(miner.orders(machine.context, { kind = "desired", desired = goal }))
  expect.truthy(outcome.applied, "now it applies")
  expect.equal(machine.context.flags.assignment.name, "rare", "with the job attached")
  expect.equal(machine.context.state.applied, 9, "and the generation catches up")
end)

it("an update comes home before replacing the code that is driving", function()
  local machine = minerContext({ node = { parked = false } })
  local goal = { mode = "update", generation = 3 }
  local outcome = assert(miner.orders(machine.context, { kind = "desired", desired = goal }))

  expect.truthy(outcome.applied, "accepted")
  expect.truthy(machine.context.flags.recall, "returning home first")
  expect.truthy(machine.context.flags.update, "with the update queued behind it")
end)

it("recalling a parked turtle is free, and doing it twice is free twice", function()
  -- Idempotence is what lets the server re-send an order it is not sure
  -- arrived, and it only works if arriving twice costs nothing. It costs
  -- nothing at two layers, which is worth pinning down separately.
  local machine = minerContext({ node = { parked = true } })
  local goal = { mode = "recall", generation = 2 }

  local outcome = assert(miner.orders(machine.context, { kind = "desired", desired = goal }))
  expect.truthy(outcome.applied, "applied")
  expect.contains(outcome.reason, "already parked", "and it says so")
  expect.falsy(machine.context.flags.recall, "without asking a parked turtle to come home")

  -- The duplicate never reaches the control flags at all: the agent recognises
  -- a generation it has already applied and says nothing. The turtle does not
  -- re-decide, which is one layer better than deciding the same thing again.
  expect.falsy(
    miner.orders(machine.context, { kind = "desired", desired = goal }),
    "the second copy stops at the agent"
  )

  -- And an ICOS 1 command, which carries no generation, is still obeyed - it
  -- reaches the flags every time, exactly as it does today.
  machine.context.node.parked = false
  local again =
    assert(miner.orders(machine.context, { kind = "command", command = { action = "recall" } }))
  expect.truthy(again.applied, "the old protocol still works during the rolling update")
  expect.truthy(machine.context.flags.recall, "and raises the flag")
end)

it("a dead radio does not stop the mining job", function()
  -- The bug this file exists to fix. apps/miner.lua runs four coroutines under
  -- parallel.waitForAny, which returns when ANY of them finishes - so a
  -- heartbeat that throws on a missing modem takes the job down with it.
  local mined = 0
  local machine = minerContext({
    runJob = function(context)
      while true do
        mined = mined + 1
        context.clock.sleep(1)
        coroutine.yield()
      end
    end,
  })

  machine.context.transport.broadcast = function()
    error("no modem", 0)
  end

  for _ = 1, 12 do
    machine.supervisor:step()
    machine.clock.advance(30)
  end

  expect.truthy(mined > 1, "the job kept running")

  -- And the machine is still healthy, because talking about mining is not
  -- mining. A turtle that cannot reach the base keeps mining, which is D004.
  expect.truthy(machine.supervisor:healthy(), "and the turtle is not reported broken")

  local health = machine.supervisor:health()
  local heartbeat
  for _, row in ipairs(health) do
    if row.id == "heartbeat" then
      heartbeat = row
    end
  end
  expect.truthy(heartbeat.failures > 0 or heartbeat.gaveUp, "while the radio is honestly failing")
end)

it("a job that gives up makes the turtle unhealthy", function()
  -- The other half: mining is the machine's entire job, so if it stops the
  -- supervisor must say so rather than report a healthy box in a hole.
  local machine = minerContext({
    runJob = function()
      error("bedrock", 0)
    end,
  })

  for _ = 1, 12 do
    machine.supervisor:step()
    machine.clock.advance(60)
  end

  local healthy, why = machine.supervisor:healthy()
  expect.falsy(healthy, "not healthy")
  expect.contains(why, "job", "and it names the job")
end)
