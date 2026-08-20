--- The wire contract: the version field §13 promised and never delivered.
---
--- Every claim in `domain/protocol/message.lua` is a claim about what happens
--- during a rolling update, which is the one situation this fleet cannot
--- rehearse: it lasts a few minutes, it involves machines on two builds at
--- once, and by the time a mistake shows up as a turtle ignoring recall the
--- evidence is gone. So the claims are checked here, where both builds can
--- exist in the same second.

local expect = require("support.expect")
local it = require("support.spec").it

local wire = require("domain.protocol.message")

---------------------------------------------------------------------------
-- One name, one version
---------------------------------------------------------------------------

it("the protocol name is not ICOS 1's", function()
  -- Sharing `ccfleet` would put an ICOS 2 heartbeat in front of an ICOS 1 base
  -- that cannot parse it. Two names, and a mixed fleet is two conversations
  -- that ignore each other rather than one that half-works.
  expect.equal(wire.NAME, "icos", "the ICOS 2 protocol name")
  expect.truthy(wire.NAME ~= "ccfleet", "distinct from ICOS 1")
end)

it("every module that names the protocol names the same one", function()
  -- The failure this guards has no error message: both sides work perfectly
  -- and never hear each other. It was seven independent copies of the literal
  -- before this module existed, which is not a constant.
  local agent = require("os.turtle.agent")
  local client = require("os.client.main")
  local discovery = require("os.server.services.discovery")
  local leases = require("os.server.services.leases")
  local reconcile = require("os.server.services.reconcile")

  for name, value in pairs({
    agent = agent.PROTOCOL,
    client = client.PROTOCOL,
    discovery = discovery.PROTOCOL,
    leases = leases.PROTOCOL,
    reconcile = reconcile.PROTOCOL,
  }) do
    expect.equal(value, wire.NAME, name .. " talks on the shared protocol")
  end
end)

---------------------------------------------------------------------------
-- Stamping
---------------------------------------------------------------------------

it("a stamped message carries the version and the build", function()
  local body = wire.stamp({ kind = "status" })

  expect.equal(body.v, wire.VERSION, "the wire version")
  expect.equal(body.build, require("lib.version"), "the build that sent it")
  expect.equal(body.kind, "status", "and the message is otherwise untouched")
end)

it("stamping returns the same table rather than a copy", function()
  -- Deliberate: every caller builds a fresh literal at the send site, so a copy
  -- would allocate a second table per heartbeat for nothing.
  local body = { kind = "status" }
  expect.truthy(wire.stamp(body) == body, "the same table")
end)

---------------------------------------------------------------------------
-- Accepting
---------------------------------------------------------------------------

it("a message with no version is a pre-versioning build, not a fault", function()
  -- The builds that shipped before this file existed are real, they are on the
  -- fleet, and their messages are valid version 1. Reading the missing field as
  -- zero would make every one of them look like it spoke a protocol that never
  -- existed.
  local body, era = wire.accept({ kind = "status" })

  expect.truthy(body ~= nil, "accepted")
  expect.equal(era, wire.LEGACY, "classified as pre-versioning")
  expect.equal(wire.versionOf({ kind = "status" }), 1, "and reads as version one")
end)

it("a message from a newer build is accepted, not refused", function()
  -- The rolling update working as designed. The updater upgrades machines one
  -- at a time, so a device ahead of the machine reading its message is the
  -- normal case; refusing it would strand exactly the devices that upgraded
  -- first. What makes it safe is the compatibility rule: a version bump may add
  -- fields and kinds, never change what an existing one means.
  local body, era = wire.accept({ kind = "status", v = wire.VERSION + 5 })

  expect.truthy(body ~= nil, "accepted")
  expect.equal(era, wire.NEWER, "and marked as coming from ahead")
end)

it("our own version is current", function()
  local _, era = wire.accept(wire.stamp({ kind = "status" }))
  expect.equal(era, wire.CURRENT, "current")
end)

it("a non-table is refused with a reason", function()
  local body, reason = wire.accept("hello")
  expect.equal(body, nil, "refused")
  expect.contains(reason, "not a table", "and says why")
end)

it("an impossible version is refused", function()
  -- No build ever sent version zero or below, so this is corruption or somebody
  -- else's traffic on our protocol name. Refusing is the only case where a
  -- version number is allowed to stop a message.
  local body, reason = wire.accept({ kind = "status", v = 0 })
  expect.equal(body, nil, "refused")
  expect.contains(reason, "impossible version", "and says why")
end)

it("an unknown kind is not the version gate's business", function()
  -- `discovery.handle` already returns nil for a message that is not its own,
  -- and duplicating the list of valid kinds here would put it in two files.
  local body = wire.accept({ kind = "something-from-2027", v = wire.VERSION })
  expect.truthy(body ~= nil, "passed through to the handler that will decline it")
end)

---------------------------------------------------------------------------
-- Reading the sender's build
---------------------------------------------------------------------------

it("the build is read off the message, and absent is nil not a guess", function()
  expect.equal(wire.buildOf(wire.stamp({})), require("lib.version"), "the stamped build")
  expect.equal(wire.buildOf({ kind = "status" }), nil, "an unstamped message admits nothing")
  expect.equal(wire.buildOf({ build = 7 }), nil, "and a non-string is not a build")
end)
