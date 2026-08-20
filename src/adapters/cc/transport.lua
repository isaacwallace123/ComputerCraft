--- Transport port over rednet.
---
--- Opening the modem is the caller's job, not this adapter's. A machine may have
--- no modem at all and must still boot, so discovering that is a setup concern
--- with a message a person can act on; a transport that silently opened whatever
--- it found would hide a missing modem until the first turtle went out of range
--- and nobody could work out why.
---
--- That is still the rule, and for a while it was only half of one: **nothing
--- called `open` either.** Constructing this adapter and never opening a modem
--- gives a radio where every send returns false and every receive times out, on
--- a server that reports itself perfectly healthy - which is the failure the
--- paragraph above was written to avoid, arrived at from the other side. The
--- method is now on the port and `os/kernel/boot.lua` calls it, so the decision
--- stays with the composition root and the outcome is a value somebody can see.

local transport = require("ports.transport")

local adapter = {}

--- Prefer a wireless modem; fall back to wired so a bench setup still works.
---
--- The same search `legacy/net.lua` does, and the same reason for `hasType`
--- rather than comparing `getType`: a peripheral can advertise several types,
--- and an Ender Pocket upgrade is a modem whose first reported type is not
--- "modem". Comparing the first one silently disables the radio on exactly the
--- hardware this fleet is recommended to use.
local function findModem()
  local wired = nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then
      local modem = peripheral.wrap(name)
      if modem and modem.isWireless() then
        return name, true
      end
      wired = wired or name
    end
  end
  return wired, false
end

function adapter.new()
  local impl = {}

  --- Make the radio usable. Safe to call repeatedly.
  ---
  --- Returns `false, reason` rather than raising, because a machine with no
  --- modem is a machine that must still boot - a turtle with no radio keeps
  --- mining, which is D004 stated as hardware.
  function impl.open()
    if rednet.isOpen() then
      return true
    end
    local name = findModem()
    if not name then
      return false, "no modem attached"
    end
    rednet.open(name)
    return true
  end

  --- True means the message reached the radio, not that anybody heard it.
  ---
  --- D004: a wireless turtle leaves range as a matter of course, so this return
  --- value is never a delivery guarantee and no caller may treat it as one.
  function impl.send(id, message, protocol)
    if not rednet.isOpen() then
      return false
    end
    return rednet.send(id, message, protocol)
  end

  function impl.broadcast(message, protocol)
    if not rednet.isOpen() then
      return
    end
    rednet.broadcast(message, protocol)
  end

  --- Returns nothing when the timeout expires. Silence is an ordinary outcome
  --- here and callers must not log it as a fault; the fleet spends most of its
  --- time with most turtles unreachable.
  function impl.receive(protocol, timeoutSeconds)
    if not rednet.isOpen() then
      -- Still burn the timeout. A caller polling in a loop would otherwise spin
      -- at full speed on a machine with no modem and starve every other
      -- coroutine on it, which on a base station means the desktop stops.
      sleep(timeoutSeconds or 0)
      return nil
    end
    return rednet.receive(protocol, timeoutSeconds)
  end

  function impl.id()
    return os.getComputerID()
  end

  --- Announce this computer under `name` so it can be addressed by it.
  ---
  --- Unhosts first, and both calls are wrapped. `rednet.host` throws when the
  --- same protocol is hosted twice, which happens after a modem is detached and
  --- reattached while the Lua process survives - the hostname registration
  --- outlives the peripheral connection. `legacy/net.lua` learned that the hard
  --- way; re-registering from a known state turns it into a no-op and leaves a
  --- genuine name conflict as an ordinary returned failure.
  ---
  --- A service may be restarted by the supervisor, so this has to be safe to
  --- call again. It is.
  function impl.host(name, protocol)
    -- Opened here rather than assumed, because this is the first thing the
    -- bridge does and it is where a machine that booted without a modem gets
    -- stuck. It asserts on the result, so a closed radio killed the service
    -- outright - and the service is what turtles talk to. A modem plugged in
    -- afterwards then did nothing at all until somebody rebooted the base,
    -- which from the outside looks exactly like a fleet that has gone quiet.
    --
    -- `open` is idempotent and answers false rather than raising, so this costs
    -- one boolean on the path where the radio is already up.
    if not rednet.isOpen() then
      impl.open()
    end

    if not rednet.isOpen() then
      return false, "no modem is open"
    end
    pcall(rednet.unhost, protocol)
    local hosted, hostError = pcall(rednet.host, protocol, name)
    if not hosted then
      return false, tostring(hostError)
    end
    return true
  end

  return transport.check(impl)
end

return adapter
