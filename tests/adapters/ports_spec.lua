--- Ports, and the two sets of adapters behind them.
---
--- The point of these is narrow and worth stating, because it is easy to mistake
--- them for tests of `fs` and `turtle`. They check that **both** implementations
--- of each port satisfy its contract and agree on the shape of an answer. A
--- domain module written against `storage.read` returning nil for a missing file
--- must not discover, in game, that one of the two returns an empty string.
---
--- The cc adapters are exercised against the simulated world's CC globals rather
--- than a real computer. That is not a substitute for running them in game - the
--- world is a model - but it does catch the failures that actually happen when a
--- layer like this is written: a method missing from a table, an argument in the
--- wrong order, a `false` where nil was meant.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

---------------------------------------------------------------------------
-- The contract
---------------------------------------------------------------------------

it("every cc adapter satisfies its port at construction", function()
  scenario.new({ groundY = 64 })

  -- `check` raises on a missing method, so constructing each one is the
  -- assertion. If this ever fails it fails here rather than at the one call
  -- site that happened to need the method, on a machine in a mine.
  require("adapters.cc.clock").new()
  require("adapters.cc.storage").new()
  require("adapters.cc.transport").new()
  require("adapters.cc.body").new()
  require("adapters.cc.locator").new()
  require("adapters.cc.screen").new()
  require("adapters.cc.input").new()
end)

it("the scripted input port replays what a person did", function()
  local hands = require("adapters.sim.input").new({ { "char", "q" } })
  hands.click(4, 2)

  local name, button, x, y = hands.port.pull()
  expect.equal(name, "char", "the scripted event comes first")

  name, button, x, y = hands.port.pull()
  expect.equal(name, "mouse_click", "then the pushed one")
  expect.equal(button, 1, "left button by default")
  expect.equal(x, 4, "at x")
  expect.equal(y, 2, "at y")

  -- Nil rather than blocking. A test that runs out of events is finished, and
  -- blocking would hang the suite rather than fail it.
  expect.equal(hands.port.pull(), nil, "and nil once the script is spent")
end)

it("an app can wake its own loop through the input port", function()
  -- The reason `queue` is on the port at all: without it the desktop's own
  -- events need a side channel, and the loop needs a polling timeout to notice
  -- them - which is the difference between an idle dashboard costing nothing
  -- and costing a wakeup a second.
  local hands = require("adapters.sim.input").new()
  hands.port.queue("icos_open_app", "devices")
  local name, payload = hands.port.pull()
  expect.equal(name, "icos_open_app", "the injected event arrives")
  expect.equal(payload, "devices", "with its argument")
end)

it("every sim port satisfies its contract", function()
  local world = scenario.new({ groundY = 64 })
  local ports = world:ports()

  expect.truthy(ports.clock, "clock")
  expect.truthy(ports.storage, "storage")
  expect.truthy(ports.transport, "transport")
  expect.truthy(ports.body, "body")
  expect.truthy(ports.locator, "locator")
end)

---------------------------------------------------------------------------
-- Storage, where the two implementations most need to agree
---------------------------------------------------------------------------

it("both storage adapters round-trip a file and agree on a missing one", function()
  local world = scenario.new({ groundY = 64 })

  for name, storage in pairs({
    cc = require("adapters.cc.storage").new(),
    sim = world:ports().storage,
  }) do
    expect.equal(storage.read("/.absent"), nil, name .. ": a missing file reads as nil")

    expect.truthy(storage.write("/.probe", "hello"), name .. ": write succeeds")
    expect.equal(storage.read("/.probe"), "hello", name .. ": and reads back")

    -- Replace, not append. A storage port that appended would corrupt every
    -- config file in the fleet on its second save.
    storage.write("/.probe", "again")
    expect.equal(storage.read("/.probe"), "again", name .. ": a second write replaces")

    expect.truthy(storage.delete("/.probe"), name .. ": delete succeeds")
    expect.equal(storage.read("/.probe"), nil, name .. ": and it is gone")
  end
end)

