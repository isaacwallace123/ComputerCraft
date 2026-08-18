--- Transport port over rednet.
---
--- Opening the modem is the caller's job, not this adapter's. A machine may have
--- no modem at all and must still boot, so discovering that is a setup concern
--- with a message a person can act on; a transport that silently opened whatever
--- it found would hide a missing modem until the first turtle went out of range
--- and nobody could work out why.

local transport = require("ports.transport")

local adapter = {}

function adapter.new()
  local impl = {}

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

  return transport.check(impl)
end

return adapter
