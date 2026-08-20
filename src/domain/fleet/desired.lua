--- Desired state: what a device *should* be doing, held by the server.
---
--- Phase 3 of docs/icos-2.md, and the most important change in the plan. It
--- answers §1's first failure: *"Recall does nothing when a turtle is out of
--- render distance — control is an event, and if nobody is listening it is
--- gone."*
---
--- ## The shape
---
---     record.desired  = { mode = "recall", generation = 41, job = ..., settings = ... }
---     record.observed = { mode = "mining", generation = 40, at = <server clock> }
---
--- Every heartbeat carries what the device is doing and the generation it has
--- applied. The reply carries what it should be doing. The device compares
--- generations and acts. Nothing is a message that can be missed; everything is
--- a fact that is eventually true.
---
--- ## The five properties, and where each one lives
---
--- These are §5's list, and each is a spec rather than a claim:
---
---   * **Survives an unloaded chunk.** Nothing here expires. A turtle that comes
---     back in twenty minutes reconciles then.
---   * **Idempotent.** `apply` on a generation already applied returns nil.
---     Duplicate delivery is not merely tolerated, it is indistinguishable.
---   * **Monotonic.** `want` never lowers a generation and `apply` refuses one
---     older than it holds, so a reply that overtook a newer order cannot undo
---     it. Rednet does not promise ordering; this is what makes that survivable.
---   * **Survives a server restart**, because it is a persisted record rather
---     than something in flight.
---   * **Honest.** `status` says converged, pending or unreachable, never "sent".
---     Pending with a stale heartbeat is exactly the information that was
---     missing when three miners went quiet.
---
--- ## The autonomy invariant is unchanged
---
--- D004 says job correctness may never depend on a message arriving. Desired
--- state is a **goal, not a permission**: a device that cannot reach the server
--- keeps doing what it was last told, and `apply` returning nil means "carry on"
--- rather than "stop". Losing the server must never strand a turtle underground,
--- and no function here can produce that outcome because none of them can be
--- called at all without a reply having arrived.
---
--- ## Pure, with the clock injected
---
--- Same rule as `domain/fleet/registry.lua` and for the same reason. `now` is a
--- parameter; persistence belongs to the caller.

local desired = {}

--- What a device can be told to be doing.
---
--- Deliberately a small closed set. These are *states to be in*, not actions to
--- perform, which is what makes them reconcilable: "recall" is a thing a turtle
--- can still be doing twenty minutes later, whereas "go home now" is an
--- instruction that either landed or did not.
desired.MODES = {
  park = true,
  deploy = true,
  recall = true,
  update = true,
  stop = true,
}

--- Fields that ride alongside the mode.
---
--- §5: this "also removes the current three-message set-job / configure / deploy
--- dance". A job change and a deployment are one goal, so they are one record
--- with one generation - which means they cannot half-arrive, and a turtle can
--- never end up deployed on the job it had before.
local CARRIED = { job = true, settings = true, reason = true }

local function goalOf(record)
  return record.desired
end

--- Do two goals mean the same thing?
---
--- Compared field by field rather than by identity, because the caller builds a
--- fresh table every time it asks for something. Without this, a policy loop
--- that re-asserts "park" every thirty seconds would bump the generation every
--- thirty seconds, and every device would re-apply an order it was already
--- obeying - which is the event model wearing a new hat.
local function same(a, b)
  if a == nil or b == nil then
    return a == b
  end
  if a.mode ~= b.mode then
    return false
  end
  for field in pairs(CARRIED) do
    local left, right = a[field], b[field]
    if type(left) == "table" or type(right) == "table" then
      if type(left) ~= "table" or type(right) ~= "table" then
        return false
      end
      for key, value in pairs(left) do
        if right[key] ~= value then
          return false
        end
      end
      for key, value in pairs(right) do
        if left[key] ~= value then
          return false
        end
      end
    elseif left ~= right then
      return false
    end
  end
  return true
end

--- Set what a device should be doing. Returns the goal and whether it changed.
---
--- The generation only moves when the goal actually differs. That is what makes
--- this safe to call from a policy loop on every pass, which is how it will
--- actually be used.
function desired.want(record, mode, options, now)
  if not desired.MODES[mode] then
    error("desired: no such mode: " .. tostring(mode), 2)
  end

  local goal = { mode = mode, generation = 0 }
  for field in pairs(CARRIED) do
    if options and options[field] ~= nil then
      goal[field] = options[field]
    end
  end

  local current = goalOf(record)
  if same(current, goal) then
    return current, false
  end

  -- Monotonic. The generation is the only thing a device uses to decide whether
  -- an order is new, so it may never repeat or go backwards - including across a
  -- server restart, which is why it counts up from whatever was persisted rather
  -- than from zero.
  goal.generation = (current and current.generation or 0) + 1
  goal.at = now
  record.desired = goal
  return goal, true
end

