--- The loop that applies the recovery rules, and the limits on it.
---
--- `domain/fleet/policy.lua` decides; this walks the registry, asks, and records
--- the answer as desired state. It writes no radio message of its own: setting a
--- goal is the whole action, and `reconcile` is what carries it to the device -
--- so a recovery dropped by a radio is retried by machinery that already exists
--- rather than by a second copy of it living here.
---
--- ## One update at a time, fleet-wide
---
--- Per-device cooldowns live in the domain module because they are a property of
--- the rule. This one limit is a property of the *fleet* and belongs here: a
--- rolling update that queues ten turtles at once is not rolling, it is a fleet
--- that all stops at the same moment. Everything else may act on every device in
--- the same pass, because refuelling one turtle does not make the next one's
--- recovery riskier.
---
--- ## Not critical
---
--- A fleet with no policy still mines - every rule here is a re-attempt of
--- something a person could do from the console. This is the clearest example of
--- `service.define`'s distinction between critical and important: losing this
--- costs convenience, losing `leases` costs a shaft.

local fleetRegistry = require("domain.fleet.registry")
local desired = require("domain.fleet.desired")
local persist = require("os.server.services.persist")
local policyRules = require("domain.fleet.policy")
local service = require("os.kernel.service")

local policy = {}

policy.PATH = ".policy2"

--- Seconds between passes.
---
--- Slow on purpose. Every rule here is a re-attempt of something that already
--- failed, and the failures it recovers from - a person emptying a chest,
--- somebody dropping fuel in a turtle - happen on human timescales. A tighter
--- loop would find nothing new and would fill the log deciding so.
policy.EVERY = 15

--- Settings, read through the storage port and defaulted when absent.
function policy.load(context)
  local text = context.storage.read(policy.PATH)
  if text == nil then
    return policyRules.normalise(nil)
  end
  local ok, saved = pcall(context.serialise.decode, text)
  return policyRules.normalise(ok and saved or nil)
end

function policy.save(context, settings)
  local normalised = policyRules.normalise(settings)
  context.storage.write(policy.PATH, context.serialise.encode(normalised))
  context.policy = normalised
  return normalised
end

--- The settings this server is running under, cached on the context.
---
--- Read once and kept, because a pass every fifteen seconds that re-read a file
--- every fifteen seconds would be a disk access to answer a question whose
--- answer only changes when a person changes it - and the person changing it
--- goes through `save`, which updates the cache.
function policy.settings(context)
  if context.policy == nil then
    context.policy = policy.load(context)
  end
  return context.policy
end

--- One pass over the fleet. Returns the actions taken.
---
--- Returned rather than logged, for the reason `discovery.isNew` is: a service
--- that wrote to a log would be deciding how a machine reports things, and on a
--- Pocket Computer that log is somewhere else entirely.
function policy.pass(context, now)
  local settings = policy.settings(context)
  local acted = {}
  if not settings.enabled then
    return acted
  end

  context.attempts = context.attempts or {}
  local updatedOne = false

  for _, record in ipairs(fleetRegistry.records(context.state.fleet)) do
    local id = record.id

    -- Only devices that are actually reporting. Not because an absent one
    -- cannot be told - desired state means the goal waits for it - but because
    -- the snapshot a decision is made from would be twenty minutes old, and
    -- "parked for fuel" twenty minutes ago is not evidence of anything now.
    local online = fleetRegistry.health(record, now) == "online"
    local decision = online and policyRules.decide(record, settings, context.version) or nil

    if decision and policyRules.ready(context.attempts, id, decision.rule, now) then
      -- The fleet-wide limit. Not a cooldown - a cooldown says "not this device
      -- again yet", and this says "not any device this pass".
      local blocked = decision.rule == "update" and updatedOne

      if not blocked then
        local _, changed = desired.want(record, decision.mode, { reason = decision.reason }, now)
        policyRules.wait(context.attempts, id, decision.rule, now)
        updatedOne = updatedOne or decision.rule == "update"

        -- `changed` is false when the device already had this goal, which is the
        -- normal case for a turtle that is slow to converge. Recording the
        -- attempt anyway is what stops the pass re-deciding every fifteen
        -- seconds; reporting only the changes is what keeps the log honest about
        -- what actually happened.
        if changed then
          acted[#acted + 1] = {
            id = id,
            rule = decision.rule,
            mode = decision.mode,
            reason = decision.reason,
          }
        end
      end
    end
  end

  if #acted > 0 then
    persist.mark(context, "fleet")
  end

  return acted
end

policy.service = service.define({
  id = "policy",
  requires = { "clock", "state", "storage", "serialise" },

  -- Not critical. A fleet with no policy still mines; it just needs a person to
  -- notice when a turtle has stopped for a reason that has since gone away.
  critical = false,

  run = function(context)
    while true do
      policy.pass(context, context.clock.now())
      context.clock.sleep(context.policyEvery or policy.EVERY)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return policy
