--- The translator that keeps an ICOS 1 fleet alive under an ICOS 2 server.
---
--- ## The gap this closes
---
--- §12 makes the desired-state path and the old command path *"run together
--- until every device converges, then events go"*, and calls that dual run the
--- safety mechanism for the highest-risk phase in the plan. `reconcile` does
--- send both - and sends both on `icos`, which only a device that already
--- speaks ICOS 2 can receive.
---
--- **So the dual run protected nobody.** Every turtle in the live fleet is an
--- ICOS 1 miner talking `ccfleet` (§13: *"the migration that actually runs on
--- ten machines"*). The moment `startup.lua` boots `os/server/main.lua` those
--- ten turtles would have gone silent to their own base: no heartbeats, so no
--- registry, so no Devices page and no recall - and no sector leases either,
--- because a mine request is a `ccfleet` message like any other, so the fleet
--- would also have stopped being able to ask where to dig.
---
--- That is §1's first two failures reappearing, caused by the change that was
--- meant to fix them.
---
--- ## Why a service and not a second protocol on `discovery`
---
--- Receiving consumes, so one loop per protocol is the rule (`discovery.lua`).
--- Two loops on two protocols do not eat each other's traffic - rednet filters
--- by protocol - so this is a second inbox rather than a second reader of the
--- first, and the supervisor is what makes running two loops safe.
---
--- It is a *bridge*, not a second implementation. Every decision it reaches is
--- made by the same code the ICOS 2 path uses: `registry.observe` records the
--- heartbeat, `desired` decides what the device should be doing, and
--- `leases.handle` answers the mine request. This file only changes the shape
--- of the envelope and the name of the protocol. A rule that lived here would
--- be a rule that applies to half the fleet, which is how two systems drift
--- into being two systems.
---
--- ## A legacy device converges on its command result, not on a generation
---
--- ICOS 1 has no notion of an applied generation, so a legacy device reports
--- nothing that `desired.converged` can read and would be nudged forever. What
--- it *does* send is a `command_result` saying whether it carried the order
--- out, which is the same information arriving by a different route. So a
--- successful result advances the observed generation to the one that was sent.
---
--- The dishonest alternative - marking it converged when the command is sent -
--- would make the Devices page say "converged" for a turtle that never heard
--- the message, which is precisely the "sent" status §5 exists to abolish.
---
--- ## It cannot make a turtle worse off
---
--- Everything here is best-effort in the D004 sense. A legacy device that never
--- hears a reply keeps doing what it was doing; a malformed message is dropped
--- rather than raised; and nothing in this file can produce a stopped turtle,
--- because nothing in it runs without a message having arrived first.

local desired = require("domain.fleet.desired")
local leases = require("os.server.services.leases")
local persist = require("os.server.services.persist")
local registry = require("domain.fleet.registry")
local service = require("os.kernel.service")
local wire = require("domain.protocol.message")

local bridge = {}

bridge.PROTOCOL = wire.LEGACY_NAME

--- The rednet name ICOS 1 devices resolve to find their base.
---
--- `legacy/net.lua` spells it too, and here it is spelled again rather than
--- required, because requiring that file opens modems and reads `peripheral` -
--- an ICOS 2 service reaching into ICOS 1's runtime would be the inversion §3
--- exists to forbid. Two spellings of one string is the lesser evil, and the
--- spec asserts they match so the drift D040 warns about cannot happen quietly.
bridge.HOSTNAME = "base"

--- The ICOS 1 message kinds this understands.
---
--- Deliberately short. `hello` and `status` are the fleet reporting itself,
--- `mine` is a sector request, and `command_result` is an acknowledgement.
--- Everything else on that protocol - `fleet_sync`, `fleet_node`, `controller`
--- - is base-to-base or base-to-handheld chatter that an ICOS 2 server has its
--- own answer for, and answering it here would mean two authorities.
bridge.HELLO = "hello"
bridge.STATUS = "status"
bridge.MINE = "mine"
bridge.RESULT = "command_result"

--- The command envelope ICOS 1 devices act on.
bridge.COMMAND = "command"

--- How often one legacy device may be sent the same order again.
---
--- Six seconds, matching `reconcile.EVERY`, and it matters more here: a legacy
--- turtle heartbeats every two seconds and this answers heartbeats, so without
--- a throttle a pending recall would go out three times as often as it needs
--- to until the acknowledgement came back. Recall twice is recall, so the cost
--- is traffic and log noise rather than a wrong outcome - but a base that
--- transmits three times more than it needs to is a base that will drop
--- something else.
bridge.EVERY = 6

--- Is this device due to be told its goal again?
---
--- Split out so a spec can ask without a radio, and so the throttle is one
--- expression rather than a condition spread through the handler. The three
--- conditions are `reconcile.due`'s, minus reachability: this is only ever
--- called while a message from the device is in hand, which is a stronger
--- statement about reachability than any staleness threshold.
function bridge.due(record, now, every)
  local goal = desired.reply(record)
  if goal == nil or desired.converged(record) then
    return nil
  end
  local last = record.commandedAt
  local elapsed = last == nil and math.huge or (now - last) / 1000
  if elapsed < (every or bridge.EVERY) then
    return nil
  end
  return goal
end

--- Record an ICOS 1 heartbeat, and work out what to send back.
---
--- Returns a list of legacy envelopes to send, which is empty far more often
--- than not: a converged turtle checking in gets nothing, exactly as it does
--- from an ICOS 1 base.
function bridge.heartbeat(context, sender, snapshot, now, command)
  if type(snapshot) ~= "table" then
    return {}
  end

  local record = registry.observe(context.state.fleet, sender, snapshot, now)

  -- What marks this device as one that cannot speak the new protocol. It is a
  -- fact about the device rather than about this message, so it is recorded on
  -- the record and read by `reconcile`, which would otherwise send a `desired`
  -- reply onto a protocol this device is not listening to.
  record.legacy = true

  -- The heartbeat refreshes *when* this device was last heard from, and moves
  -- the applied generation not at all - it is re-observed at whatever the last
  -- `command_result` left it. ICOS 1 reports no generation, and reading a zero
  -- out of its silence would be inventing one.
  --
  -- Refreshing the timestamp is not cosmetic. `desired.status` reads it to tell
  -- pending from unreachable, so a legacy device with an outstanding order
  -- would otherwise show as unreachable while it was heartbeating every two
  -- seconds - which is the "three busy miners look like three missing ones"
  -- confusion §5 exists to remove, with the sign flipped.
  desired.observe(record, record.observed, now)
  persist.mark(context, "fleet")

  -- A working turtle's lease is renewed from its heartbeat, the same as on the
  -- ICOS 2 path. Without this every ICOS 1 turtle would lose its sector fifteen
  -- minutes after the server started, and two of them would be sent down one
  -- shaft.
  leases.renew(context, sender, snapshot)

  local goal = bridge.due(record, now, context.commandEvery)
  if goal == nil then
    return {}
  end

  local body = command and command(goal) or nil
  if body == nil then
    -- No ICOS 1 equivalent for this goal - `park` is the one that has none.
    -- Nothing is sent and nothing is recorded as sent, so the device stays
    -- pending, which is the honest answer: it cannot be told.
    return {}
  end

  record.commandedAt = now
  record.commandedGeneration = goal.generation
  return { wire.wrap(bridge.COMMAND, body, now) }
end

--- Fold an ICOS 1 acknowledgement into the record.
---
--- A refusal is recorded and *not* treated as convergence, which is what keeps
--- "recall this turtle before changing its job" visible as pending on the
--- Devices page rather than disappearing into a log line nobody reads.
function bridge.result(context, sender, body, now)
  if type(body) ~= "table" then
    return {}
  end

  local record = registry.get(context.state.fleet, sender)
  if record == nil then
    return {}
  end

  if type(body.snapshot) == "table" then
    registry.observe(context.state.fleet, sender, body.snapshot, now)
  end
  record.lastResult = { action = body.action, ok = body.ok ~= false, message = body.message }

  if body.ok ~= false and record.commandedGeneration then
    -- The generation that was actually sent, not the one currently wanted. An
    -- order set while this acknowledgement was in flight must stay pending, or
    -- the newer order is marked applied by a reply to the older one.
    desired.observe(record, {
      mode = record.desired and record.desired.mode,
      generation = record.commandedGeneration,
    }, now)
  end

  persist.mark(context, "fleet")
  return {}
end

--- Answer one ICOS 1 message.
---
--- Returns a list of legacy envelopes, never nil, so the loop is a `for` rather
--- than a branch. `command` is the goal-to-command translator, injected because
--- the one authority on it is `reconcile.legacy` and requiring that from here
--- would close a cycle.
function bridge.handle(context, sender, envelope, command)
  local kind, body = wire.unwrap(envelope)
  if kind == nil then
    return {}
  end

  local now = context.clock.now()

  if kind == bridge.HELLO or kind == bridge.STATUS then
    return bridge.heartbeat(context, sender, body, now, command)
  end

  if kind == bridge.RESULT then
    return bridge.result(context, sender, body, now)
  end

  if kind == bridge.MINE then
    -- Straight through to the service that already owns sector leases. The
    -- body ICOS 1 sends is the body `leases` reads - §5 kept it deliberately -
    -- so this re-addresses the letter without rewriting what is inside it.
    local reply = leases.handle(context, sender, { kind = leases.MINE, body = body })
    if reply == nil then
      return {}
    end
    -- Back into an ICOS 1 envelope. `leases` answers flat because that is the
    -- ICOS 2 shape; a legacy turtle unwraps `body`, and handing it the flat
    -- table would look to it like a message with no body at all.
    return { wire.wrap(reply.kind, reply, now) }
  end

  return {}
end

bridge.service = service.define({
  id = "bridge",
  requires = { "transport", "clock", "state" },

  -- Critical while any device is still on ICOS 1, which is every device today.
  -- A server that cannot hear its own fleet is not a server, for exactly the
  -- reason `discovery` is critical: everything else here operates on state that
  -- arrives as a heartbeat.
  critical = true,

  run = function(context)
    -- Be findable by the name ICOS 1 devices look for, before listening.
    --
    -- Heartbeats and mine requests are broadcast, so they arrive without this.
    -- Everything *addressed* does not: a Pocket controller sends every
    -- authoritative request to `net.findBase()`, and with nothing hosting the
    -- name it reports "base station is offline" and does nothing at all. A
    -- miner also announces itself the first time it sees a base, which is how
    -- a device joining gets logged as joining rather than appearing silently.
    --
    -- Unguarded, and re-run on every restart of this service. The adapter makes
    -- it idempotent (`rednet.host` throws on a second host of one protocol), and
    -- a failure here is a real fault worth backing off on rather than something
    -- to swallow: a server nobody can address is a server that has half failed
    -- while looking healthy.
    assert(context.transport.host(bridge.HOSTNAME, bridge.PROTOCOL))

    while true do
      local sender, envelope, protocol =
        context.transport.receive(bridge.PROTOCOL, context.pollSeconds or 2)
      if sender ~= nil and protocol == bridge.PROTOCOL then
        for _, out in ipairs(bridge.handle(context, sender, envelope, context.toCommand)) do
          context.transport.send(sender, out, bridge.PROTOCOL)
        end
      end
    end
  end,
})

return bridge
