--- The turtle: a machine with arms, and the three loops that keep it honest.
---
--- §2 of docs/icos-2.md. This is the composition root for a turtle - it wires
--- ports to services and hands both to the supervisor, and it decides nothing.
--- Everything that decides anything is in `domain/` or in `os/turtle/agent.lua`
--- and `os/turtle/control.lua`, both of which are testable without a turtle.
---
--- ## The role is a form factor; mining is a job
---
--- This is not `os/miner/`, and the distinction is load-bearing rather than
--- pedantic. A mining turtle and a farming turtle are the same machine running
--- different code: the same heartbeat, the same recall, the same fuel and depot
--- and dead-reckoning problems - everything except which file drives the arms.
--- Giving mining a role of its own would have meant a second operating system
--- differing from the first by one `require`, and a third when somebody wanted a
--- builder.
---
--- So nothing in this file knows what the turtle is for. `context.runJob` is
--- whatever the node selected at setup.
---
--- ## The bug this file exists to fix
---
--- `apps/miner.lua` runs four coroutines under `parallel.waitForAny`, which
--- returns when **any** of them finishes. So a heartbeat loop that throws on a
--- missing modem takes the job down with it, and a turtle halfway down a shaft
--- stops - not because the work failed, but because *talking about* the work
--- failed. D004 says job correctness may never depend on a message arriving, and
--- `waitForAny` is a direct contradiction of it sitting in the entrypoint.
---
--- The supervisor restarts the loop that failed and leaves the others running.
--- The job carries on while the radio backs off and retries, which is what D004
--- asked for in the first place.
---
--- ## It runs the ICOS 1 job code unchanged
---
--- `miner/runtime.lua` is what drives a turtle today, it is proven, and the
--- fleet is running it right now. Rewriting it in the same change that rewrites
--- supervision and orders would put a fleet in a hole with two untested halves.
--- So the job service calls it, `control.lua` writes the flags it already reads,
--- and from the runtime point of view nothing happened. Its eventual replacement
--- is a job module like any other, which is the point of not calling this
--- directory `miner`.
---
--- ## It does not run yet
---
--- Nothing calls `boot`. `src/startup.lua` still starts `apps/miner.lua`, and
--- switching it over is the change that alters what a turtle does on power-up -
--- the one thing in this branch that reaches a running fleet. It waits for an
--- in-world test rather than riding along with the rest.

local agent = require("os.turtle.agent")
local control = require("os.turtle.control")
local jobs = require("domain.turtle.jobs")
local service = require("os.service")
local supervisor = require("os.supervisor")

local turtleOs = {}

turtleOs.PROTOCOL = "icos"

--- Seconds between heartbeats.
---
--- Two, matching ICOS 1. It is what `registry.LATE_AFTER` and `OFFLINE_AFTER`
--- are calibrated against, so changing it here would silently re-tune when the
--- base decides a turtle has gone quiet.
turtleOs.HEARTBEAT = 2

---------------------------------------------------------------------------
-- Which job, and whether this machine can run it
---------------------------------------------------------------------------

--- What this turtle can observe about itself.
---
--- Only the things that can actually be checked without doing them, which is a
--- shorter list than it looks. Fuel is a number the turtle can read; a modem
--- either answers or does not.
---
--- **`dig` and `place` are assumed**, and that is the honest answer rather than
--- a shortcut. A turtle cannot find out whether it has a tool without trying to
--- use one: `turtle.dig` with nothing equipped and `turtle.dig` with nothing in
--- front both return false, and telling them apart means breaking a block to ask
--- a question. A capability check that damaged the world to run would be worse
--- than the problem it detects.
---
--- So the declaration in the catalogue is for the *person* - setup can say "this
--- job needs a tool that breaks blocks" before they choose it - and the runtime
--- discovers the truth the first time it digs, parks, and reports why. That is
--- the existing D004 park path and it already works; the catalogue makes the
--- requirement visible ten seconds earlier, where it is cheap.
function turtleOs.capabilities(ports)
  local body = ports.body
  local level = body and body.fuel() or 0

  return {
    -- Level -1 is an unlimited-fuel world, where every job is fuelled forever.
    fuel = level ~= 0,
    dig = body ~= nil,
    place = body ~= nil,
    modem = ports.transport ~= nil and ports.transport.id() ~= nil,
  }
