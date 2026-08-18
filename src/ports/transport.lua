--- Port: messages between computers.
---
--- Modelled on rednet and deliberately no richer than it. There is no request/
--- reply primitive, no acknowledgement, and no delivery guarantee, because
--- adding one here would let the domain quietly start depending on it - and the
--- whole fleet rests on D004: a wireless turtle leaves range, so job correctness
--- can never require that a message arrived.
---
--- `receive` takes a timeout and returns nothing when it expires. Callers treat
--- "no message" as an ordinary outcome, not an error.

local contract = require("ports.contract")

local transport = {}

transport.NAME = "transport"

transport.METHODS = {
  "send", -- (id, message, protocol) -> boolean delivered-to-the-radio
  "broadcast", -- (message, protocol) -> nil
  "receive", -- (protocol, timeoutSeconds) -> senderId, message, protocol | nil
  "id", -- () -> this computer's id, so a sender can name itself
}

function transport.check(impl)
  return contract.check(transport.NAME, transport.METHODS, impl)
end

--- A radio with nobody on the other end: sends vanish, receives time out. This
--- is the honest default for a machine with no modem, and it is also the state
--- every turtle must keep working in.
function transport.null()
  return contract.null(transport.METHODS, { send = false, id = 0 })
end

return transport
