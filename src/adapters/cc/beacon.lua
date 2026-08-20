--- Beacon port over a wireless modem.
---
--- What `rom/programs/gps.lua host` does, minus the printing and minus the
--- infinite loop - because a service that never returns cannot be supervised,
--- and a program that prints cannot run on a machine whose screen belongs to
--- something else.
---
--- ## Wireless only, and that is not a preference
---
--- A wired modem reports no distance, and distance is the entire payload of a
--- GPS reply: a client trilaterates from four hosts' distances, so a host that
--- cannot be measured is a host that makes every fix worse. CC's own program
--- refuses for the same reason.
---
--- ## `peripheral.find` rather than a remembered name
---
--- Looked up at `open` rather than cached at construction, so a modem attached
--- after boot starts working without a reboot. A base station that has to be
--- restarted to notice a modem somebody just placed is a base station that gets
--- restarted during an outage, which is the worst possible moment.

local beacon = require("ports.beacon")

local adapter = {}

function adapter.new()
  local modem = nil

  local function wireless()
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.hasType(name, "modem") then
        local found = peripheral.wrap(name)
        if found and found.isWireless() then
          return found, name
        end
      end
    end
    return nil
  end

  local impl = {}

  --- Start listening. False means there is no wireless modem, which is a fact
  --- about the machine rather than a fault: the service reports it and stands
  --- down, and everything else on the server carries on.
  function impl.open()
    local found, name = wireless()
    if not found then
      return false, "no wireless modem"
    end
    modem = found
    modem.open(beacon.CHANNEL)
    return true, name
  end

  --- Answer at most one ping, waiting up to `timeoutSeconds`.
  ---
  --- One rather than all, so the caller keeps control: a host under heavy
  --- traffic that answered every queued ping before returning would hold the
  --- coroutine for as long as the fleet kept asking, and on a base station that
  --- means the screen stops.
  ---
  --- `nDistance` being present is what proves the message arrived over the air.
  --- A wired modem delivers the same message with no distance, and answering it
  --- would put a host into the constellation that no client can trilaterate
  --- against - a fix that is confidently wrong rather than absent.
  function impl.answer(position, timeoutSeconds)
    if modem == nil or type(position) ~= "table" then
      -- Burn the timeout rather than returning at once, for the reason the
      -- transport adapter does: a caller polling in a loop would otherwise spin
      -- at full speed and starve every other coroutine on the machine.
      sleep(timeoutSeconds or 0)
      return false
    end

    local timer = os.startTimer(timeoutSeconds or 2)
    while true do
      local event, side, channel, reply, message, distance = os.pullEvent()
      if event == "modem_message" then
        if
          channel == beacon.CHANNEL
          and message == beacon.PING
          and distance ~= nil
          and side ~= nil
        then
          modem.transmit(reply, beacon.CHANNEL, { position.x, position.y, position.z })
          os.cancelTimer(timer)
          return true
        end
      elseif event == "timer" and side == timer then
        return false
      end
    end
  end

  function impl.close()
    if modem then
      modem.close(beacon.CHANNEL)
      modem = nil
    end
  end

  return beacon.check(impl)
end

return adapter