end

--- The job this turtle is going to run, and whether the node needs correcting.
---
--- Never nil. A turtle whose job cannot be resolved gets the default, because
--- the alternative is a turtle that will not start - and a turtle that will not
--- start is one somebody has to walk to. The correction is returned rather than
--- written here, so the composition root persists it once instead of the boot
--- path re-deriving it every time.
---
--- A job the machine cannot run is *still selected*, and reported as unrunnable
--- rather than silently swapped. A turtle that quietly started fuel-hunting
--- because its pickaxe fell out would be a turtle nobody could diagnose from the
--- base; one that says "quarry - needs a tool equipped that can break blocks" is
--- one somebody fixes in ten seconds.
function turtleOs.selectJob(node, capabilities)
  local entry, corrected = jobs.resolve(node and node.job)
  local runnable, why = jobs.runnable(entry, capabilities)
  return entry, corrected, runnable, why
end

---------------------------------------------------------------------------
-- Services
---------------------------------------------------------------------------

--- Say what this turtle is doing, and hear what it should be.
---
--- One loop rather than two, unlike ICOS 1's `heartbeat` and `commands`. The
--- exchange is a request and its reply, and splitting it meant a turtle whose
--- receive loop had died kept reporting cheerfully while ignoring every order -
--- which looks identical, from the base, to a turtle that is fine.
turtleOs.heartbeat = service.define({
  id = "heartbeat",
  requires = { "transport", "clock", "state" },

  -- Not critical, and this is the whole point of the file. A turtle that cannot
  -- talk to the base is a turtle that keeps working. D004: the job is correct
  -- without the radio, so the radio being down must not make the machine
  -- unhealthy or stop anything else.
  critical = false,

  run = function(context)
    while true do
      local snapshot = context.snapshot()
      context.transport.broadcast(agent.heartbeat(context.state, snapshot), turtleOs.PROTOCOL)

      -- A short receive rather than a sleep, so a reply is picked up as soon as
      -- it lands instead of on the next tick of a timer that knows nothing
      -- about it.
      local sender, message, protocol =
        context.transport.receive(turtleOs.PROTOCOL, turtleOs.HEARTBEAT)
      if sender ~= nil and protocol == turtleOs.PROTOCOL then
        turtleOs.orders(context, message)
      end
    end
  end,
})

--- Act on one message. Returns what happened, or nil if it was not for us.
---
--- Separated from the loop for the reason every service here separates them:
--- anything worth testing that lives inside a `while true` is something that
--- cannot be tested.
function turtleOs.orders(context, message)
  local intent = agent.receive(context.state, message)
  if intent == nil then
    return nil
  end

  local outcome = control.apply(context.node, context.flags, intent)

  -- Only a carried-out order moves the applied generation. A turtle that was
  -- asked to change job while running reports the old generation until it is
  -- parked and can actually do it, so the base shows it as pending rather than
  -- as converged-on-something-it-never-did.
  if outcome.applied then
    agent.applied(context.state, intent)
    agent.save(context, context.state)
  end

  if outcome.halt then
    context.halt = true
  end

  return outcome
end

--- Drive the turtle.
---
--- The one service that is critical, because it is the machine's entire purpose.
--- If this gives up, the turtle is a box standing still, and the supervisor
--- should say so rather than report a healthy machine that is doing nothing.
---
--- Which job it runs is not this file's business. `context.runJob` is whatever
--- the node selected at setup, and a farming turtle registers exactly this
--- service with a different function behind it.
turtleOs.job = service.define({
  id = "job",
  requires = { "state" },
  critical = true,

  run = function(context)
    return context.runJob(context)
  end,
})

