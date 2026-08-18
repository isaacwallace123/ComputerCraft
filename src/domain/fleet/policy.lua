--- When an unattended fleet is allowed to fix itself, and when it must not.
---
--- The rules only, as a pure function of a device record and a settings table.
--- `os/server/services/policy.lua` is the loop that applies them.
---
--- ## The rule ICOS 1 stated and did not enforce
---
--- `fleet/policy.lua` opens by saying that an unattended system must be active
--- but "must not turn an intentional recall into an automatic redeploy". It
--- enforced that by having no rule that happened to match a recalled turtle,
--- which is not enforcement - it is an absence that any future rule can end by
--- accident.
---
--- Desired state lets it be structural instead. **Policy never contradicts a
--- standing goal.** It may act when a device has no goal at all, or when its
--- goal is already `deploy` and reality disagrees - which is exactly the case
--- "it is supposed to be working and it is not". A recalled turtle has a goal of
--- `recall`, so every rule here is unreachable for it, no matter what anybody
--- adds later.
---
--- That also fixes the thing that made the ICOS 1 version feel unsafe to leave
--- on: it sent a command and hoped. This sets a goal, and `reconcile` keeps
--- nudging until the device converges - so a recovery that is dropped by a
--- radio is retried, and one that succeeds is not re-sent.
---
--- ## Nothing here installs code or changes a job
---
--- The default set is routine recovery: a turtle that ran out of fuel and has
--- been refuelled, a depot that was full and may not be now, a setup check that
--- may since have been satisfied. Rolling updates stay opt-in, because an update
--- is the one action that can turn a working fleet into a broken one while
--- nobody is watching.

local policy = {}

--- The settings, and their defaults.
---
--- Recovery on, code changes off. Every default here answers "should the fleet
--- do this while nobody is looking?", and the three that are on are all
--- re-attempts of something that already failed for a reason that may have gone
--- away by itself.
policy.DEFAULTS = {
  enabled = true,
  resumeRefueled = true,
  retryDepot = true,
  retrySetup = true,
  updateParked = false,
}

--- Seconds before the same device may be acted on again.
---
--- Per rule, because the rules fail differently. A refuelled turtle either
--- starts moving or did not really have fuel, and thirty seconds is enough to
--- find out. A full depot needs time for somebody to empty it, and hammering it
--- every thirty seconds turns one problem into a log nobody can read.
policy.COOLDOWN = {
  fuel = 30,
  depot = 60,
  setup = 60,
  update = 300,
}

function policy.normalise(saved)
  local result = {}
  if type(saved) ~= "table" then
    saved = {}
  end
  for key, default in pairs(policy.DEFAULTS) do
    if saved[key] == nil then
      result[key] = default
    else
      result[key] = saved[key] == true
    end
  end
  return result
end

--- May policy touch this device at all?
---
--- The structural half of the safety rule. A device carrying a goal that is not
--- `deploy` is carrying somebody's decision, and policy is not entitled to
--- overrule it - so this returns false and no rule below is ever consulted.
---
--- No goal at all is allowed, because a device the server has never been told
--- anything about is not a device anybody has an opinion on.
function policy.mayAct(record)
  local goal = record.desired
  if goal == nil then
    return true
  end
  return goal.mode == "deploy"
end

--- Has the fuel that stopped this turtle come back?
---
--- `-1` means an unlimited-fuel world, where a fuel park is always spurious and
--- always safe to clear.
local function refuelled(snapshot)
  if snapshot.fuel == -1 then
    return true
  end
  local fuel = tonumber(snapshot.fuel)
  local required = tonumber(snapshot.fuelRequired)
  return fuel ~= nil and required ~= nil and fuel >= required
end

--- What, if anything, policy wants done about this device right now.
---
--- Returns `{ rule, mode, reason }` or nil. The rule name comes back so the
--- caller can pick the right cooldown and say something useful in the log
--- without re-deriving which branch fired.
---
--- Order matters where two rules could match: fuel first, because a turtle that
--- is out of fuel cannot carry out any of the others.
function policy.decide(record, options, version)
  if not options.enabled or not policy.mayAct(record) then
    return nil
  end

  local snapshot = record.snap
  if type(snapshot) ~= "table" or not snapshot.parked then
    return nil
  end

  if options.resumeRefueled and snapshot.parkKind == "fuel" and refuelled(snapshot) then
    return { rule = "fuel", mode = "deploy", reason = "fuel restored" }
  end

  -- A depot that was full when the turtle arrived may not be full now, because
  -- filling and emptying a chest is something a person does. This is the rule
  -- that most often turns a stopped fleet back into a running one.
  if
    options.retryDepot
    and snapshot.parkKind == "error"
    and tostring(snapshot.detail or ""):find("depot full", 1, true)
  then
    return { rule = "depot", mode = "deploy", reason = "retrying depot unload" }
  end

  if options.retrySetup and snapshot.parkKind == "setup" then
    return { rule = "setup", mode = "deploy", reason = "rechecking setup prerequisites" }
  end

  -- Opt-in, and last. An update is the one action here that can turn a working
  -- fleet into a broken one with nobody watching, so it is never a default and
  -- never applies to a turtle that is already parked because something went
  -- wrong - that turtle needs a person, not a new build.
  if
    options.updateParked
    and version
    and snapshot.version
    and snapshot.version ~= version
    and snapshot.parkKind ~= "updating"
    and snapshot.parkKind ~= "error"
  then
    return { rule = "update", mode = "update", reason = "rolling update" }
  end

  return nil
end

--- Is this device off cooldown for this rule?
---
--- Cooldowns are per device and per rule rather than global, so a turtle stuck
--- on a full depot cannot delay a different turtle's refuel resume. The one
--- deliberately global limit lives in the service, not here.
function policy.ready(attempts, id, rule, now)
  local key = tostring(id) .. ":" .. rule
  local until_ = attempts[key]
  return until_ == nil or now >= until_
end

function policy.wait(attempts, id, rule, now)
  local key = tostring(id) .. ":" .. rule
  attempts[key] = now + (policy.COOLDOWN[rule] or 60) * 1000
  return attempts
end

return policy
