--- How a page asks for something to change.
---
--- Every interactive app in ICOS has the same shape: draw what the server
--- knows, and when somebody presses a button, ask the server to want something
--- different. Until this file each of them did the second half by calling
--- `transport.broadcast` directly, and **on the server itself that does
--- nothing.**
---
--- ## The bug this exists to fix
---
--- Rednet does not loop back. `rednet.broadcast` puts a message on the modem and
--- the sending computer never receives it, which is correct behaviour and is
--- exactly wrong for a base station: §2 says a server with a monitor is a server
--- *and* a client, so the Fleet page on the base is drawing state it owns and
--- sending its Deploy button into the air, addressed to itself, to be heard by
--- nobody.
---
--- The symptom is precise and was reported exactly this way: the same buttons
--- work from another computer and do nothing on the base. Nothing errors,
--- nothing logs, and the page has no way to tell - a broadcast that reached no
--- listener looks identical to one that reached ten.
---
--- ## One function, two implementations
---
--- A page calls `context.request(message)` and does not know which machine it is
--- on. A client sends over the radio; a server hands the message to its own
--- handlers, which is the same code path a radio message would have taken and
--- therefore the same rules, the same refusals and the same persistence.
---
--- That is the whole trick, and it is worth stating why it is safe: the server's
--- request handlers already take `(context, sender, message)` and already have
--- to cope with a sender they have never met. Delivering locally is not a
--- shortcut past them, it is a shorter route to them.
---
--- ## The reply is optional
---
--- A local delivery can return what the handlers said; a broadcast cannot,
--- because the answer arrives seconds later on a loop this function does not
--- own. So the contract is deliberately weak: truthy means "asked", and a table
--- means "asked, and here is what came back immediately". A page that needed the
--- answer to draw would be a page that blocks on a radio round trip, which is
--- the thing §2 forbids.

local wire = require("domain.protocol.message")

local request = {}

--- Ask over the radio. What a client, a handheld or a turtle does.
---
--- Stamped here rather than by each caller, because the version field is the
--- thing that makes a rolling update safe and "the app forgot to stamp it" is a
--- failure with no error message.
function request.remote(transport, protocol)
  return function(message)
    if transport == nil or type(message) ~= "table" then
      return false
    end
    transport.broadcast(wire.stamp(message), protocol or wire.NAME)
    -- True means "handed to the radio", never "delivered". `ports/transport.lua`
    -- is explicit that no caller may read a send result as a delivery
    -- guarantee, and this one does not.
    return true
  end
end

--- Ask this machine's own handlers. What a server does.
---
--- `dispatch` is passed in rather than required, because the module that owns
--- the inbox is `os/server/services/discovery.lua` and a kernel file that
--- required a server service would be pointing the wrong way. The composition
--- root closes it, which is the same move it makes for `toCommand`.
---
--- The sender is the machine's own id. Not a special value: a handler that
--- treated "from myself" differently would be a handler with a second code path
--- that only ever runs on a base with a monitor - which is the least tested
--- machine in the fleet and the one this is for.
function request.loopback(context, dispatch, id)
  return function(message)
    if type(message) ~= "table" then
      return false
    end
    return dispatch(context, id, wire.stamp(message))
  end
end

--- The sender a page should use, whatever it is running on.
---
--- Falls back to a plain broadcast when the context has no `request`, which is
--- every spec that builds a context by hand and every machine on a build older
--- than this file. A page that had to know the difference would be a page with a
--- branch in it for the benefit of its own tests.
function request.of(context, protocol)
  if type(context) ~= "table" then
    return function()
      return false
    end
  end
  if type(context.request) == "function" then
    return context.request
  end
  return request.remote(context.transport, protocol)
end

return request
