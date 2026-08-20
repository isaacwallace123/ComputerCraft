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
--- `legacy/apps/miner.lua` runs four coroutines under `parallel.waitForAny`, which
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
--- `legacy/miner/runtime.lua` is what drives a turtle today, it is proven, and the
--- fleet is running it right now. Rewriting it in the same change that rewrites
--- supervision and orders would put a fleet in a hole with two untested halves.
--- So the job service calls it, `control.lua` writes the flags it already reads,
--- and from the runtime point of view nothing happened. Its eventual replacement
--- is a job module like any other, which is the point of not calling this
--- directory `miner`.
---
--- ## What starts it
---
--- `startup.lua` on power-up, through `os/kernel/boot.lua`, which maps the role
--- in `.node` onto one of four operating systems. `icos` starts the same thing
--- by hand.

local agent = require("os.turtle.agent")
local calibrate = require("os.turtle.calibrate")
local control = require("os.turtle.control")
local gps = require("os.kernel.services.gps")
local peer = require("domain.protocol.peer")
local jobs = require("domain.turtle.jobs")
local legacyLink = require("os.turtle.legacy")
local service = require("os.kernel.service")
local supervisor = require("os.kernel.supervisor")
local switches = require("os.kernel.switches")
local wire = require("domain.protocol.message")

local turtleOs = {}

