--- Building a machine: ports from CC, a role from disk, a supervisor to run.
---
--- The one file in ICOS 2 that is allowed to know both that CC exists and that
--- there are four operating systems. Everything below it knows one or the other
--- and never both, which is what makes the whole tree testable: `domain/` knows
--- neither, `ports/` and `os/` know the shape without the implementation, and
--- `adapters/cc/` knows CC without knowing what anybody does with it.
---
--- ## The event loop is here, not in the supervisor
---
--- `Supervisor:step(event)` resumes services and returns; it does not pull
--- events, because a supervisor that pulled events could not be driven by a
--- spec. So the loop that calls `os.pullEventRaw` lives in the one file that is
--- already allowed to name CC globals, and the supervisor stays a pure state
--- machine over coroutines.
---
--- `pullEventRaw` rather than `pullEvent`: terminate has to reach the services
--- so they can be stopped in order, rather than unwinding this loop from
--- underneath them.
---
--- ## Nothing here decides policy
---
--- It wires and it loops. Which services exist is `os/<role>/main.lua`; what
--- they do is `domain/`. If this file grows an `if` about mining, the `if` is in
--- the wrong place.

local roles = require("os.kernel.roles")

local boot = {}

--- Every port a machine might need, built from the CC adapters.
---
--- All of them, on every role, rather than a per-role subset. A port is a table
--- of functions and costs nothing to construct, while a subset would mean four
--- lists to keep in step with `requires` declarations that already say the same
--- thing - and the supervisor already refuses to start a service whose ports are
--- absent, which is the check that actually runs.
---
--- The exception is `body`, which is `turtle` and does not exist on anything
--- else. It is nil there rather than a null, because a null body would let a
--- non-turtle service declare `requires = { "body" }` and start successfully on
--- a machine with no arms.
function boot.ports()
  local built = {
    clock = require("adapters.cc.clock").new(),
    log = require("adapters.cc.log").new(),
    storage = require("adapters.cc.storage").new(),
    serialise = require("adapters.cc.serialise").new(),
    transport = require("adapters.cc.transport").new(),
    locator = require("adapters.cc.locator").new(),
    beacon = require("adapters.cc.beacon").new(),
    peripherals = require("adapters.cc.peripherals").new(),

    -- The write half of the locator. `locator` reads `.location`; nothing could
    -- write it except `commands/locate`, so a machine that corrected itself
    -- against the constellation on boot would have thrown the correction away
    -- the moment it rebooted - the whole point of refreshing, silently undone.
    --
    -- A function rather than a port method because it is one write to one file
    -- and widening the locator port would mean every null and every spec
    -- carrying a setter that only one caller uses.
    saveLocation = function(record)
      local locator = require("adapters.cc.locator")
      return require("adapters.cc.config").save(locator.PATH, record)
    end,
    screen = require("adapters.cc.screen").new(term),

    -- Filtered, not the raw queue. A base station runs two screens and the
    -- supervisor hands every event to every service, so an unfiltered terminal
    -- port would have the wall's touches driving the keyboard desktop as well.
    input = require("adapters.cc.input").terminal(),
  }
  if turtle then
    built.body = require("adapters.cc.body").new()
  end

  -- The wall, if there is one.
  --
  -- Discovered here rather than by whoever draws, because picking a monitor
  -- means comparing physical walls and setting a text scale - a decision about
  -- hardware, which is what this file is for. A machine with no monitor gets
  -- nil and simply draws on its own terminal, which is most machines.
  --
  -- Its input port is scoped to that monitor's name so a base with two walls
  -- cannot act on a tap meant for the other one, and so the dashboard surface
  -- never receives a keystroke at all (D020).
  local wall, wallName, size = require("adapters.cc.display").attach({
    naturalLess = require("lib.util").naturalLess,
  })
  if wall then
    built.wall = wall
    built.wallName = wallName
    built.wallSize = size
    -- Woken by the machine's own tick as well as by touches. A wall that only
    -- woke on a touch drew its first frame and then showed it forever, and a
    -- fleet dashboard frozen at boot looks like a fleet rather than like a
    -- fault. The constant comes from here because this is the layer that knows
    -- both halves; see `adapters/cc/input.lua`.
    built.wallInput =
      require("adapters.cc.input").monitor(wallName, require("os.kernel.services.ticker").EVENT)
  end

  return built
