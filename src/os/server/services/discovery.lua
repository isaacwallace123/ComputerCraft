--- The server's ear: heartbeats in, desired state out.
---
--- The service that finally connects the three domain modules built for phases 2
--- and 3. A device says what it is doing and which generation it has applied;
--- the server records it, retains its position, and replies with what it should
--- be doing. That exchange is the whole of the desired-state model.
---
--- ## The logic is a function, the loop is three lines
---
--- `handle` takes a context, a sender and a message and returns a reply. It
--- touches no radio and no clock of its own, so a spec drives it directly with a
--- table - which is why the end-to-end behaviour of the server is checkable
--- without a world.
---
--- `run` is the loop the supervisor resumes, and it is deliberately trivial.
--- Anything worth testing that lives inside a `while true` is something that
--- cannot be tested, so nothing worth testing lives there.
---
--- ## D004 is unchanged
---
--- The reply is best-effort. A device that never receives one keeps doing what
--- it was last told, and the order stays in the record waiting for the next time
--- it checks in - which is the point of §5 and the reason recall stops being a
--- message that can be missed.

local desired = require("domain.fleet.desired")
local persist = require("os.server.services.persist")
local registry = require("domain.fleet.registry")
local service = require("os.service")

local discovery = {}

--- The protocol name devices talk on.
---
--- Kept as a constant rather than inlined so the miner and the server cannot
--- drift apart by a typo, which is a failure mode with no error message: both
--- sides work perfectly and never hear each other.
discovery.PROTOCOL = "icos"

--- Message kinds this service answers.
discovery.HELLO = "hello"
discovery.STATUS = "status"

--- Record one heartbeat and work out the reply.
---
--- Returns the reply table, or nil when the message is not ours. Nil rather than
--- an empty table, so a caller can tell "nothing to say" from "say nothing" -
--- the first is a message for somebody else and the second would be a bug.
function discovery.handle(context, sender, message)
  if type(message) ~= "table" then
    return nil
  end
  if message.kind ~= discovery.HELLO and message.kind ~= discovery.STATUS then
    return nil
  end

  local now = context.clock.now()
  local snapshot = message.snapshot

  local record = registry.observe(context.state.fleet, sender, snapshot, now)

  -- What the device has applied, which is what decides whether it has caught up.
  -- Absent on a device running an older build: it reports generation 0 and is
  -- therefore always behind, which is the correct answer - it has applied
  -- nothing because it does not know how to.
  desired.observe(record, message.applied, now)

  -- Marked, not written. `persist` batches the registry because ten turtles at
  -- one heartbeat every two seconds is five disk writes a second, and a CC write
  -- is a real file operation on the host.
  persist.mark(context, "fleet")

  return {
    kind = "desired",
    desired = desired.reply(record),
    -- The server's own clock, so a device can tell how far its own has drifted
    -- without needing anything to agree about the past.
    now = now,
  }
end

--- A device that has just been seen for the first time, or has come back.
---
--- Returned separately from `handle` rather than logged inside it, because a
--- service that wrote to a log would be a service deciding how a machine reports
--- things - and on a Pocket Computer that log is somewhere else entirely.
function discovery.isNew(context, sender)
  return registry.get(context.state.fleet, sender) == nil
end

--- The manifest, attached rather than returned separately.
---
--- `require` hands back one value, so a module that returned the definition and
--- the logic as two would silently give every caller only the first. The service
--- is `discovery.service`; everything testable is beside it.
discovery.service = service.define({
  id = "discovery",
  requires = { "transport", "clock", "state" },

  -- Critical: a server that is not listening is not a server. Everything else it
  -- does - leases, policy, persistence - operates on state this service is the
  -- only source of.
  critical = true,

  run = function(context)
    while true do
      local sender, message, protocol =
        context.transport.receive(discovery.PROTOCOL, context.pollSeconds or 2)
      if sender ~= nil and protocol == discovery.PROTOCOL then
        local reply = discovery.handle(context, sender, message)
        if reply then
          context.transport.send(sender, reply, discovery.PROTOCOL)
        end
      end
    end
  end,
})

return discovery