--- The buttons on the turtle itself.
---
--- Kept as its own service rather than folded into the job, because the reason
--- somebody is standing in front of a turtle pressing keys is usually that the
--- job has stopped doing what they expected - so the controls have to work when
--- the job does not.
---
--- It runs the same shell a client does, with `surface = "launcher"`. That is
--- the whole benefit of filtering apps by surface rather than by machine: the
--- Services page - which is exactly what somebody standing in front of a stopped
--- turtle wants, because it says "job: gave up - bedrock" - needed no turtle
--- version written for it. It declared the surface and appeared.
turtleOs.controls = service.define({
  id = "controls",
  requires = { "state" },
  critical = false,

  run = function(context)
    return context.runControls(context)
  end,
})

function turtleOs.services()
  return { turtleOs.job, turtleOs.heartbeat, turtleOs.controls }
end

---------------------------------------------------------------------------
-- Composition
---------------------------------------------------------------------------

--- Build a supervised turtle, ready to be stepped.
---
--- `options.snapshot`, `options.runJob` and `options.runControls` are the seams
--- where ICOS 1 is plugged in - the entrypoint passes `ctx:snapshot()` and the
--- two `miner/runtime.lua` loops, and a spec passes three functions and no
--- turtle. That is the only reason they are parameters rather than requires.
function turtleOs.boot(ports, options)
  options = options or {}

  local sup = supervisor.new({
    clock = ports.clock,
    onError = options.onError,
  })

  local context = {
    clock = ports.clock,
    storage = ports.storage,
    transport = ports.transport,
    locator = ports.locator,
    body = ports.body,
    serialise = ports.serialise,

    -- What this turtle has already carried out, read from disk. A missing file
    -- means generation zero, so the next order looks new - which is the safe
    -- direction, because every mode is idempotent.
    state = options.state or agent.load(ports),

    -- ICOS 1's node record and control flags, untouched. `miner/runtime.lua`
    -- reads both and neither knows this file exists.
    node = options.node or {},
    flags = options.flags or {},

    snapshot = options.snapshot or function()
      return {}
    end,
    runJob = options.runJob or function() end,

    -- The launcher, not a stub. A turtle whose controls service does nothing is
    -- a turtle somebody has to diagnose by reading a log file over the top of a
    -- program that is still running.
    runControls = options.runControls or function(inner)
      return require("os.client.shell").run(inner, {
        role = "turtle",
        surface = "launcher",
        -- A turtle's screen is 39x13 with the job's own status above it, so the
        -- table gets what is left rather than a client's eight rows.
        capacity = 5,
      })
    end,
  }

  -- Resolved before the services start, so the job service has something to
  -- run and the first heartbeat already reports the truth rather than a job
  -- name the base will have to correct on the next one.
  local capabilities = options.capabilities or turtleOs.capabilities(ports)
  local entry, corrected, runnable, why = turtleOs.selectJob(context.node, capabilities)
  context.job = entry
  context.jobRunnable = runnable
  context.jobProblem = why

  if corrected then
    -- Written once, here. A node whose job was renamed two versions ago would
    -- otherwise be re-translated on every boot forever, and the one thing worse
    -- than a stale record is a stale record that looks fresh.
    context.node.job = entry.id
    context.nodeChanged = true
  end

  for _, definition in ipairs(turtleOs.services()) do
    sup:add(definition)
  end

  -- What the Services page reads. Attached after construction rather than built
  -- into the context, because a context holding the supervisor that was started
  -- with that context is a cycle the serialiser would refuse - and that is
  -- discovered when a state file quietly stops being written.
  context.supervisor = sup

  sup:start(context)

  return { supervisor = sup, context = context, ports = ports }
end

return turtleOs
