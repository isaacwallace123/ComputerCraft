--- The wire contract: one protocol name, one version field, and the rule that
--- makes a rolling update safe.
---
--- §13 of docs/icos-2.md promised this in phase 1 and it was never written:
--- *"A device on an old build must keep working against a new server through
--- phase 3. Protocol messages gain a version field in phase 1 so that stays
--- true."* Without it there is no way for either side to tell a message it
--- fully understands from one that merely parses.
---
--- ## Why one place spells "icos"
---
--- `discovery.lua` already says it: *"kept as a constant rather than inlined so
--- the miner and the server cannot drift apart by a typo, which is a failure
--- mode with no error message."* It was then inlined in seven files - the
--- server, the turtle, the client, the mobile, `reconcile`, `leases`, and the
--- Devices app - each with its own copy of the literal. Seven copies of a
--- constant is not a constant, and the failure it was written to prevent is
--- exactly the one nobody would find: both sides work perfectly and never hear
--- each other, because there is nothing to hear.
---
--- ## The compatibility rule
---
--- **A version bump may add fields and add kinds. It may never change what an
--- existing field means.** A change that cannot obey that gets a new `kind`,
--- not a new version number.
---
--- That single sentence is what makes `accept` able to take a message from the
--- future. A turtle updated ahead of its base sends `v = 3` to a server that
--- speaks 2; every field the server knows how to read still means what it
--- meant, so the server reads those and ignores the rest. The alternative -
--- refusing anything newer than ourselves - would strand precisely the devices
--- the updater upgrades first, and the updater upgrades turtles first.
---
--- ## Absent means one, not zero
---
--- An ICOS 2 message with no `v` came from a build made before this file
--- existed. That is a real build, it is on the fleet, and its messages are
--- valid version 1 - so the missing field is a default, not a fault. Reading it
--- as zero would make every pre-versioning device look like it was speaking a
--- protocol that never existed.
---
--- ## Pure, and it has to be
---
--- No clock, no radio, no I/O. Deciding whether a message is comprehensible is
--- a question about the message, and a question about a message is answerable
--- with the message - which is what lets every branch below be a spec rather
--- than a fleet-wide experiment.

local build = require("lib.version")

local message = {}

--- The rednet protocol ICOS 2 devices talk on.
---
--- Distinct from ICOS 1's `ccfleet` (`legacy/net.lua`) on purpose: the two
--- systems have different message shapes, and sharing a protocol name would let
--- an ICOS 1 base receive an ICOS 2 heartbeat it cannot parse. Two names, and a
--- mixed fleet is two conversations that ignore each other rather than one
--- conversation that half-works.
message.NAME = "icos"

--- The rednet protocol ICOS 1 devices talk on.
---
--- Named here, beside the new one, because the two together are the whole
--- compatibility story and reading one without the other is how the gap below
--- was missed for a whole phase.
---
--- **An ICOS 1 device and an ICOS 2 server are mutually deaf without a
--- translator.** §12 says the desired-state path and the old command path *"run
--- together until every device converges"*, and `reconcile` duly sends both -
--- but it sends both on `icos`, which only a device that already speaks ICOS 2
--- can receive. The dual run protected nobody. Every turtle in the live fleet
--- is ICOS 1, so the moment `startup.lua` boots the new server the fleet would
--- have vanished from it: no heartbeats, no registry, no recall, and no sector
--- leases either, because a mine request is a `ccfleet` message too.
---
--- `os/server/services/bridge.lua` is the translator, and this constant is what
--- stops it and `legacy/net.lua` from disagreeing about the name.
message.LEGACY_NAME = "ccfleet"

--- What this build speaks.
---
--- One, because this is where versioning starts. Bump it when a message gains a
--- field or a kind; do not bump it for a change that breaks the rule above,
--- because no number can make that change safe.
message.VERSION = 1

