local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local agent = require("os.turtle.agent")
local desired = require("domain.fleet.desired")
local discovery = require("os.server.services.discovery")
local registry = require("domain.fleet.registry")

local serverContext = fleet.server
local turtle = fleet.turtle

---------------------------------------------------------------------------
-- The turtle agent: the half that has to obey a recall
---------------------------------------------------------------------------

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
  expect.truthy(
    agent.receive(state, { kind = "desired", desired = { mode = "park", generation = 1 } }),
    "takes it"
  )
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
