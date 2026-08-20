--- A fleet with no world: clocks, ports, contexts and the messages devices send.
---
--- These were local functions at the top of one 2,700-line spec file, which is
--- why that file covered roles, discovery, the bridge, leases, policy, GPS, the
--- turtle, the client, the mobile, boot, the job catalogue and four apps. Every
--- one of those sections wanted one or two of these fakes, and the only way to
--- share them was to live in the same file.
---
--- Now they are a module and the specs are one file per thing they test.
---
--- ## The one rule these fakes follow
---
--- **Anything that blocks, yields.** A service body is a `while true` parked on a
--- receive or a sleep; a fake that returned instantly would spin inside
--- `coroutine.resume`, which never returns - so the supervisor never gets control
--- back and the suite hangs rather than fails. A hung test is worse than a
--- failing one, and no supervisor can preempt its way out of it.

local agent = require("os.turtle.agent")
local discovery = require("os.server.services.discovery")
local logrotate = require("os.server.services.logrotate")
local minePlan = require("domain.mine.plan")
local osBoot = require("os.kernel.boot")
local reconcile = require("os.server.services.reconcile")
local registry = require("domain.fleet.registry")
local server = require("os.server.main")
local turtleOs = require("os.turtle.main")
local wire = require("domain.protocol.message")

local fleet = {}

--- Milliseconds in a second, which is what every clock here counts in.
fleet.SECOND = 1000
local SECOND = fleet.SECOND

--- A clock a spec advances by hand.
---
--- `now` is a required argument everywhere in `domain/`, and this is the other
--- end of that rule: time only moves when a test says so, so a lease that looks
--- stale is one the test made stale.
function fleet.clock(start)
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

--- What an ICOS 2 device broadcasts every two seconds.
function fleet.heartbeat(overrides)
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

--- The smallest context a handler needs: a clock and some state.
function fleet.context()
  local clock = fleet.clock(1000 * SECOND)
  return {
    clock = clock.port,
    state = server.state(),
    _clock = clock,
  }
end

--- Storage and a serialiser, over plain tables.
function fleet.ports(clock, options)
  local files = {}
  local hosted = {}
  options = options or {}
  return {
    hosted = hosted,
    clock = clock.port,
    locator = {
      gps = function()
        return nil
      end,
      saved = function()
        return options.position ~= false and { x = 10, y = 64, z = -3 } or nil
      end,
    },
    -- Answering nulls rather than omissions. A missing port is refused by the
    -- supervisor at registration, so leaving these out would not fail a service
    -- - it would silently not start one, and the count would quietly be right
    -- for the wrong reason.
    screen = require("ports.screen").null(),
    input = require("ports.input").null(),

    -- A body that refuses everything, which is what a computer without turtle
    -- hardware honestly has - and is the difference between a spec that
    -- exercises the turtle's services and one that silently does not.
    --
    -- The supervisor refuses to start a service whose ports are absent, so
    -- leaving this out did not fail anything: it quietly skipped `locate` in
    -- every turtle spec, and the tests written for that service passed by
    -- driving its parts directly while the service itself never ran.
    body = require("ports.body").null(),

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
      -- Yields when there is nothing, exactly as `rednet.receive` does. See the
      -- header: a fake that returned immediately hangs the suite.
      receive = function()
        if coroutine.isyieldable() then
          coroutine.yield()
        end
        return nil
      end,
      id = function()
        return 1
      end,
      host = function(name, protocol)
        hosted[#hosted + 1] = { name = name, protocol = protocol }
        return true
      end,
      open = function()
        return options.modem ~= false
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

--- A context with a recording transport, so a spec can read what went out.
function fleet.server(options)
  options = options or {}
  local clock = fleet.clock(1000 * SECOND)
  local sent = {}
  local hosted = {}
  return {
    _hosted = hosted,
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
      host = function(name, protocol)
        hosted[#hosted + 1] = { name = name, protocol = protocol }
        return true
      end,
      open = function()
        return options.modem ~= false
      end,
    },
    _clock = clock,
    _sent = sent,
  }
end

--- The envelope an ICOS 1 device actually puts on the wire.
function fleet.legacy(kind, body)
  return wire.wrap(kind, body, 0)
end

--- What an ICOS 1 miner broadcasts every two seconds.
function fleet.legacySnapshot(overrides)
  local snap = {
    label = "miner-3",
    phase = "mining",
    job = "rare",
    fuel = 42000,
    sector = 4,
    workKey = "rare@-59",
    world = { x = 12, y = -59, z = -300 },
  }
  for key, value in pairs(overrides or {}) do
    snap[key] = value
  end
  return snap
end

--- A server that can answer an ICOS 1 device.
function fleet.bridge(options)
  local ctx = fleet.server(options)
  ctx.toCommand = reconcile.legacy
  return ctx
end

--- Give a context a mine, since an unconfigured one refuses every claim.
function fleet.mine(ctx)
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

--- A server with a mine already configured.
function fleet.mined(options)
  return fleet.mine(fleet.server(options))
end

--- A `mine` message with the given action.
function fleet.request(action, body)
  body = body or {}
  body.action = action
  return { kind = "mine", body = body }
end

--- A device parked for the given reason, reporting right now.
function fleet.parked(ctx, id, snapshot)
  snapshot.parked = true
  discovery.handle(ctx, id, { kind = "status", snapshot = snapshot })
  return registry.get(ctx.state.fleet, id)
end

--- A turtle that has applied nothing.
function fleet.turtle()
  return agent.empty()
end

--- A context holding one log file.
function fleet.logs(text)
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

--- A booted turtle whose job and controls are whatever the caller passes.
function fleet.turtleMachine(options)
  options = options or {}
  local clock = fleet.clock(1000 * SECOND)
  local ports = fleet.ports(clock)
  local machine = turtleOs.boot(ports, {
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

--- What `adapters/cc/machine.lua` would have reported, as a literal.
---
--- Passed explicitly rather than letting `boot.machine` probe for it. The real
--- probe reads `peripheral`, `term` and `os.getComputerID`, and the only reason
--- it worked in a spec was that some earlier file had installed a simulated
--- world into `_G` and left it there - so this spec's result depended on which
--- other specs had run first. Naming the capabilities makes the boot path honest
--- and the ordering irrelevant.
fleet.CAPABILITIES = {
  kind = "computer",
  turtle = false,
  pocket = false,
  id = 1,
  screen = true,
  advanced = true,
  modem = true,
  wireless = true,
  monitor = false,
  chunkLoaded = false,
  located = true,
}

--- A machine built from fakes, with a scripted event queue.
function fleet.booted(role, options)
  options = options or {}
  local clock = fleet.clock(0)
  local ports = fleet.ports(clock)
  ports.state = nil

  local machine = assert(osBoot.machine({}, {
    role = role,
    ports = ports,
    machine = options.machine or fleet.CAPABILITIES,
    draw = options.draw or function(context)
      while true do
        context.clock.sleep(1)
        coroutine.yield()
      end
    end,
    snapshot = function()
      return {}
    end,
    runJob = options.runJob or function(context)
      while true do
        context.clock.sleep(1)
        coroutine.yield()
      end
    end,
    runControls = function(context)
      while true do
        context.clock.sleep(1)
        coroutine.yield()
      end
    end,
  }))
  machine.clock = clock
  return machine
end

--- Feed a fixed list of events and then terminate, so `run` always returns.
function fleet.scripted(events)
  local index = 0
  return function()
    index = index + 1
    return events[index] or { "terminate" }
  end
end

return fleet
