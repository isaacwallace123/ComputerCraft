--- Running ICOS 2 by hand, without changing what this machine does on power-up.
---
--- `startup.lua` still boots ICOS 1. That is deliberate and it is the last thing
--- that will change: switching it over alters what a live fleet does when the
--- chunk loads, and it is the one change in this branch that cannot be tested
--- anywhere except in a world.
---
--- So this exists instead. Run `icos2` in a test world and the machine becomes
--- an ICOS 2 machine until you press Ctrl-T. Nothing is written that ICOS 1
--- reads, so rebooting puts it back exactly as it was.
---
---     icos2              boot the role in .node and run
---     icos2 server       force a role, for a machine that has not been set up
---     icos2 status       build the machine, print its health, and stop
---
--- ## Why `status` builds the machine rather than reading a file
---
--- Because the interesting failures are all in the wiring. "No wireless modem",
--- "no saved position", "this role has no operating system" are discovered when
--- the ports are constructed and the services are registered, and a status
--- command that read a file would report a healthy machine that cannot start.
--- Building it and stopping costs one tick.

package.path = "/?.lua;/?/init.lua;" .. package.path

local boot = require("os.boot")
local config = require("core.config")
local roles = require("os.roles")

local args = { ... }
local command = args[1]

local node = config.load(".node", {})

--- A forced role, if the first argument is one.
---
--- Checked against the role table rather than passed through, so a typo becomes
--- "unknown role: sever" here instead of "no operating system for role sever"
--- three frames later.
local forced = nil
for _, name in pairs(roles) do
  if type(name) == "string" and name == command then
    forced = name
  end
end

if command ~= nil and command ~= "status" and forced == nil then
  printError("unknown role: " .. tostring(command))
  print("expected one of: server, client, turtle, mobile - or `status`")
  return
end

local machine, why = boot.machine(node, { role = forced })
if machine == nil then
  printError(why)
  return
end

if command == "status" then
  -- One step, so every service has been resumed once and has had the chance to
  -- fail on something it needs. A status printed before that has only checked
  -- that the modules load.
  machine.supervisor:step()

  print("ICOS 2 - " .. machine.role)
  for _, row in ipairs(machine.supervisor:health()) do
    local mark = row.state == "running" and "  ok  " or (row.critical and " FAIL " or " warn ")
    local line = mark .. row.id
    if row.lastError then
      line = line .. " - " .. tostring(row.lastError)
    end
    print(line)
  end

  local healthy, reason = machine.supervisor:healthy()
  print(healthy and "healthy" or ("unhealthy: " .. tostring(reason)))
  machine.supervisor:stop()
  return
end

print("ICOS 2 - " .. machine.role .. " - hold Ctrl-T to stop")

local outcome, reason = boot.run(machine)

if outcome == "stopped" then
  printError("every service gave up: " .. tostring(reason))
  print("Run `icos2 status` to see which, or reboot for ICOS 1.")
elseif outcome == "halted" then
  print("Stopped on request.")
else
  print("ICOS 2 stopped.")
end
