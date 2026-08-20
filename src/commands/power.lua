--- Shut this machine down, and tell the fleet it was on purpose.
---
--- §4's second category. `legacy/apps/power.lua` was a three-item menu wrapped
--- around `os.reboot` and `os.shutdown`, plus a shutdown animation - fifteen
--- lines of which fourteen were decoration.
---
--- ## What is actually new
---
--- It says goodbye first. §6's subject is telling *"we do not know where miner-7
--- is"* from *"there is no miner-7"*, and a planned shutdown was the case it was
--- missing: a turtle powered down for maintenance looked exactly like one that
--- fell in lava, because both simply stop reporting. The dashboard raised the
--- same alarm for both, which is how somebody learns to ignore the alarm.
---
--- ## Best-effort, and it has to be
---
--- The farewell is a broadcast into a radio that may not be open, to a base that
--- may not be listening, from a machine that is about to stop. None of that is
--- worth waiting on - a device somebody unplugs sends nothing at all and is
--- reported offline, which is the honest answer for a machine nobody switched
--- off. So this sends, pauses briefly so the message leaves before the computer
--- does, and powers down regardless.
---
--- ## Both protocols
---
--- The same reason `os/turtle/legacy.lua` exists: during a rolling update the
--- base listening might be an ICOS 1 base, and a goodbye it cannot hear is a
--- goodbye that did not happen.
---
---     power             ask
---     power reboot      restart now
---     power off         shut down now

package.path = "/?.lua;/?/init.lua;" .. package.path

local wire = require("domain.protocol.message")

--- Tell whoever is listening that this was deliberate.
local function farewell()
  if not rednet or not rednet.isOpen or not rednet.isOpen() then
    return false
  end

  rednet.broadcast(wire.stamp({ kind = "farewell" }), wire.NAME)
  rednet.broadcast(wire.wrap("farewell", {}, os.epoch("utc")), wire.LEGACY_NAME)

  -- Long enough for the modem to send, short enough that nobody notices. A
  -- shutdown that waited on an acknowledgement would hang whenever the base was
  -- down, which is one of the times somebody most wants to reboot a machine.
  sleep(0.2)
  return true
end

local action = (({ ... })[1] or ""):lower()

if action == "" then
  print("Power")
  print("")
  print("  1  restart")
  print("  2  shut down")
  print("  3  cancel")
  print("")
  write("Choose [1-3]: ")
  local answer = tonumber((read() or ""):match("%d"))
  if answer == 1 then
    action = "reboot"
  elseif answer == 2 then
    action = "off"
  else
    print("Cancelled.")
    return
  end
end

if action ~= "reboot" and action ~= "off" then
  printError("Unknown action: " .. action)
  print("Expected `reboot` or `off`.")
  return
end

if farewell() then
  print("Told the fleet.")
end

if action == "reboot" then
  print("Restarting...")
  os.reboot()
else
  print("Shutting down...")
  os.shutdown()
end
