--- Fleet automation policy editor. Works locally on the base and remotely from
--- a subscribed Pocket controller.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local log = require("core.log")
local control = require("fleet.control")
local policyStore = require("fleet.policy")

local function on(value)
  return value and "ON" or "off"
end

while true do
  local policy = policyStore.load()
  local labels = {
    "Auto-recovery master  " .. on(policy.enabled),
    "Fuel stop: resume     " .. on(policy.resumeRefueled),
    "Full depot: retry     " .. on(policy.retryDepot),
    "Setup wait: recheck   " .. on(policy.retrySetup),
    "Update parked slowly  " .. on(policy.updateParked),
    "Network: poll status  " .. tostring(policy.refreshSeconds) .. "s",
    "Network: sync pocket  " .. tostring(policy.syncSeconds) .. "s",
    "Back to Home",
  }
  local choice = ui.menu("AUTO RECOVERY", labels, {
    "Handles routine fleet pauses.",
    "It never assigns a new job.",
  })
  if not choice or choice == #labels then
    break
  end

  local fields = {}
  if choice == 1 then
    fields.enabled = not policy.enabled
  elseif choice == 2 then
    fields.resumeRefueled = not policy.resumeRefueled
  elseif choice == 3 then
    fields.retryDepot = not policy.retryDepot
  elseif choice == 4 then
    fields.retrySetup = not policy.retrySetup
  elseif choice == 5 then
    fields.updateParked = not policy.updateParked
  elseif choice == 6 then
    fields.refreshSeconds = policy.refreshSeconds == 30 and 60
      or (policy.refreshSeconds == 60 and 120 or 30)
  elseif choice == 7 then
    fields.syncSeconds = policy.syncSeconds == 10 and 20 or (policy.syncSeconds == 20 and 30 or 10)
  end

  local ok, err = control.setPolicy(fields)
  if not ok then
    log.warn("automation: " .. tostring(err))
    ui.clear()
    ui.header("AUTO RECOVERY", "offline")
    ui.text(2, 3, ui.pad(err, select(1, ui.size()) - 3), ui.theme.warn)
    sleep(1)
  end
end

ui.clear()
