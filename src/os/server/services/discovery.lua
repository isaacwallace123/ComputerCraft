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
local service = require("os.kernel.service")
local wire = require("domain.protocol.message")

local discovery = {}

--- The protocol name devices talk on.
---
--- Kept as a constant rather than inlined so the miner and the server cannot
--- drift apart by a typo, which is a failure mode with no error message: both
--- sides work perfectly and never hear each other. It was then inlined in six
--- other files anyway, which is how that failure was going to arrive; the
--- literal now lives once, in `domain/protocol/message.lua`, and this is an
--- alias so existing callers read the same as they did.
discovery.PROTOCOL = wire.NAME

--- Message kinds this service answers.
discovery.HELLO = "hello"
discovery.STATUS = "status"

--- A client asking for a copy of the registry.
---
--- Answered here rather than by a service of its own, because this service
--- already owns both the registry and the radio, and "tell me what you know"
--- is not a different job from "here is what I know".
---
--- A request-reply rather than a subscription. A subscription means the server
--- keeping a list of who is listening, and a list of listeners on machines that
--- reboot is a list that goes stale and gets written to forever.
discovery.MIRROR = "mirror"

--- A device saying it is going down on purpose.
---
--- Best-effort, like everything else on this radio: a machine that is unplugged
--- sends nothing and is reported offline, which is the honest answer for a
--- machine nobody switched off. What this buys is the *planned* case - a device
--- powered down for maintenance stops looking like one that fell in lava, so
--- the dashboard stops raising the same alarm for both.
discovery.FAREWELL = "farewell"

--- A client asking the server to want something of a device.
---
--- The only way an app changes anything. An app never sends an order to a
--- device: it asks the server to set a goal, and `reconcile` carries it. So a
--- button press dropped by a radio is retried by machinery that already exists,
--- and closing the page changes nothing about what the fleet is doing (D018).
---
--- There is no authentication, and there cannot be - CC has no notion of one
--- computer proving who it is, and a shared secret in a file every device holds
--- is a secret. This is the same exposure ICOS 1 has today with `command`, and
--- it is bounded the same way: the modem is in a base nobody else can reach.
--- Worth stating rather than leaving as an assumption somebody discovers.
discovery.WANT = "want"

--- Record one heartbeat and work out the reply.
---
--- Returns the reply table, or nil when the message is not ours. Nil rather than
--- an empty table, so a caller can tell "nothing to say" from "say nothing" -
--- the first is a message for somebody else and the second would be a bug.
function discovery.handle(context, sender, message)
  if type(message) ~= "table" then
    return nil
  end
  if message.kind == discovery.WANT then
    return discovery.want(context, message)
  end

  if message.kind == discovery.FAREWELL then
    if registry.depart(context.state.fleet, sender, context.clock.now()) then
      persist.mark(context, "fleet")
    end
    -- No reply. The device is already powering down and has nothing left to do
    -- with an answer; sending one would be a message into a machine that is
    -- gone, which is how a server ends up with a queue of undeliverable replies.
    return nil
  end

  if message.kind == discovery.MIRROR then
    -- The whole registry, not a diff. Ten devices is a small table and a diff
    -- would need the client and the server to agree about what the client
    -- already has - which is a second piece of state to get wrong, on the side
    -- of the system that is allowed to be wrong about everything else.
    return { kind = discovery.MIRROR, fleet = context.state.fleet, now = context.clock.now() }
  end

  if message.kind ~= discovery.HELLO and message.kind ~= discovery.STATUS then
    return nil
  end

  local now = context.clock.now()
  local snapshot = message.snapshot

  local record = registry.observe(context.state.fleet, sender, snapshot, now)

  -- Which build this device is running, kept beside the rest of what is known
  -- about it. During a rolling update "which devices are still on the old
  -- build" is the question being asked every few minutes, and reading it off
  -- the heartbeat is the only way to answer it that does not require the
  -- device to be reachable at the moment somebody asks.
  record.build = wire.buildOf(message) or record.build
  record.protocol = wire.versionOf(message)

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

--- Set a goal on behalf of a client.
---
--- Returns an acknowledgement, or a refusal that says why. Refusing loudly
--- rather than silently matters here more than anywhere else on the server: the
--- person who pressed the button is standing in front of a screen waiting to see
--- something happen, and a page that showed nothing would leave them pressing it
--- again.
---
--- A device the server has never heard of is refused rather than created. The
--- registry is built from heartbeats, and inventing an entry from a click would
--- put a device on the Devices page that does not exist - which is the one thing
--- a fleet dashboard must never do, because the whole point of §6 is telling
--- "there is no miner-7" from "we do not know where miner-7 is".
function discovery.want(context, message)
  local record = registry.get(context.state.fleet, message.id)
  if record == nil then
    return { kind = "want_result", ok = false, id = message.id, message = "no such device" }
  end
  if not desired.MODES[message.mode] then
    return {
      kind = "want_result",
      ok = false,
      id = message.id,
      message = "no such mode: " .. tostring(message.mode),
    }
  end

  local goal, changed = desired.want(record, message.mode, {
    job = message.job,
    settings = message.settings,
  }, context.clock.now())

  if changed then
    persist.mark(context, "fleet")
  end

  -- `changed = false` is still `ok`. Asking for a goal the device already has is
  -- not a failure, and reporting it as one would make a second click on Recall
  -- look like something went wrong when the correct answer is "it is already
  -- recalled".
  return {
    kind = "want_result",
    ok = true,
    id = message.id,
    generation = goal.generation,
    changed = changed,
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

--- The server's single inbox, and everything that wants to read from it.
---
--- Only one loop can call `transport.receive`, because receiving consumes: two
--- services polling the same protocol would each silently eat half the fleet's
--- traffic, and both would look perfectly healthy while doing it. So this
--- service owns the radio and every other one registers a handler.
---
--- Returns a list of replies rather than one, because a single message can
--- legitimately concern two services - a status heartbeat is a device report to
--- this service *and* a lease renewal to `leases`. Handlers that have nothing to
--- say return nil and contribute nothing.
---
--- The order is fixed: this service first, then `context.handlers` as given. A
--- handler therefore sees state this service has already updated, which is the
--- direction that makes sense - everything else on a server operates on facts
--- that arrived as a heartbeat.
function discovery.dispatch(context, sender, message)
  local replies = {}

  -- The one version gate on the server, here rather than in each handler. A
  -- handler that had to check would be a handler that could forget, and the
  -- answer does not vary by handler: whether a message is comprehensible is a
  -- property of the message.
  --
  -- `era` is deliberately not used to refuse anything. `NEWER` means a device
  -- updated ahead of this base, which the updater makes the normal case rather
  -- than the exception, and the compatibility rule in
  -- `domain/protocol/message.lua` is what makes reading it safe.
  local body = wire.accept(message)
  if body == nil then
    return replies
  end

  local reply = discovery.handle(context, sender, body)
  if reply then
    replies[#replies + 1] = reply
  end

  for _, handler in ipairs(context.handlers or {}) do
    local extra = handler(context, sender, body)
    if extra then
      replies[#replies + 1] = extra
    end
  end

  -- Stamped once, on the way out, rather than at each `return` inside a handler.
  -- Six handlers returning a table literal is six chances to forget a field
  -- whose absence means "pre-versioning build" - a wrong answer that looks like
  -- a right one.
  for _, out in ipairs(replies) do
    wire.stamp(out)
  end

  return replies
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
        for _, reply in ipairs(discovery.dispatch(context, sender, message)) do
          context.transport.send(sender, reply, discovery.PROTOCOL)
        end
      end
    end
  end,
})

return discovery
