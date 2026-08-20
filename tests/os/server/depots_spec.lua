--- Declaring where the fleet unloads.
---
--- `domain/depot/list.lua` has had priorities, full-detection and item filters
--- since ICOS 1, and nothing could ever add to it: the server allocated an empty
--- list at boot, no message changed it, and no page drew it. Every base ran with
--- zero drop-offs, which made the whole mechanism dead code wearing the shape of
--- a feature. These are the tests for the missing half.

local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local depotList = require("domain.depot.list")
local depots = require("os.server.services.depots")

local function base()
  local ctx = fleet.context()
  local context = ctx.context or ctx
  context.state.depots = depotList.empty()
  return context
end

local function send(context, body)
  return depots.handle(context, 0, { kind = "depot", body = body })
end

it("a chest can be declared, and comes back in the reply", function()
  local context = base()
  local answer = assert(send(context, { action = "add", position = { x = 53, y = 71, z = 426 } }))

  expect.truthy(answer.ok)
  expect.equal(#answer.depots, 1, "the whole list, not the one record that changed")
  expect.equal(answer.depots[1].position.x, 53)
  expect.equal(answer.depots[1].position.z, 426)
  expect.truthy(answer.depots[1].enabled, "and it is in the rotation immediately")
end)

it("a position that is not three numbers is refused rather than defaulted", function()
  -- A depot at 0, 0, 0 is a place in the world that almost certainly has no
  -- chest in it, and a turtle sent there flies the length of the map to find
  -- out that somebody left a field blank.
  local context = base()

  local missing = assert(send(context, { action = "add" }))
  expect.falsy(missing.ok)
  expect.contains(missing.reason, "needs a position")

  local partial = assert(send(context, { action = "add", position = { x = 1, y = 2 } }))
  expect.falsy(partial.ok)
  expect.contains(partial.reason, "x, y and z")

  local text = assert(send(context, { action = "add", position = { x = "here", y = 2, z = 3 } }))
  expect.falsy(text.ok)
  expect.equal(#text.depots, 0, "and nothing was recorded on any of them")
end)

it("order is priority, so it can be changed", function()
  -- Which chest is tried first is a fact about the room somebody built. The
  -- fleet walks this list in order, so this is the whole reason it is a list
  -- and not a set.
  local context = base()
  send(context, { action = "add", label = "far", position = { x = 100, y = 64, z = 0 } })
  send(context, { action = "add", label = "near", position = { x = 2, y = 64, z = 0 } })

  local second = context.state.depots.depots[2].id
  local answer = assert(send(context, { action = "move", id = second, delta = -1 }))

  expect.truthy(answer.ok)
  expect.equal(answer.depots[1].label, "near", "the nearer chest is tried first now")
end)

it("a chest can be switched out of the rotation without being forgotten", function()
  -- Off and full are different states and must stay different. Off is a choice
  -- somebody made; full is a problem. A page showing both as unavailable would
  -- hide which of them needs doing something about.
  local context = base()
  send(context, { action = "add", position = { x = 1, y = 64, z = 1 } })
  local id = context.state.depots.depots[1].id

  local off = assert(send(context, { action = "enable", id = id, enabled = false }))
  expect.truthy(off.ok)
  expect.falsy(off.depots[1].enabled)
  expect.equal(#off.depots, 1, "still declared, just not in use")

  local on = assert(send(context, { action = "enable", id = id, enabled = true }))
  expect.truthy(on.depots[1].enabled)
end)

it("a full chest is routed around rather than stopping the fleet", function()
  -- The reason for having more than one. A turtle with a full inventory and
  -- nowhere to put it stops and waits, which looks exactly like a turtle that
  -- has crashed.
  local context = base()
  send(context, { action = "add", label = "first", position = { x = 1, y = 64, z = 1 } })
  send(context, { action = "add", label = "second", position = { x = 5, y = 64, z = 1 } })

  local state = context.state.depots
  local now = context.clock.now()
  depotList.reportFull(state, state.depots[1].id, now, true)

  local usable = depotList.usable(state, now)
  expect.equal(#usable, 1, "there is still somewhere to unload")
  expect.equal(usable[1].label, "second", "the next one along")
end)

it("acting on a depot that is not there says so rather than half working", function()
  local context = base()

  for _, action in ipairs({ "remove", "move", "enable" }) do
    local answer = assert(send(context, { action = action, id = "nonesuch" }))
    expect.falsy(answer.ok, action .. " reported success for a depot that does not exist")
    expect.contains(answer.reason, "no such depot")
  end

  local unknown = assert(send(context, { action = "juggle" }))
  expect.falsy(unknown.ok)
  expect.contains(unknown.reason, "no such action")
end)

it("messages for somebody else are left alone", function()
  local context = base()
  expect.equal(depots.handle(context, 0, { kind = "status" }), nil)
  expect.equal(depots.handle(context, 0, { kind = "depot" }), nil, "and one with no body")
  expect.equal(depots.handle(context, 0, "depot"), nil)
end)

it("a machine with no depot list refuses rather than erroring", function()
  local ctx = fleet.context()
  local context = ctx.context or ctx
  context.state.depots = nil

  local answer = assert(send(context, { action = "add", position = { x = 1, y = 2, z = 3 } }))
  expect.falsy(answer.ok)
  expect.contains(answer.reason, "keeps no depot list")
end)
