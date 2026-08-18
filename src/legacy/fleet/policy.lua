--- Persisted, conservative fleet automation policy.
---
--- Defaults automate routine recovery and observation. Actions which can change
--- a job or install code remain opt-in: an unattended system should be active,
--- but it must not turn an intentional recall into an automatic redeploy.

local config = require("adapters.cc.config")

local policy = {}

policy.PATH = ".fleet-policy"

local DEFAULTS = {
  enabled = true,
  resumeRefueled = true,
  retryDepot = true,
  retrySetup = true,
  updateParked = false,
  refreshSeconds = 30,
  syncSeconds = 10,
}

local function normalise(saved)
  saved.enabled = saved.enabled ~= false
  saved.resumeRefueled = saved.resumeRefueled ~= false
  saved.retryDepot = saved.retryDepot ~= false
  saved.retrySetup = saved.retrySetup ~= false
  saved.updateParked = saved.updateParked == true
  saved.refreshSeconds =
    math.max(10, math.min(300, math.floor(tonumber(saved.refreshSeconds) or 30)))
  saved.syncSeconds = math.max(5, math.min(60, math.floor(tonumber(saved.syncSeconds) or 10)))
  return saved
end

function policy.load()
  return normalise(config.load(policy.PATH, DEFAULTS))
end

function policy.save(value)
  value = normalise(value or {})
  config.save(policy.PATH, value)
  return value
end

function policy.update(fields)
  local saved = policy.load()
  for key, value in pairs(fields or {}) do
    if DEFAULTS[key] ~= nil then
      saved[key] = value
    end
  end
  return policy.save(saved)
end

return policy