--- What to send a device that has just checked in.
---
--- `epoch` names the run of numbering this generation was minted under. It is
--- stamped here rather than in `want` because it identifies the *server* rather
--- than the goal, and every reply in the system leaves through this function.
--- Omitting it is allowed and means "unstamped", which is how an older server
--- behaves and is treated as its own run.
function desired.reply(record, epoch)
  local goal = goalOf(record)
  if goal ~= nil and epoch ~= nil then
    goal.epoch = epoch
  end
  return goal
end

--- Record what a device reports it is doing and has applied.
---
--- `report.generation` is the generation the *device* has applied, not the one
--- the server wants. The gap between the two is the whole status model.
function desired.observe(record, report, now)
  record.observed = {
    mode = report and report.mode or nil,
    generation = tonumber(report and report.generation) or 0,
    epoch = report and report.epoch or nil,
    at = now,
  }
  return record.observed
end

--- Has the device applied what it was last told?
function desired.converged(record)
  local goal = goalOf(record)
  if goal == nil then
    return true
  end
  local observed = record.observed
  if observed == nil then
    return false
  end

  -- A device still answering under an older run of numbering has not applied
  -- this goal, whatever its number says. Comparing across runs is what let a
  -- turtle holding generation 6 read as converged against a goal of 3 - the
  -- dashboard's half of the same fault `apply` fixes below.
  if goal.epoch ~= nil and observed.epoch ~= goal.epoch then
    return false
  end

  return (observed.generation or 0) >= goal.generation
end

--- `converged`, `pending`, or `unreachable`.
---
--- §5: *"The dashboard shows converged / pending / unreachable instead of
--- 'sent'."* The distinction that matters is the third one - an order that has
--- not been applied by a device that is also not talking is a different
--- situation from one still in flight, and showing both as "sent" is what made
--- three missing turtles look like three busy ones.
---
--- `silentFor` is how long a device may be quiet before pending becomes
--- unreachable. It is the caller's threshold rather than this module's, because
--- a turtle at the bottom of a shaft and a base station on the same desk have
--- very different ideas of normal.
function desired.status(record, now, silentFor)
  if desired.converged(record) then
    return "converged"
  end
  local observed = record.observed
  local since = observed and observed.at
  if since == nil then
    return "unreachable"
  end
  if (now - since) / 1000 > (silentFor or 60) then
    return "unreachable"
  end
  return "pending"
end

---------------------------------------------------------------------------
-- The device side
---------------------------------------------------------------------------

--- Decide whether an incoming goal is news.
---
--- Returns the goal to apply, or nil to carry on unchanged. Nil is the common
--- answer and the safe one: it covers a duplicate delivery, a reply that
--- overtook a newer one, a malformed message, and no reply at all. **In every
--- one of those cases the device keeps doing what it was already doing**, which
--- is D004 expressed as a return value.
---
--- `applied` is the generation this device has already acted on, which it
--- persists. A rebooted turtle reads it back and therefore does not re-apply an
--- order it had already carried out - a recall that re-ran on every boot would
--- be a turtle that could never be redeployed.
--- What a device remembers having applied: a number, and the run it belongs to.
---
--- A bare number is accepted and means "no run recorded", which is what every
--- device held before epochs existed and what a device that has only ever heard
--- ICOS 1 commands holds today.
local function appliedOf(applied)
  if type(applied) == "table" then
    return tonumber(applied.applied) or 0, applied.epoch
  end
  return tonumber(applied) or 0, nil
end

function desired.apply(applied, incoming)
  if type(incoming) ~= "table" then
    return nil
  end
  local generation = tonumber(incoming.generation)
  if generation == nil or not desired.MODES[incoming.mode] then
    return nil
  end

  local held, epoch = appliedOf(applied)

  -- Monotonic *within* a run of numbering, and only within one.
  --
  -- Generations count up from whatever a record holds, so they mean nothing
  -- except relative to the state file holding them. Lose that file - a fresh
  -- install, a pruned record, a rebuilt server - and the count restarts at 1
  -- while every turtle in the world still remembers the number it last applied.
  -- Comparing the two numbers then discards every order the new server sends,
  -- permanently, and nothing on either side looks wrong: the fleet is present
  -- on the dashboard, reporting healthy, and deaf. That is exactly how four
  -- turtles came to ignore recall.
  --
  -- So a number is only comparable against one minted under the same run. A
  -- different epoch is a different authority, and its count is taken as given.
  if epoch == incoming.epoch and generation <= held then
    return nil
  end

  return {
    mode = incoming.mode,
    generation = generation,
    epoch = incoming.epoch,
    job = incoming.job,
    settings = incoming.settings,
    reason = incoming.reason,
  }
end

--- What a device puts in its heartbeat so the server can tell whether it has
--- caught up.
function desired.report(applied, mode)
  local generation, epoch = appliedOf(applied)
  return { generation = generation, epoch = epoch, mode = mode }
end

return desired