end

--- Which composition root a role uses.
---
--- A table rather than a chain of `if`s, so adding a fifth operating system is
--- one line here and one directory - and so this file cannot quietly acquire an
--- opinion about which roles are more important.
boot.ROOTS = {
  [roles.SERVER] = "os.server.main",
  [roles.CLIENT] = "os.client.main",
  [roles.TURTLE] = "os.turtle.main",
  [roles.MOBILE] = "os.mobile.main",
}

--- Extra options a role needs wired before its composition root is built.
---
--- A table for the same reason `ROOTS` is one: a branch here would be this file
--- growing an opinion about mining, which its own header forbids. A role either
--- has an entry or it does not.
---
--- Only the turtle has one, and only until `legacy/` is gone. `os/turtle/main.lua`
--- declares `runJob` and `runControls` as seams and defaults them to a stub and
--- a launcher, which means a turtle booted without this heartbeats, obeys
--- recall, and never mines. `os/turtle/engine.lua` is what fills them, and it is
--- the turtle's entire remaining dependency on ICOS 1.
--- `when` is the seam whose absence means "this machine has no engine". It is
--- declared so the wiring can be *skipped* without being *run*, which is the
--- whole reason this is not just a function: building the turtle's engine
--- constructs an ICOS 1 context, which reads `turtle` and `peripheral` and
--- paints a screen. A caller that brought its own - every spec does - must not
--- pay for one, and calling it to find out would be finding out too late.
---
--- One key rather than the whole list it fills, because `node` and `flags` have
--- their own harmless defaults in `os/turtle/main.lua` and a caller omitting
--- those is saying nothing about whether it wants an engine. `runJob` is the
--- one that means it.
boot.WIRING = {
  [roles.TURTLE] = {
    when = "runJob",
    build = function()
      return require("os.turtle.engine").new()
    end,
  },
}