--- How a message relates to what we speak.
message.LEGACY = "legacy" --- no version field: a pre-versioning ICOS 2 build
message.CURRENT = "current" --- the same version, or older than us
message.NEWER = "newer" --- from a build ahead of this one

--- Stamp an outbound message.
---
--- Returns the same table, mutated. Mutating rather than copying is deliberate:
--- every caller builds a fresh table literal at the send site, so a copy would
--- allocate a second one per heartbeat for no benefit, and there is no case in
--- this codebase where a message table outlives its send.
---
--- `build` rides on every message rather than only on `hello`. A device that is
--- already known never sends another hello, so a build string carried only
--- there would be the version that device had when the server last rebooted -
--- and "which devices are still on the old build" is the one question a rolling
--- update needs answered, at the moment it is least true.
function message.stamp(body)
  body.v = message.VERSION
  body.build = build
  return body
end

--- What version a received message claims. Absent is 1; see the header.
function message.versionOf(body)
  if type(body) ~= "table" then
    return nil
  end
  local claimed = tonumber(body.v)
  if claimed == nil then
    return 1
  end
  return math.floor(claimed)
end

--- Classify a received message, or reject it.
---
--- Returns `body, era` for anything worth handling and `nil, reason` for
--- anything that is not. The two rejections are the only two that exist: it is
--- not a table, or it claims a version below one - which no build ever sent, so
--- it is corruption or somebody else's traffic on our protocol name.
---
--- Note what is *not* rejected: a message from a newer build, a message with a
--- `kind` we have never heard of, and a message with fields we do not read. The
--- first is the rolling update working as designed, and the other two are how a
--- handler that does not want a message declines it - `nil` from
--- `discovery.handle` already means "not ours", and duplicating that judgement
--- here would put the list of valid kinds in two files.
function message.accept(body)
  if type(body) ~= "table" then
    return nil, "not a table"
  end

  local claimed = tonumber(body.v)
  if claimed == nil then
    return body, message.LEGACY
  end

  claimed = math.floor(claimed)
  if claimed < 1 then
    return nil, "impossible version: " .. tostring(body.v)
  end
  if claimed > message.VERSION then
    return body, message.NEWER
  end
  return body, message.CURRENT
end

---------------------------------------------------------------------------
-- The ICOS 1 envelope
---------------------------------------------------------------------------

--- Wrap a body in the envelope ICOS 1 puts on the wire.
---
--- `{ kind, body, at }`, which is what `legacy/net.lua` sends and what
--- `legacy/miner/network.lua` expects to unwrap. It is described here rather
--- than left implicit in the bridge because it is a wire format two systems
--- depend on, and a wire format that only exists as the shape of a table
--- literal in one file is a wire format nobody can check.
---
--- `at` is passed rather than read, for the same reason every other clock in
--- `domain/` is (D041). ICOS 1 never reads this field - it is there because the
--- original envelope carried it - so it is preserved rather than relied upon.
function message.wrap(kind, body, at)
  return { kind = kind, body = body, at = at }
end

--- Take an ICOS 1 envelope apart. Returns kind and body, or nil.
---
--- The same validation `net.receive` does, in the same order: a message that is
--- not a table, or whose `kind` is not a string, is dropped rather than
--- crashing the listener. Duplicated deliberately - the bridge cannot require
--- `legacy/net.lua`, which opens modems and reads `peripheral`, and a domain
--- module that reached for either would be the exact inversion §3 forbids.
function message.unwrap(envelope)
  if type(envelope) ~= "table" or type(envelope.kind) ~= "string" then
    return nil
  end
  return envelope.kind, envelope.body
end

--- The build string a message was sent by, or nil.
---
--- Separated from `accept` because it is an observation rather than a gate.
--- A device on an unknown build is still a device to talk to; refusing one
--- would make the dashboard's own reporting a reason to lose a turtle.
function message.buildOf(body)
  if type(body) ~= "table" or type(body.build) ~= "string" then
    return nil
  end
  return body.build
end

return message