turtleOs.PROTOCOL = wire.NAME

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
--- `machine` is what `adapters/cc/machine.lua` reported about the hardware, or
--- nil in a spec that has no hardware to report. The two vocabularies are
--- deliberately different - that one answers "what is this computer", this one
--- answers "what can a job ask of it" - so the translation happens here, once,
--- rather than every job learning both.
function turtleOs.capabilities(ports, machine)
  local body = ports.body
  local level = body and body.fuel() or 0

  return {
    -- Level -1 is an unlimited-fuel world, where every job is fuelled forever.
    fuel = level ~= 0,
    dig = body ~= nil,
    place = body ~= nil,
    modem = ports.transport ~= nil and ports.transport.id() ~= nil,

    -- The one capability in this table that can actually be observed rather than
    -- assumed: the chunk loader is a peripheral, so it either answers or it does
    -- not. A turtle without one is refused the `general` job at setup instead of
    -- being posted to a chunk it cannot hold - which would look like coverage on
    -- the base and be nothing at all in the world.
    chunky = machine ~= nil and machine.chunkLoaded == true,
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

      -- To the base if we know which computer it is, and to everybody only
      -- until it has answered once. A broadcast wakes every machine in range and
      -- makes each one resume every service it has to discard the message; see
      -- `domain/protocol/peer.lua` for why that is the fleet's problem and not
      -- just this turtle's.
      peer.send(
        context.peer,
        context.transport,
        wire.stamp(agent.heartbeat(context.state, snapshot)),
        turtleOs.PROTOCOL,
        context.clock.now()
      )

      -- A short receive rather than a sleep, so a reply is picked up as soon as
      -- it lands instead of on the next tick of a timer that knows nothing
      -- about it.
      local sender, message, protocol =
        context.transport.receive(turtleOs.PROTOCOL, turtleOs.HEARTBEAT)
      if sender ~= nil and protocol == turtleOs.PROTOCOL then
        -- The base is whoever sent a `desired`, and only the base sends one.
        --
        -- This used to bind to the sender of anything that arrived. Until a
        -- device has bound it broadcasts, and every other device in range hears
        -- it - so two turtles booting together each heard the other's heartbeat,
        -- each bound to the other, and both spent the rest of the day unicasting
        -- their status to a machine that keeps no registry. They kept working and
        -- went offline on the one screen that decides whether they are alive.
        if type(message) == "table" and message.kind == "desired" then
          peer.remember(context.peer, sender, context.clock.now())
        end

        turtleOs.orders(context, message)

        -- Anything else that needs to see a message registers here, for the
        -- reason `os/server/services/discovery.lua` gives: receiving consumes,
        -- so only one loop may call it, and a second reader would silently eat
        -- half the traffic while looking perfectly healthy. The sector client
        -- is the one that needs it - its reply arrives here, not where it asked.
        for _, handler in ipairs(context.handlers or {}) do
          handler(context, sender, message)
        end
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
  -- Who this turtle works with, kept whether or not there is an order attached.
  --
  -- Derived on the server from the chunk claims and sent down rather than worked
  -- out here, because working it out here would mean every turtle holding a copy
  -- of the coverage state to answer a question about itself. Stored before the
  -- order is read: a heartbeat reply with nothing to carry out still tells a
  -- general who its crew is, and dropping it would leave a general that has
  -- converged showing "nobody yet" forever.
  if type(message) == "table" then
    context.state.general = message.general
    context.state.crew = message.crew
  end

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

--- Find out where this turtle is, from the constellation.
---
--- A service rather than a step in boot, and the difference matters: it needs a
--- GPS constellation, which on a base that is still coming up does not exist for
--- the first few seconds. A boot step would ask once, fail, and leave the turtle
--- unlocated until somebody rebooted it - which is exactly the state the whole
--- fleet was found in.
---
--- So it retries, slowly, and stops the moment it succeeds. `run` returning
--- would be a fault to the supervisor, so it parks instead.
---
--- **Only while parked.** The calibration steps one block forward and back, and
--- a turtle doing that in the middle of a quarry cycle is a turtle that has
--- moved without its navigator knowing. Parked is the same condition
--- `domain/gps/host.lua` uses for hosting, for the same reason.
turtleOs.locate = service.define({
  id = "locate",
  requires = { "locator", "body", "clock" },

  -- Not critical. A turtle that does not know where it is cannot take a shared
  -- mine sector and can still be recalled, and D004 says the radio being down
  -- must not stop the machine - this is the same rule one layer up.
  critical = false,

  run = function(context)
    local nav = context.nav
    while true do
      if nav ~= nil and calibrate.needed(nav) and context.node and context.node.parked then
        local found, why = calibrate.run(context.body, context.locator)
        if found then
          -- Both files in one call. Two that disagreed about which way home is
          -- would be a turtle mining confidently in the wrong direction.
          nav.setOrigin(found.x, found.y, found.z, found.heading)

          -- Guarded, because a machine assembled without one is a real shape -
          -- every spec is - and the origin has already been written by the line
          -- above. Throwing here would restart the service and lose the reason.
          if context.saveLocation then
            context.saveLocation({
              x = found.x,
              y = found.y,
              z = found.z,
              heading = found.heading,
            })
          end
          context.locateWhy = nil
          if context.log then
            context.log.info(
              ("located at %d, %d, %d facing %s"):format(
                found.x,
                found.y,
                found.z,
                require("domain.gps.fix").compass(found.heading)
              )
            )
          end
        else
          -- On the screen, not only in the log.
          --
          -- A turtle has no Logs page any more, so a reason written only to
          -- `.log` is a reason nobody standing in front of the machine can read
          -- - and "no position" with no explanation is exactly the state the
          -- whole fleet was found in. The turtle's own screen is where somebody
          -- is looking when they want to know.
          -- On the context, not on `context.state`. That table is the applied
          -- generation and is written to disk on every order; a transient
          -- diagnostic in it would be persisted, and a stale one would survive a
          -- reboot to describe an attempt that never happened.
          context.locateWhy = why

          if context.log then
            -- Once per attempt, and the attempts are a minute apart. A turtle
            -- with no constellation in range would otherwise fill its own disk
            -- saying so, on the machine least able to spare it.
            context.log.warn("locate: " .. tostring(why))
          end
        end
      end

      context.clock.sleep(context.locateEvery or turtleOs.LOCATE_EVERY)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

--- Seconds between attempts to find out where we are.
---
--- A minute. The constellation either exists or does not, and a turtle that
--- retried every second would spend a move and a GPS round trip sixty times a
--- minute discovering the same thing.
turtleOs.LOCATE_EVERY = 60

--- The services a turtle runs.
---
--- `legacy` is the odd one and is temporary by design: it is the turtle's
--- `ccfleet` side, and it exists only for the window in which an upgraded turtle
--- is talking to a base that has not been upgraded yet. §12 says that window is
--- the normal case during a rolling update, because turtles update before the
--- base does. It now falls silent on its own once an ICOS 2 base answers, so the
--- cost of keeping it is nothing on a converged fleet.
---
--- **No ticker.** Every other machine has one because its pages recompute from a
--- value that has to move; a turtle's screen is `os/turtle/screen.lua`, which
--- redraws when what it says changes and not on a clock. Keeping it would be a
--- queued event every second that wakes every service on the machine so that
--- nothing can look at it - and on a shared budget, so that nothing on any other
--- machine can either.
---
--- That also takes `ui/state/reactive.lua` off the turtle entirely.
function turtleOs.services()
  return {
    turtleOs.job,
    turtleOs.heartbeat,
    turtleOs.controls,
    turtleOs.locate,
    legacyLink.service,
    gps.service,
  }
end

---------------------------------------------------------------------------
-- Composition
---------------------------------------------------------------------------

--- Build a supervised turtle, ready to be stepped.
---
--- `options.snapshot`, `options.runJob` and `options.runControls` are the seams
--- where ICOS 1 is plugged in - the entrypoint passes `ctx:snapshot()` and the
--- two `legacy/miner/runtime.lua` loops, and a spec passes three functions and no
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
    body = ports.body,
    serialise = ports.serialise,
    beacon = ports.beacon,
    locator = ports.locator,
    peripherals = ports.peripherals,

    -- The turtle's own screen.
    --
    -- Missing until the first in-world boot, and the symptom was the worst kind:
    -- the turtle looked hung on the splash. It was not - every service was
    -- running - but `controls` builds the launcher, the launcher mounts a page
    -- on `context.screen`, and a nil screen threw before anything drew. So the
    -- splash stayed on the display and a working machine looked dead.
    --
    -- A machine that is fine and looks broken is worse than one that is broken
    -- and says so, because the first thing somebody does is reboot it.
    screen = ports.screen,
    input = ports.input,
    saveLocation = ports.saveLocation,

    -- A turtle owns nothing the fleet cares about, so its pages ask over the
    -- radio like a client's do. See `os/kernel/request.lua` for why this is a
    -- function on the context rather than each page reaching for the transport.
    request = require("os.kernel.request").remote(ports.transport, wire.NAME),
    log = ports.log,

    -- What this turtle has already carried out, read from disk. A missing file
    -- means generation zero, so the next order looks new - which is the safe
    -- direction, because every mode is idempotent.
    state = options.state or agent.load(ports),

    -- ICOS 1's node record and control flags, untouched. `legacy/miner/runtime.lua`
    -- reads both and neither knows this file exists.
    node = options.node or {},
    flags = options.flags or {},

    -- Who answered last, so the next heartbeat is a message rather than a shout.
    peer = peer.empty(),

    -- The navigator, when this machine has one.
    --
    -- Injected rather than required at the top of this file, for the reason the
    -- turtle engine is: `os/turtle/device/nav.lua` reads `fs` and `turtle` at
    -- load, and a spec that only wanted to check supervision should not have to
    -- own a filesystem. A caller that brings its own is believed.
    nav = options.nav,

    snapshot = options.snapshot or function()
      return {}
    end,
    runJob = options.runJob or function() end,

    -- One page, drawn straight at the screen port - not the desktop.
    --
    -- The framework costs about three milliseconds and eighteen modules to load,
    -- keeps a reactive graph, a layout solver and a double buffer alive for the
    -- life of the machine, and re-solves a tree whenever the tick moves. What it
    -- bought here was an app switcher for four pages on a 39x13 screen that
    -- somebody looks at after walking to a stopped turtle.
    --
    -- That is not a trade worth making at any price, and CC charges it to a
    -- budget the whole world shares - so a turtle drawing a desktop is spending
    -- the base station's time. See `os/turtle/screen.lua`.
    runControls = options.runControls or function(inner)
      return require("os.turtle.screen").run(inner)
    end,
  }

  -- The mine link, and the mailbox its replies land in.
  --
  -- `os/turtle/site.lua` is shared with ICOS 1 and deliberately does not know
  -- which protocol it is on, so the composition root says. Required here rather
  -- than at the top of the file because it reaches for `fs` through the config
  -- adapter, and a spec that only wanted to check supervision should not have
  -- to own a filesystem.
  -- A turtle counts every confirmed move, so it knows exactly when it is under
  -- way - which is what lets it host at all. Parked is the only state in which
  -- the position on disk is the position it is standing on.
  --
  -- Read from the node on every call rather than captured, because parking is
  -- the thing that changes most often on a turtle and a captured value would be
  -- wrong within a minute of booting.
  context.anchored = function()
    if context.node.parked then
      return true
    end
    return false, "mining - a turtle hosts only while parked"
  end

  -- How the legacy loop reaches the order path without requiring this file and
  -- making a cycle. A function on the context rather than a require, which is
  -- the same shape `context.handlers` uses and for the same reason.
  context.orders = turtleOs.orders

  local site = require("os.turtle.site")
  site.attach({
    broadcast = function(body)
      context.transport.broadcast(wire.stamp({ kind = "mine", body = body }), turtleOs.PROTOCOL)

      -- And on the old protocol, so a turtle under an un-upgraded base is still
      -- given a sector. Without this an upgraded turtle either idles or digs
      -- where somebody else is digging, which is the collision D018 exists to
      -- prevent, reintroduced by the upgrade meant to improve things.
      legacyLink.mine(context, body)
      -- `transport.broadcast` reports nothing - the port says so, because a
      -- broadcast has no addressee to have reached. So "did this get out" is
      -- answered by whether the radio is open at all, which `os/kernel/boot.lua`
      -- recorded when it opened it. False sends the turtle down its offline
      -- path, which is the right answer for a machine with no modem.
      return ports.radio ~= nil and ports.radio.open == true
    end,
  })

  context.handlers = options.handlers
    or {
      function(_, _, message)
        if type(message) == "table" and message.kind == "mine_result" then
          site.deliver(message)
        end
      end,
    }

  -- Resolved before the services start, so the job service has something to
  -- run and the first heartbeat already reports the truth rather than a job
  -- name the base will have to correct on the next one.
  local capabilities = options.capabilities or turtleOs.capabilities(ports, options.machine)
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

  -- What somebody switched off on the Services page, last time this machine was
  -- up. Applied before starting, so a service meant to stay off never runs at
  -- all rather than running until the first frame can stop it.
  --
  -- This is what makes a configuration a configuration: a GPS host is a client
  -- with the fleet mirror and the desktop switched off, and until the choice
  -- survived a reboot that was a thing somebody had to redo every restart.
  switches.apply(sup, switches.load(context))

  sup:start(context)

  return { supervisor = sup, context = context, ports = ports }
end

return turtleOs
