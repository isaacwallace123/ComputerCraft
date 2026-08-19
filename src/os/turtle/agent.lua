--- The device side of desired state: deciding what to do about a reply.
---
--- `domain/fleet/desired.lua` holds the rules. This holds the turtle's half of
--- the conversation: what it persists, what it puts in a heartbeat, and what it
--- does with what comes back.
---
--- ## It must survive the server not existing
---
--- D004, and it is the reason every function here has a nil path that means
--- "carry on". A turtle that cannot reach the base keeps working; a turtle that
--- receives nonsense keeps working; a turtle whose base has been broken for a
--- week keeps working and comes home when its own fuel says so. Nothing in this
--- file can produce a stopped turtle, because nothing in it is reached without a
--- message having arrived first.
---
--- ## Both protocols, during the rolling update
---
--- §12 has the server sending desired state *and* the old `command` message
--- until every device converges. A turtle running this file will therefore
--- receive both, and will act on both - which is harmless, because every mode is
--- a state to be in rather than an action to perform, so recall twice is recall.
---
--- It would be tidier to ignore commands here and rely on desired state alone.
--- That is wrong for a reason worth writing down: **turtles update before the
--- base does.** The updater deploys by manifest and a fleet upgrades a machine
--- at a time, so there is a window where a new turtle is talking to an old
--- server that has never heard of desired state. A turtle that ignored commands
--- in that window would ignore recall, which is a safety control.
---
--- So it takes both, and stops taking commands only when the server stops
--- sending them - which is one switch, in one place, thrown once.
---
--- ## The applied generation is persisted, and that is what makes reboot safe
---
--- A turtle that recalled, parked, and then rebooted must not recall again: the
--- order was carried out, and re-running it on every boot would be a turtle that
--- could never be redeployed. `state.applied` is written to disk and read back,
--- which turns "have I done this?" into a question with an answer.

local desired = require("domain.fleet.desired")
local wire = require("domain.protocol.message")

local agent = {}

agent.PROTOCOL = wire.NAME

--- Where the applied generation lives.
---
--- Its own file rather than a field in `.node`. `.node` is written by setup and
--- read at boot by code that predates all of this; adding a field to it would
--- mean an ICOS 1 build reading a file with something it does not expect, and
--- the whole migration story rests on old code tolerating new files by not
--- knowing about them.
agent.PATH = ".desired"

function agent.empty()
  return { applied = 0, mode = nil }
end

--- Read what this turtle has already carried out.
---
--- A missing or unreadable file means zero, which means the next order it sees
--- is new. That is the safe direction: worst case a turtle re-applies an order
--- it had already applied, and every mode is idempotent precisely so that costs
--- nothing.
function agent.load(ports)
  local text = ports.storage.read(agent.PATH)
  if text == nil then
    return agent.empty()
  end
  local ok, saved = pcall(ports.serialise.decode, text)
  if not ok or type(saved) ~= "table" then
    return agent.empty()
  end
  saved.applied = tonumber(saved.applied) or 0
  return saved
end

function agent.save(ports, state)
  return ports.storage.write(agent.PATH, ports.serialise.encode(state))
end

--- What this turtle puts in a heartbeat.
---
--- The applied generation rides alongside the snapshot, which is what lets the
--- server tell converged from pending without asking a second question.
function agent.heartbeat(state, snapshot)
  return {
    kind = "status",
    applied = desired.report(state.applied, state.mode),
    snapshot = snapshot,
  }
end

--- Decide what to do about an incoming message.
---
--- Returns an intent - `{ mode, job, settings, generation, source }` - or nil for
--- "carry on unchanged". Nil is the common answer: a duplicate, a stale reply, a
--- malformed message, a message for somebody else, and no message at all all
--- come back nil, and in every one of those cases the turtle keeps doing what it
--- was already doing.
---
--- The intent is returned rather than acted on so that this is testable without
--- a turtle. Translating an intent into the runtime's control flags is the
--- composition root's job, and it is the only place that knows what a control
--- flag is.
function agent.receive(state, message)
  -- The device's half of the version gate the server applies in
  -- `discovery.dispatch`. It refuses the same two things and nothing else: a
  -- message from a build ahead of this one is accepted, because the turtle is
  -- the machine most likely to be *behind* - the updater upgrades the base
  -- before the fleet finishes, and a turtle that ignored a newer recall would
  -- ignore a safety control for the length of the rollout.
  message = wire.accept(message)
  if message == nil then
    return nil
  end

  if message.kind == "desired" then
    local accepted = desired.apply(state.applied, message.desired)
    if accepted == nil then
      return nil
    end
    return {
      mode = accepted.mode,
      job = accepted.job,
      settings = accepted.settings,
      reason = accepted.reason,
      generation = accepted.generation,
      source = "desired",
    }
  end

  -- The old protocol, during the rolling update. No generation, so nothing is
  -- recorded as applied and the same command arriving twice acts twice - which
  -- is exactly how ICOS 1 behaves today and is safe for the same reason it has
  -- always been safe: these are states, not actions.
  if message.kind == "command" and type(message.command) == "table" then
    local intent = agent.fromCommand(message.command)
    if intent then
      intent.source = "command"
    end
    return intent
  end

  return nil
end

--- Translate an ICOS 1 command into the same intent shape.
---
--- Only the commands that mean "be in this state". `status_request` and the
--- configure/set_job pair are handled by the existing ICOS 1 path and are not
--- desired state, so they are deliberately not mapped: turning a query into a
--- mode would make a dashboard refresh look like an order.
function agent.fromCommand(command)
  local action = command.action
  if action == "recall" then
    return { mode = "recall" }
  end
  if action == "update" then
    return { mode = "update" }
  end
  if action == "deploy" then
    return { mode = "deploy" }
  end
  if action == "assign_job" then
    return { mode = "deploy", job = command.job, settings = command.settings }
  end
  return nil
end

--- Record that an intent was carried out.
---
--- Only a desired-state intent moves the applied generation; a command has none
--- to move. That asymmetry is what makes a turtle that only ever hears commands
--- report generation 0 forever, and therefore show as never converged - which is
--- the honest answer, because it has applied nothing it could name.
function agent.applied(state, intent)
  state.mode = intent.mode
  if intent.source == "desired" and intent.generation then
    state.applied = intent.generation
  end
  return state
end

return agent