--- Build the machine this computer is, without starting the loop.
---
--- Separated from `run` so that a person can boot a role, inspect its health,
--- and stop - which is what `icos status` does, and what somebody debugging a
--- base station at 2am needs to be able to do without committing to a loop that
--- never returns.
function boot.machine(node, options)
  options = options or {}
  local role = options.role or roles.roleOf(node)
  local moduleName = boot.ROOTS[role]
  if moduleName == nil then
    return nil, "no operating system for role " .. tostring(role)
  end

  local ports = options.ports or boot.ports()

  -- Open the radio, once, here - and here rather than inside `boot.ports`.
  --
  -- The transport adapter deliberately does not open a modem on construction,
  -- so that a missing one is discovered as a setup problem with a message
  -- rather than as messages quietly going nowhere. Nothing then called `open`
  -- either, which produced exactly the outcome that rule exists to prevent: a
  -- server whose every send returned false and whose every receive timed out,
  -- reporting itself perfectly healthy.
  --
  -- Putting it in `boot.ports` would have fixed that on hardware and left the
  -- spec suite exercising a different path, because every spec injects its
  -- ports and would have skipped the call. Opening the radio is part of
  -- building a *machine*, not part of building the CC bundle, and doing it
  -- where both paths meet is what makes the tested behaviour the real one.
  --
  -- Not asserted. A machine with no modem must still boot - a turtle with no
  -- radio keeps mining, which is D004 stated as hardware - so the outcome is
  -- recorded for `icos status` to print instead. The services that genuinely
  -- cannot work without a radio say so themselves by failing to start.
  local opened, why = ports.transport.open()
  ports.radio = { open = opened == true, reason = why }

  -- What this computer actually is, asked once and handed down.
  --
  -- `adapters/cc/machine.lua` was written for `roles.check` and `roles.offered`
  -- and **nothing had ever called it** - every caller was a spec passing a
  -- literal, so the layer that answers "can this machine be what it claims"
  -- existed and never ran. This is the call it was waiting for.
  --
  -- Built here rather than in `boot.ports` because it is a fact about the
  -- machine rather than a port, and because it needs the locator port to answer
  -- whether the machine knows where it is. A caller that brought its own - every
  -- spec does - keeps it.
  options.machine = options.machine or require("adapters.cc.machine").capabilities(ports)

  -- Can this machine be what its `.node` says it is?
  --
  -- Asked here and *recorded* rather than enforced, which is the deliberate half.
  -- `roles.check` produces a sentence somebody can act on - "a server needs a
  -- wireless or ender modem" - and refusing to boot on it would leave a base
  -- station that cannot be used to fix the base station. So the machine starts,
  -- the services that genuinely cannot work say so themselves by failing, and
  -- `icos status` prints the sentence.
  local ok, note = roles.check(role, options.machine)
  ports.role = { ok = ok, note = note, plan = roles.plan(node, options.machine) }

  -- The one place that decides what is worth writing down.
  --
  -- Every service returns what it did rather than logging it, because a service
  -- that wrote to a log would be deciding how a machine reports things - and on
  -- a Pocket Computer that log is somewhere else. This is the other end of that
  -- rule: the composition root has the facts and knows what kind of machine it
  -- is, so it is what records them.
  --
  -- Only failures, and only through the supervisor's own hook. A boot that
  -- logged every service starting would put seven lines in the file every time
  -- a base station reloads a chunk, and the log's whole value is that the lines
  -- in it are worth reading.
  options.onError = options.onError
    or (
      ports.log
      and function(id, reason, failures)
        -- The first failure is warned about and the rest are errors. A service
        -- that fails once and restarts is ordinary - a radio going out of range
        -- does it - and a machine that shouted about every one would train
        -- somebody to skip the shouting.
        local write = failures and failures > 1 and ports.log.error or ports.log.warn
        write(("%s: %s"):format(tostring(id), tostring(reason)))
      end
    )

  -- Merged rather than replaced, so a caller that brought its own seams keeps
  -- them. The wiring is a default, not an override: a spec that wants a turtle
  -- with no arms says so and is believed.
  local wiring = boot.WIRING[role]
  if wiring and options.wire ~= false and options[wiring.when] == nil then
    for key, value in pairs(wiring.build()) do
      if options[key] == nil then
        options[key] = value
      end
    end
  end

  local machine = require(moduleName).boot(ports, options)
  machine.role = role
  return machine
end

--- Run a machine until it is terminated.
---
--- The first step is taken with no event, because services have not been
--- resumed yet and are waiting for their context rather than for anything that
--- happened. Every step after it carries a real event.
---
--- Returns the reason it stopped, so the caller can tell "somebody pressed
--- Ctrl-T" from "the machine decided to stop", and print accordingly. A turtle
--- that stopped because it was told to should not print an error.
function boot.run(machine, pull)
  pull = pull or function()
    return { os.pullEventRaw() }
  end

  machine.supervisor:step()

  while true do
    local event = pull()

    if event[1] == "terminate" then
      -- `shutdown` rather than step-then-stop, so the errors `terminate` raises
      -- inside each parked service are not reported as five separate faults.
      -- Somebody pressing Ctrl-T has not broken anything.
      machine.supervisor:shutdown(event)
      return "terminated"
    end

    machine.supervisor:step(event)

    -- A machine whose services have all given up is not a machine. Returning
    -- rather than spinning means the caller gets to say why on the screen,
    -- which is the only place anybody will see it - and a base that sat in a
    -- loop resuming nothing would look, from across the room, exactly like a
    -- base that was working.
    if machine.supervisor:running() == 0 then
      local _, why = machine.supervisor:healthy()
      return "stopped", why
    end

    -- The halt flag, which only a turtle sets and only for the `stop` mode.
    -- Checked here rather than inside a service because stopping is the one
    -- thing a service cannot do to itself: a coroutine that returns is a fault.
    if machine.context.halt then
      machine.supervisor:stop()
      return "halted"
    end
  end
end

return boot
