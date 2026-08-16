--- Rednet wrapper: one protocol, one envelope shape, one place that knows how
--- to find a modem.
---
--- Everything is best-effort. A turtle 60 blocks down a hole will lose contact
--- with a plain wireless modem constantly, so no call here ever blocks a job or
--- throws when the network is unreachable - `send` just returns false and the
--- caller carries on mining. Ender modems have unlimited range and are what you
--- actually want for this.

local net = {}

net.PROTOCOL = "ccfleet"
net.HOSTNAME = "base"

local modemName = nil
local isWireless = false

--- Prefer a wireless modem; fall back to wired so a bench setup still works.
local function findModem()
  local wired = nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem and modem.isWireless() then
        return name, true
      end
      wired = wired or name
    end
  end
  return wired, false
end

--- Returns true if rednet is usable. Safe to call repeatedly.
function net.open()
  if modemName and rednet.isOpen(modemName) then
    return true
  end

  local name, wireless = findModem()
  if not name then
    modemName = nil
    return false, "no modem attached"
  end

  rednet.open(name)
  modemName, isWireless = name, wireless
  return true
end

function net.isOpen()
  return modemName ~= nil and rednet.isOpen(modemName)
end

function net.isWireless()
  return isWireless
end

--- Announce this computer as the fleet base so turtles can find it by name
--- instead of you hardcoding an ID anywhere.
function net.hostAsBase()
  if not net.open() then
    return false
  end
  rednet.host(net.PROTOCOL, net.HOSTNAME)
  return true
end

function net.unhostBase()
  pcall(rednet.unhost, net.PROTOCOL)
end

--- Look up the base station's computer ID. Returns nil if it is not reachable,
--- which is a normal condition, not an error.
function net.findBase()
  if not net.open() then
    return nil
  end
  return rednet.lookup(net.PROTOCOL, net.HOSTNAME)
end

local function envelope(kind, body)
  return { kind = kind, body = body, at = os.epoch("utc") }
end

function net.send(id, kind, body)
  if not id or not net.open() then
    return false
  end
  return rednet.send(id, envelope(kind, body), net.PROTOCOL)
end

function net.broadcast(kind, body)
  if not net.open() then
    return false
  end
  rednet.broadcast(envelope(kind, body), net.PROTOCOL)
  return true
end

--- Receive one message. Returns senderId, kind, body - or nil on timeout.
--- Malformed messages are dropped rather than crashing the listener.
function net.receive(timeout)
  if not net.open() then
    sleep(timeout or 1)
    return nil
  end

  local sender, message = rednet.receive(net.PROTOCOL, timeout)
  if not sender or type(message) ~= "table" or type(message.kind) ~= "string" then
    return nil
  end
  return sender, message.kind, message.body
end

return net
