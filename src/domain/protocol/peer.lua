--- Who to ask, so that asking does not wake the whole world.
---
--- ## Broadcasting is not free, and it is not free for you
---
--- `rednet.broadcast` puts a message on channel 65535, which **every computer
--- in range receives**. Each one wakes, resumes every service coroutine it has,
--- and each of those decides the message was not theirs.
---
--- Four turtles heartbeating every two seconds is two messages a second. On a
--- base with six machines that is twelve machine-wakeups a second, each
--- resuming ten-odd coroutines, to deliver two messages that one machine wanted.
---
--- The cost lands on a budget nobody owns alone. CC gives every computer in a
--- world a shared slice - `max_main_global_time`, ten milliseconds a tick by
--- default across all of them - so a turtle that shouts is spending the client's
--- time, and the client cannot do anything about it. Adding a machine makes
--- every other machine slower.
---
--- ## So shout once, then speak
---
--- A device does not know the server's id when it boots, so the first message
--- has to be a broadcast. The reply comes from somewhere, and that somewhere is
--- the answer: every message after it is sent to that id and wakes one computer.
---
--- If the replies stop, the address is forgotten and the next message is a
--- broadcast again. That is what makes this safe against the server being
--- rebuilt with a new id, moved, or replaced by a spare - none of which a device
--- can detect, and all of which are indistinguishable from silence.
---
--- ## Pure, and it has to be
---
--- No radio, no clock of its own (D041). Deciding who to address is a question
--- about what has been heard and when, which is answerable from those two
--- things - and that is what lets every branch below be a spec rather than a
--- fleet-wide experiment.

local peer = {}

--- How long a remembered address survives silence, in seconds.
---
--- Thirty. Long enough to ride out a server that is busy or a chunk that
--- unloaded for a moment, short enough that a base rebuilt with a new id is
--- found again before anybody has finished walking back to it.
---
--- Deliberately longer than a heartbeat and shorter than the sixty seconds that
--- makes a device count as offline: forgetting an address should happen before
--- the fleet gives up on the device, not after.
peer.FORGET = 30

function peer.empty()
  return { id = nil, at = nil }
end

--- Note that this peer answered.
---
--- Called with the sender of any reply, not only the one that was expected. A
--- machine that answers at all is a machine worth addressing, and being fussy
--- about which message proved it would mean a device that stays deaf because the
--- one kind of reply it was watching for never came.
function peer.remember(state, id, now)
  if type(state) ~= "table" or type(id) ~= "number" then
    return false
  end
  state.id = id
  state.at = now
  return true
end

--- The id to send to, or nil to broadcast.
---
--- Nil is not a failure - it is the honest answer before anybody has replied,
--- and again once a reply has stopped arriving. The caller broadcasts, which is
--- exactly what it did before this file existed and is now the exception rather
--- than the rule.
function peer.address(state, now)
  if type(state) ~= "table" or state.id == nil or state.at == nil then
    return nil
  end
  if now == nil then
    return state.id
  end
  if (now - state.at) / 1000 > peer.FORGET then
    return nil
  end
  return state.id
end

--- Give up on the remembered address.
---
--- Separate from expiry, for the one case expiry cannot cover: a send that the
--- radio itself refused. `transport.send` returning false means the id is not
--- reachable, which is a fact available immediately rather than in thirty
--- seconds, and waiting for the timeout would be thirty seconds of a device
--- talking to a computer that is not there.
function peer.forget(state)
  if type(state) ~= "table" then
    return false
  end
  state.id = nil
  state.at = nil
  return true
end

--- Send to the remembered peer if there is one, and broadcast if there is not.
---
--- The transport is passed in rather than required, because this file is in
--- `domain/` and may not touch a port (§3). Returns whether it went to one
--- machine, which is the only thing a caller could want to know.
function peer.send(state, transport, message, protocol, now)
  local id = peer.address(state, now)
  if id == nil then
    transport.broadcast(message, protocol)
    return false
  end

  if transport.send(id, message, protocol) then
    return true
  end

  -- The radio said no. Forget the address and shout, so a device whose server
  -- has gone is not silent for the length of the timeout.
  peer.forget(state)
  transport.broadcast(message, protocol)
  return false
end

return peer