it("the cc storage adapter leaves no temporary file behind", function()
  local world = scenario.new({ groundY = 64 })
  local storage = require("adapters.cc.storage").new()

  storage.write("/.probe", "value")
  -- The `.tmp` is the crash-recovery window, not a leftover. A stale one would
  -- be read in preference to nothing by `core/config`, which is how a turtle
  -- ends up restoring a position it had already moved on from.
  expect.falsy(world.files["/.probe.tmp"], "the temporary is moved, not copied")
  expect.equal(world.files["/.probe"], "value", "and the live file holds the value")
end)

---------------------------------------------------------------------------
-- The body
---------------------------------------------------------------------------

it("the body ports move a turtle and report refusals with a reason", function()
  local world = scenario.new({ groundY = 64 })

  for name, body in pairs({
    cc = require("adapters.cc.body").new(),
    sim = world:ports().body,
  }) do
    local startY = world.y
    expect.truthy(body.move("up"), name .. ": up is clear")
    expect.equal(world.y, startY + 1, name .. ": and the turtle went there")

    expect.truthy(body.move("down"), name .. ": back down")
    expect.equal(world.y, startY, name .. ": to where it started")

    -- Standing on the ground, digging down finds a block; digging up finds air,
    -- and CC reports that as a refusal rather than a no-op.
    expect.truthy(body.detect("down"), name .. ": ground below")
    local dug, reason = body.dig("up")
    expect.falsy(dug, name .. ": nothing to dig above")
    expect.contains(reason, "Nothing to dig", name .. ": and says so")

    body.dig("down")
    world:set(world.x, world.y - 1, world.z, "minecraft:grass_block")

    local ok, why = body.move("sideways")
    expect.falsy(ok, name .. ": a direction that does not exist is refused")
    expect.contains(why, "no such direction", name .. ": by name")
  end
end)

---------------------------------------------------------------------------
-- Transport, which is allowed to fail and must say so calmly
---------------------------------------------------------------------------

it("a send with no modem is false, not an error", function()
  scenario.new({ groundY = 64 })
  local transport = require("adapters.cc.transport").new()

  -- D004: nothing may treat a send as a delivery guarantee, and a machine with
  -- no modem is the same case as a turtle out of range - ordinary, not broken.
  expect.falsy(transport.send(2, { hello = true }, "icos"), "send reports failure")
  expect.equal(transport.receive("icos", 0), nil, "receive times out quietly")
end)

it("the sim transport loops messages back and can be told to drop them", function()
  local world = scenario.new({ groundY = 64, id = 9 })
  local transport = world:ports().transport

  expect.truthy(transport.send(2, { action = "recall" }, "icos"), "queued")
  local from, message, protocol = transport.receive("icos", 0)
  expect.equal(from, 9, "the sender names itself")
  expect.equal(message.action, "recall", "the payload survives")
  expect.equal(protocol, "icos", "so does the protocol")
  expect.equal(transport.receive("icos", 0), nil, "and the queue is drained")

  world.dropMessages = true
  expect.falsy(transport.send(2, { action = "recall" }, "icos"), "dropped when told to")
  expect.equal(transport.receive("icos", 0), nil, "nothing arrives")
end)

---------------------------------------------------------------------------
-- Locator
---------------------------------------------------------------------------

it("a device that has not been set up does not guess where it is", function()
  local world = scenario.new({ groundY = 64 })

  local sim = world:ports().locator
  expect.equal(sim.gps(0), nil, "no constellation, no fix")
  expect.equal(sim.saved(), nil, "and nothing written down")

  -- 0,0,0 is a real place in the world. A locator that answered with it rather
  -- than nil would send a turtle to the middle of the map, which is exactly the
  -- failure `sector = 0` already caused once.
  local cc = require("adapters.cc.locator").new(".location", function()
    return {}
  end)
  expect.equal(cc.saved(), nil, "an empty record is not a location")

  world.fix = { x = 12, y = 70, z = -30 }
  local x, y, z = world:ports().locator.gps(0)
  expect.equal(x, 12, "a fix, once there is one")
  expect.equal(y, 70, "y")
  expect.equal(z, -30, "z")
end)
