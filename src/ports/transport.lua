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
  "host", -- (name, protocol) -> ok, error: be findable under a name
  "open", -- () -> ok, error: make the radio usable at all
}

function transport.check(impl)
  return contract.check(transport.NAME, transport.METHODS, impl)
end

--- `open` exists because nothing was doing it.
---
--- `adapters/cc/transport.lua` declined to open a modem on construction, for a
--- good reason it still gives: a machine with no modem must boot anyway, and an
--- adapter that silently opened whatever it found would hide a missing modem
--- until the first turtle went out of range. The decision was right and the
--- follow-through never happened - **no caller opened one either**, so on real
--- hardware every send returned false, every receive timed out, and an ICOS 2
--- server would have sat there looking perfectly healthy with a dead radio.
---
--- So it is an explicit method, called once by the composition root, whose
--- result is a value somebody can print. A machine with no modem still boots;
--- the difference is that it now says so.
---
--- Idempotent by contract. A supervisor restarts services, and a service that
--- had to know whether the radio was already open would be a service holding
--- state that belongs to the radio.

--- `host` is the one thing here that is not a message.
---
--- It was missing, and the omission had teeth. ICOS 1 devices find the base by
--- rednet hostname - a Pocket controller sends every authoritative request to
--- `net.findBase()`, and a miner announces itself when it first sees one. With
--- no way to express "be findable under a name", an ICOS 2 server could receive
--- a broadcast heartbeat but could never be *addressed*, so an unupgraded
--- handheld would report "base station is offline" and do nothing at all.
---
--- Deliberately no `lookup` beside it. ICOS 2 clients broadcast and take
--- whatever answers (`os/client/main.lua`), which is a decision recorded there
--- and not one to quietly reopen by adding the method that would let somebody
--- depend on a name instead. This exists to keep a promise to the *old*
--- protocol, and that is the whole of its remit.

--- A radio with nobody on the other end: sends vanish, receives time out,
--- hosting succeeds and means nothing. This is the honest default for a machine
--- with no modem, and it is also the state every turtle must keep working in.
function transport.null()
  return contract.null(transport.METHODS, { send = false, id = 0, host = true, open = false })
end

return transport
