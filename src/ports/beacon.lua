--- Port: answering the constellation.
---
--- The other half of `locator.gps`. A machine that asks where it is needs four
--- hosts in range that answer, and this is what a server uses to be one of them.
---
--- ## Why this is not the transport port
---
--- `transport` is rednet-shaped: it addresses computers by id and carries
--- tables. GPS is neither. It is a raw modem exchange on a fixed channel where
--- the *distance* the modem reports is the payload that matters - the position
--- in the reply is only useful in combination with how far away the sender
--- measured it to be. Trilateration is the protocol; the message is almost
--- incidental.
---
--- Folding that into `transport` would mean widening it with a channel concept
--- that exactly one caller needs, and every null adapter and every spec would
--- carry it. A second narrow port costs less than a wider general one.
---
--- ## The wire protocol is CC's, not ours
---
--- Verified against `rom/programs/gps.lua` and `rom/apis/gps.lua` at tag
--- `v1.20.1-1.113.1`: a client transmits the string `PING` on channel 65534 with
--- its own reply channel, and a host answers on that reply channel with a
--- three-element array of numbers. Anything else is not GPS, and a server that
--- got it subtly wrong would take the whole fleet's navigation with it - so the
--- adapter reimplements nothing it can avoid and the shape is pinned here.

local contract = require("ports.contract")

local beacon = {}

beacon.NAME = "beacon"

--- CC's GPS channel. Fixed by the mod, not by us.
beacon.CHANNEL = 65534

--- The string a client sends.
beacon.PING = "PING"

beacon.METHODS = {
  "open", -- () -> ok, error   start listening; safe to call twice
  "answer", -- (position, timeoutSeconds) -> answered:boolean
  "close", -- () -> nil
}

function beacon.check(impl)
  return contract.check(beacon.NAME, beacon.METHODS, impl)
end

--- A machine with no radio, which answers nobody and says so.
---
--- `open` returning false rather than erroring is deliberate: a server with no
--- wireless modem is a perfectly good server that simply cannot host GPS, and
--- the service that finds this out should report it and stand down rather than
--- take the machine with it.
function beacon.null()
  return contract.null(beacon.METHODS, {
    open = false,
    answer = false,
  })
end

return beacon
