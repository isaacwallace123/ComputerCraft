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

local roles = require("os.roles")

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
    screen = require("adapters.cc.screen").new(term),
    input = require("adapters.cc.input").new(),
  }
  if turtle then
    built.body = require("adapters.cc.body").new()
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

--- Build the machine this computer is, without starting the loop.
---
--- Separated from `run` so that a person can boot a role, inspect its health,
--- and stop - which is what `icos2 status` does, and what somebody debugging a
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
      machine.supervisor:step(event)
      machine.supervisor:stop()
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
