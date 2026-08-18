--- Driving devices towards their desired state, and the bridge to the old way.
---
--- `discovery` answers a device that asks. This is the other half: it notices a
--- device that is behind and has not asked recently, and nudges it.
---
--- ## Why a nudge is needed at all
---
--- Desired state is a pull model, and a pull model is enough for correctness - a
--- device reconciles on its next heartbeat and every property in §5 still holds.
--- But a heartbeat is every few seconds and a recall is something a person just
--- pressed, so waiting for the next one makes a correct system feel broken. The
--- nudge is latency, not correctness, which is why it may fail silently and why
--- nothing depends on it arriving.
---
--- ## The dual run, and how it ends
---
--- §12: *"Phase 3 is the one to be careful with. Recall is a safety control;
--- replacing its mechanism while turtles are underground is how a fleet gets
--- stranded. Both paths run together until the dashboard shows every device
--- converging, then events go."*
---
--- So a nudge carries **both**: the desired-state reply for a device that
--- understands it, and the ICOS 1 `command` message for one that does not. A
--- turtle on the old build obeys the command and never reports an applied
--- generation; a turtle on the new build applies the generation and converges.
--- Both are correct at once, so the fleet can be upgraded a turtle at a time.
---
--- `context.events` is the switch. Leaving it on costs one extra message per
--- nudge; turning it off is the irreversible half of phase 3 and belongs to
--- whoever is looking at the dashboard, not to this file.
---
--- ## Idempotence is what makes sending both safe
---
--- An old-style command is an instruction and a new-style reply is a goal, so a
--- device that understood both would act twice. It does not matter: `recall`
--- twice is `recall`, and `deploy` on an already-deployed turtle is refused by
--- the turtle. Every mode is a state to be in rather than an action to perform,
--- which is what §5 means by reconcilable and what makes the overlap harmless
--- rather than a race.

local desired = require("domain.fleet.desired")
local registry = require("domain.fleet.registry")
local service = require("os.kernel.service")

local reconcile = {}

reconcile.PROTOCOL = "icos"

--- How often one device may be nudged.
---
--- Six seconds: often enough that a person pressing recall sees something
--- happen, rare enough that ten pending turtles do not turn the base into a
--- transmitter. A converged device needs no nudge and an unreachable one cannot
--- hear it, so this only ever applies to the few genuinely in flight.
reconcile.EVERY = 6

--- The ICOS 1 command for a goal, or nil where there is no equivalent.
---
--- Taken from `legacy/miner/network.lua`'s existing handler, which is the authority on
--- what an unupgraded turtle understands. `park` has no command: the old
--- protocol cannot say "stop when convenient", and inventing one for a build
--- that will not understand it would be a message into the void.
---
--- `deploy` carries the job and settings as `assign_job`, because the old
--- protocol's three-message dance is exactly what §5 collapses - and a device on
--- the old build still needs all three pieces to arrive.
function reconcile.legacy(goal)
  if goal == nil then
    return nil
  end
  if goal.mode == "recall" then
    return { action = "recall" }
  end
  if goal.mode == "update" then
    return { action = "update" }
  end
  if goal.mode == "deploy" then
    if goal.job then
      return { action = "assign_job", job = goal.job, settings = goal.settings }
    end
    return { action = "deploy" }
  end
  return nil
end

--- Devices that are behind, reachable, and not nudged too recently.
---
--- Returns rows rather than sending, so a spec can ask "who would be nudged
--- now?" and get an answer with no radio anywhere. The three conditions are
--- separate on purpose: converged needs nothing, unreachable cannot hear, and
--- recently nudged has already been told.
function reconcile.due(context, now)
  local rows = {}
  for _, record in pairs(context.state.fleet.devices) do
    local goal = desired.reply(record)
    if goal ~= nil and not desired.converged(record) then
      local health = registry.health(record, now)
      local last = record.nudgedAt
      local elapsed = last == nil and math.huge or (now - last) / 1000
      if health ~= "offline" and elapsed >= (context.nudgeEvery or reconcile.EVERY) then
        rows[#rows + 1] = { id = record.id, record = record, goal = goal }
      end
    end
  end
  table.sort(rows, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)
  return rows
end

--- Send one device what it should be doing.
---
--- Best-effort, and deliberately unchecked. D004: a send reporting false is an
--- ordinary outcome for a wireless turtle, and treating it as a failure here
--- would make the server's health depend on whether a turtle happened to be in
--- range - exactly the coupling desired state removes.
function reconcile.nudge(context, row, now)
  row.record.nudgedAt = now

  context.transport.send(row.id, {
    kind = "desired",
    desired = row.goal,
    now = now,
  }, reconcile.PROTOCOL)

  if context.events ~= false then
    local command = reconcile.legacy(row.goal)
    if command then
      context.transport.send(row.id, { kind = "command", command = command }, reconcile.PROTOCOL)
    end
  end
  return true
end

--- One pass. Returns how many devices were nudged.
function reconcile.pass(context, now)
  local nudged = 0
  for _, row in ipairs(reconcile.due(context, now)) do
    reconcile.nudge(context, row, now)
    nudged = nudged + 1
  end
  return nudged
end

reconcile.service = service.define({
  id = "reconcile",
  requires = { "transport", "clock", "state" },

  -- Not critical. A server whose reconcile has died still records heartbeats and
  -- still answers devices that ask, so the fleet converges - just less promptly.
  -- Marking it critical would take a whole machine down over a latency problem,
  -- which is the opposite of what §8's health model is for.
  critical = false,

  run = function(context)
    while true do
      reconcile.pass(context, context.clock.now())
      context.clock.sleep(1)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return reconcile
