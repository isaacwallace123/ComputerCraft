--- The miner: a turtle that mines, and the three loops that keep it honest.
---
--- §2 of docs/icos-2.md. This is the composition root for a mining turtle - it
--- wires ports to services and hands both to the supervisor, and it decides
--- nothing. Everything that decides anything is in `domain/` or in
--- `os/miner/agent.lua` and `os/miner/control.lua`, both of which are testable
--- without a turtle.
---
--- ## The bug this file exists to fix
---
--- `apps/miner.lua` runs four coroutines under `parallel.waitForAny`, which
--- returns when **any** of them finishes. So a heartbeat loop that throws on a
--- missing modem takes the mining job down with it, and a turtle that was
--- halfway down a shaft stops - not because mining failed, but because talking
--- about mining failed. D004 says job correctness may never depend on a message
--- arriving, and `waitForAny` is a direct contradiction of it sitting in the
--- entrypoint.
---
--- The supervisor restarts the loop that failed and leaves the others running.
--- The mining job carries on down the shaft while the radio backs off and
--- retries, which is what D004 asked for in the first place.
---
--- ## It runs the ICOS 1 job code unchanged
---
--- `miner/runtime.lua` is what actually drives a turtle, it is proven, and the
--- fleet is running it right now. Rewriting it in the same change that rewrites
--- supervision and orders would put a fleet in a hole with two untested halves.
--- So the job service calls it, `control.lua` writes the flags it already reads,
--- and from the runtime's point of view nothing happened.
---
--- ## It does not run yet
---
--- Nothing calls `boot`. `src/startup.lua` still starts `apps/miner.lua`, and
--- switching it over is the change that alters what a turtle does on power-up -
--- the one thing in this branch that reaches a running fleet. It waits for an
--- in-world test rather than riding along with the rest.

local agent = require("os.miner.agent")
local control = require("os.miner.control")
local service = require("os.service")
local supervisor = require("os.supervisor")

local miner = {}

miner.PROTOCOL = "icos"

--- Seconds between heartbeats.
---
--- Two, matching ICOS 1. It is what `registry.LATE_AFTER` and `OFFLINE_AFTER`
--- are calibrated against, so changing it here would silently re-tune when the
--- base decides a turtle has gone quiet.
miner.HEARTBEAT = 2

---------------------------------------------------------------------------
-- Services
---------------------------------------------------------------------------

--- Say what this turtle is doing, and hear what it should be.
---
--- One loop rather than two, unlike ICOS 1's `heartbeat` and `commands`. The
--- exchange is a request and its reply, and splitting it meant a turtle whose
--- receive loop had died kept reporting cheerfully while ignoring every order -
--- which looks identical, from the base, to a turtle that is fine.
miner.heartbeat = service.define({
  id = "heartbeat",
  requires = { "transport", "clock", "state" },

  -- Not critical, and this is the whole point of the file. A turtle that cannot
  -- talk to the base is a turtle that keeps mining. D004: the job is correct
  -- without the radio, so the radio being down must not make the machine
  -- unhealthy or stop anything else.
  critical = false,

  run = function(context)
    while true do
      local snapshot = context.snapshot()
      context.transport.broadcast(agent.heartbeat(context.state, snapshot), miner.PROTOCOL)

      -- A short receive rather than a sleep, so a reply is picked up as soon as
      -- it lands instead of on the next tick of a timer that knows nothing
      -- about it.
      local sender, message, protocol = context.transport.receive(miner.PROTOCOL, miner.HEARTBEAT)
      if sender ~= nil and protocol == miner.PROTOCOL then
        miner.orders(context, message)
      end
    end
  end,
})

--- Act on one message. Returns what happened, or nil if it was not for us.
---
--- Separated from the loop for the reason every service here separates them:
--- anything worth testing that lives inside a `while true` is something that
--- cannot be tested.
function miner.orders(context, message)
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
--- The one service that is critical, because it is the machine's entire job. If
--- this gives up, the turtle is a box in a hole and the supervisor should say
--- so rather than report a healthy machine that is not mining.
miner.job = service.define({
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
miner.controls = service.define({
  id = "controls",
  requires = { "state" },
  critical = false,

  run = function(context)
    return context.runControls(context)
  end,
})

function miner.services()
  return { miner.job, miner.heartbeat, miner.controls }
end

---------------------------------------------------------------------------
-- Composition
---------------------------------------------------------------------------

--- Build a supervised miner, ready to be stepped.
---
--- `options.snapshot`, `options.runJob` and `options.runControls` are the seams
--- where ICOS 1 is plugged in - the entrypoint passes `ctx:snapshot()` and the
--- two `miner/runtime.lua` loops, and a spec passes three functions and no
--- turtle. That is the only reason they are parameters rather than requires.
function miner.boot(ports, options)
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
    runControls = options.runControls or function() end,
  }

  for _, definition in ipairs(miner.services()) do
    sup:add(definition)
  end
  sup:start(context)

  return { supervisor = sup, context = context, ports = ports }
end

return miner
