--- The turtle's ICOS 1 side, so an upgraded turtle is not invisible to an old base.
---
--- ## The mirror of the gap `os/server/services/bridge.lua` closes
---
--- That file exists because an ICOS 2 *server* could not hear an ICOS 1 fleet:
--- `reconcile` sent the dual run on `icos` and every live turtle speaks
--- `ccfleet`. This is the same hole in the other direction, and §12 says this
--- direction happens **first**: *"turtles update before the base does."* The
--- updater deploys by manifest and a fleet upgrades a machine at a time, so the
--- ordinary case during a rolling update is a new turtle talking to an old base.
---
--- Without this, that turtle is invisible three ways at once. Its heartbeat goes
--- out on `icos`, so it vanishes from the roster. It listens only on `icos`, so
--- no recall reaches it. And its mine request goes out on `icos`, so it is never
--- given a sector and either idles or digs where somebody else is digging.
---
--- ## It made dead code reachable
---
--- `agent.receive` has always handled `kind == "command"`, and its header says
--- why in as many words: turtles update before the base does, and a turtle that
--- ignored commands in that window would ignore recall, which is a safety
--- control. That was right, and it could never run - the turtle neither spoke
--- nor listened on the protocol those commands arrive on. The branch was written
--- for a window it could not observe.
---
--- ## Both protocols, always, until the file is deleted
---
--- Not detected. A turtle could notice whether an ICOS 2 server has answered
--- recently and stop sending the legacy copy, and that would save one broadcast
--- every two seconds - at the cost of a mode, a timeout, and a turtle that flips
--- back to legacy every time it walks out of range. The switch that ends the
--- dual run is deleting this file, which is one decision, taken once, by a
--- person who can see the whole fleet's build numbers.
---
--- The cost of not detecting is one extra broadcast per turtle per heartbeat.
---
--- ## It is a translator, not a second turtle
---
--- Every decision it reaches is made by the same code the ICOS 2 path uses:
--- `turtleOs.orders` for an order, `site.deliver` for a sector reply. This file
--- changes the envelope and the protocol name and nothing else. A rule that
--- lived here would be a rule that applies to half of a rolling update, which is
--- how one system becomes two.

local peer = require("domain.protocol.peer")
local service = require("os.kernel.service")
local wire = require("domain.protocol.message")

local legacy = {}

legacy.PROTOCOL = wire.LEGACY_NAME

--- Seconds between legacy heartbeats.
---
--- The same two the ICOS 2 heartbeat uses, because it is the interval
--- `legacy/fleet/roster.lua` decides "online" against. A turtle that reported on
--- a different cadence to the base watching it would drift in and out of the
--- roster for no reason anybody could see.
legacy.HEARTBEAT = 2

--- Say hello and say what we are doing, in the envelope ICOS 1 expects.
---
--- The snapshot is the same table the ICOS 2 heartbeat sends - `engine.lua`
--- hands over ICOS 1's own `ctx:snapshot()`, so the two protocols carry
--- identical contents and differ only in the wrapper. That is what makes this a
--- translation rather than a second implementation.
--- Whether this turtle still needs to speak ICOS 1 at all.
---
--- No, once an ICOS 2 server has answered it. `domain/protocol/peer.lua` holds
--- the address of whoever replied to the last heartbeat, and a turtle with a
--- live ICOS 2 base has nothing left to say to an ICOS 1 one - §12's dual run is
--- over for that device, whatever the rest of the fleet is doing.
---
--- Worth its own function because the cost is not small. This loop *broadcasts*,
--- so every beat wakes every computer in range and makes each resume every
--- service it has to discard the message - and it beat every two seconds
--- alongside the ICOS 2 heartbeat, which means each turtle was waking the whole
--- world twice as often as it needed to. On a shared ten-millisecond budget
--- (see `domain/protocol/peer.lua`) that is other machines' time.
---
--- Self-disabling rather than a setting. A flag would be a thing somebody has to
--- know to turn off, and the machine already has the evidence.
function legacy.needed(context)
  return peer.address(context.peer, context.clock.now()) == nil
end

function legacy.beat(context)
  if not legacy.needed(context) then
    return nil
  end
  local snapshot = context.snapshot()
  context.transport.broadcast(wire.wrap("status", snapshot, context.clock.now()), legacy.PROTOCOL)
  return snapshot
end

--- Route one ICOS 1 message.
---
--- Returns what it did, or nil for a message that is not ours - which is most of
--- them, because every turtle's heartbeat is broadcast and this loop hears the
--- whole fleet's. Dropping quietly is the only correct behaviour: a turtle that
--- logged every peer's status would fill its own disk with other people's news.
---
--- The sender is not a parameter, and that is not an oversight. ICOS 1 has no
--- way for a computer to prove who it is, so checking the id would be a check
--- anything on the modem could pass - security theatre that reads like security.
--- The real boundary is the modem being in a base nobody else can reach, which
--- is stated in `discovery.want` and is no weaker here.
function legacy.route(context, envelope)
  local kind, body = wire.unwrap(envelope)
  if kind == nil then
    return nil
  end

  if kind == "command" and type(body) == "table" then
    -- Into the same path a desired-state reply takes. `agent.receive` already
    -- knows how to read an ICOS 1 command; it has simply never been given one.
    return context.orders(context, { kind = "command", command = body })
  end

  if kind == "mine_result" and type(body) == "table" then
    -- The sector reply. It arrives here rather than where it was asked for,
    -- exactly as it does on the ICOS 2 path, because a broadcast has no
    -- addressee to answer.
    local site = require("os.turtle.site")
    site.deliver(body)
    return { delivered = true }
  end

  return nil
end

--- Ask for a sector on the old protocol.
---
--- Called alongside the ICOS 2 request rather than instead of it, so a turtle
--- gets an answer from whichever base is listening. Two bases answering is not a
--- problem worth solving: `site.deliver` takes the first reply that matches the
--- request it is waiting on, and an ICOS 1 base and an ICOS 2 base cannot both
--- be authoritative for the same mine - `startup.lua` picks one per machine.
function legacy.mine(context, body)
  context.transport.broadcast(wire.wrap("mine", body, context.clock.now()), legacy.PROTOCOL)
end

legacy.service = service.define({
  id = "legacy",
  requires = { "transport", "clock", "state" },

  -- Not critical, for the same reason `heartbeat` is not: a turtle that cannot
  -- talk to a base keeps working (D004). It is *less* critical than that one,
  -- because this loop only matters during a rolling update and does nothing at
  -- all once the fleet has converged - which is the point at which the file goes.
  critical = false,

  run = function(context)
    while true do
      legacy.beat(context)

      -- Still listening even when it has stopped speaking. Hearing an ICOS 1
      -- base costs nothing this turtle can avoid - the message arrives whether
      -- or not it is read - and a turtle that stopped reading would be a turtle
      -- that ignores a recall from the only base that can still send one.
      local sender, envelope, protocol =
        context.transport.receive(legacy.PROTOCOL, legacy.HEARTBEAT)
      if sender ~= nil and protocol == legacy.PROTOCOL then
        legacy.route(context, envelope)
      end
    end
  end,
})

return legacy
