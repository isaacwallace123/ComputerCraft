--- Who a device talks to, and what it costs everyone else when it shouts.
---
--- The failure this guards is not a device that cannot reach its base - that one
--- announces itself. It is a device that *can*, and shouts anyway: every machine
--- in range wakes, resumes every coroutine it has, and discards the message.
--- Nothing errors, nothing logs, and the whole world gets slower.

local expect = require("support.expect")
local it = require("support.spec").it

local peer = require("domain.protocol.peer")

local NOW = 1700000000 * 1000
local SECOND = 1000

--- A transport that records how a message went out rather than sending it.
local function radio(sendable)
  local out = { sent = {}, shouted = 0 }
  out.send = function(id, message, protocol)
    if sendable == false then
      return false
    end
    out.sent[#out.sent + 1] = { id = id, message = message, protocol = protocol }
    return true
  end
  out.broadcast = function()
    out.shouted = out.shouted + 1
  end
  return out
end

it("a device that has heard nothing has to shout", function()
  local state = peer.empty()
  expect.equal(peer.address(state, NOW), nil, "there is nobody to address yet")

  local air = radio()
  expect.falsy(peer.send(state, air, { kind = "status" }, "icos", NOW))
  expect.equal(air.shouted, 1)
  expect.equal(#air.sent, 0)
end)

it("whoever answers is who it talks to next", function()
  local state = peer.empty()
  peer.remember(state, 5, NOW)

  local air = radio()
  expect.truthy(peer.send(state, air, { kind = "status" }, "icos", NOW))

  -- The whole point. This message wakes one computer instead of every computer
  -- in range, and the difference is charged to a budget the fleet shares.
  expect.equal(air.shouted, 0, "no broadcast")
  expect.equal(#air.sent, 1)
  expect.equal(air.sent[1].id, 5)
end)

it("an address that has gone quiet is given up", function()
  local state = peer.empty()
  peer.remember(state, 5, NOW)

  expect.equal(peer.address(state, NOW + 29 * SECOND), 5, "still worth trying")

  -- A base rebuilt with a new id, moved, or replaced by a spare all look
  -- identical to a device: silence. Forgetting is the only way back to finding
  -- it, and it has to happen before the fleet writes the device off.
  expect.equal(peer.address(state, NOW + 31 * SECOND), nil)
  expect.truthy(peer.FORGET < 60, "sooner than a device counts as offline")
end)

it("a refused send gives up immediately rather than waiting out the timeout", function()
  local state = peer.empty()
  peer.remember(state, 5, NOW)

  -- `transport.send` answering false means the radio could not reach that id.
  -- That is a fact available now; waiting for the thirty seconds would be thirty
  -- seconds of a turtle talking to a computer that is not there.
  local air = radio(false)
  expect.falsy(peer.send(state, air, { kind = "status" }, "icos", NOW))
  expect.equal(air.shouted, 1, "it fell back to shouting in the same breath")
  expect.equal(peer.address(state, NOW), nil, "and forgot the address")
end)

it("hearing again after being forgotten starts it over", function()
  local state = peer.empty()
  peer.remember(state, 5, NOW)
  expect.equal(peer.address(state, NOW + 31 * SECOND), nil)

  peer.remember(state, 9, NOW + 32 * SECOND)
  expect.equal(peer.address(state, NOW + 32 * SECOND), 9, "and it is the new one")
end)

it("nonsense is not remembered", function()
  local state = peer.empty()
  expect.falsy(peer.remember(state, "five", NOW))
  expect.falsy(peer.remember(nil, 5, NOW))
  expect.equal(peer.address(state, NOW), nil)
  expect.equal(peer.address(nil, NOW), nil)
end)

it("a turtle with a live base stops speaking the old protocol", function()
  -- `os/turtle/legacy.lua` broadcasts an ICOS 1 status every two seconds, beside
  -- the ICOS 2 heartbeat - so each turtle was waking every machine in range
  -- twice as often as it needed to, for a base that may not exist.
  --
  -- The evidence that it can stop is the same evidence used for addressing: an
  -- ICOS 2 server has answered. A flag would be a thing somebody has to know to
  -- turn off.
  local legacy = require("os.turtle.legacy")
  local clock = {
    now = function()
      return NOW
    end,
  }

  local silent = { peer = peer.empty(), clock = clock }
  peer.remember(silent.peer, 5, NOW)
  expect.falsy(legacy.needed(silent), "an ICOS 2 base is answering")

  local alone = { peer = peer.empty(), clock = clock }
  expect.truthy(legacy.needed(alone), "nothing has answered, so keep trying both")
end)
