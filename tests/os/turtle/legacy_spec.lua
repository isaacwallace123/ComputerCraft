--- The turtle's ICOS 1 side: the three ways an upgraded turtle was invisible.

local expect = require("support.expect")
local fleet = require("support.fleet")
local it = require("support.spec").it

local legacy = require("os.turtle.legacy")
local turtleOs = require("os.turtle.main")
local wire = require("domain.protocol.message")

--- A turtle whose radio is recorded rather than discarded.
local function wired(options)
  local machine = fleet.turtleMachine(options)
  local sent = {}
  machine.context.transport.broadcast = function(body, protocol)
    sent[#sent + 1] = { body = body, protocol = protocol }
  end
  machine.sent = sent
  return machine
end

local function onProtocol(sent, protocol)
  local out = {}
  for _, entry in ipairs(sent) do
    if entry.protocol == protocol then
      out[#out + 1] = entry.body
    end
  end
  return out
end

it("an upgraded turtle is still on the old base's roster", function()
  -- §12 says turtles update before the base does, so the ordinary case during a
  -- rolling update is a new turtle talking to an old base. Heartbeating only on
  -- `icos` made that turtle vanish from the roster it had been on a minute
  -- earlier - §1's first failure, caused by the upgrade meant to fix it.
  local machine = wired({ node = { parked = false, label = "miner-7" } })

  legacy.beat(machine.context)

  local old = onProtocol(machine.sent, wire.LEGACY_NAME)
  expect.equal(#old, 1, "it announced itself on ccfleet")

  local kind, body = wire.unwrap(old[1])
  expect.equal(kind, "status", "in the envelope ICOS 1 unwraps")
  expect.equal(assert(body).label, "miner-7", "carrying the same snapshot")
end)

it("boot wires the order path, so this file is not dead in production", function()
  -- The failure this asserts against is the one this whole file exists to fix,
  -- one level up: code that is green in a spec and unreachable on a machine.
  -- Two tests below set `context.orders` by hand, which would pass perfectly
  -- while `boot` had never set it and every command was dropped in the world.
  local machine = fleet.turtleMachine()
  expect.equal(machine.context.orders, turtleOs.orders, "the composition root set it")
end)

it("an ICOS 1 command reaches the control flags at last", function()
  -- `agent.receive` has always handled `kind == "command"`, and its header says
  -- why: a turtle that ignored commands during a rolling update would ignore
  -- recall, which is a safety control. That branch could never run, because the
  -- turtle neither spoke nor listened on the protocol commands arrive on.
  local machine = wired({ node = { parked = false } })
  machine.context.orders = turtleOs.orders

  local outcome =
    assert(legacy.route(machine.context, wire.wrap("command", { action = "recall" }, 0)))

  expect.truthy(outcome.applied, "the order was carried out")
  expect.truthy(machine.context.flags.recall, "and the turtle is coming home")
end)

it("a sector is asked for on both protocols, so whichever base is listening answers", function()
  -- The third way it was invisible. A mine request on `icos` alone means an
  -- upgraded turtle under an old base is never given a sector, so it idles or
  -- digs where somebody else is digging - the collision D018 exists to prevent,
  -- reintroduced by the upgrade.
  local machine = wired({ node = { parked = false } })

  legacy.mine(machine.context, { action = "claim", workKey = "w" })

  local old = onProtocol(machine.sent, wire.LEGACY_NAME)
  expect.equal(#old, 1, "the old base was asked")

  local kind, body = wire.unwrap(old[1])
  expect.equal(kind, "mine", "as a mine request")
  expect.equal(assert(body).action, "claim", "with the body ICOS 1 already understands")
end)

it("the whole fleet's chatter is heard and ignored", function()
  -- Every turtle's heartbeat is a broadcast, so this loop hears all of them. A
  -- turtle that acted on a peer's status - or logged it - would fill its own
  -- disk with other people's news.
  local machine = wired({ node = { parked = false } })
  machine.context.orders = turtleOs.orders

  expect.falsy(
    legacy.route(machine.context, wire.wrap("status", fleet.legacySnapshot(), 0)),
    "a peer's heartbeat is not an order"
  )
  expect.falsy(machine.context.flags.recall, "and nothing happened to this turtle")
end)

it("a malformed message is dropped rather than raised", function()
  -- D004 in its smallest form: nothing that arrives on a radio can stop a
  -- turtle, including something that is not a message.
  local machine = wired({ node = { parked = false } })
  machine.context.orders = turtleOs.orders

  expect.falsy(legacy.route(machine.context, nil), "no message")
  expect.falsy(legacy.route(machine.context, {}), "no kind")
  expect.falsy(legacy.route(machine.context, { kind = 7 }), "a kind that is not a string")
  expect.falsy(legacy.route(machine.context, wire.wrap("command", "not a table", 0)), "no body")
end)

it("the legacy loop is one of the turtle's services, and is not critical", function()
  -- A turtle that cannot talk to a base keeps working (D004). This one matters
  -- less than the ICOS 2 heartbeat, not more: it does nothing at all once the
  -- fleet has converged, which is when the file is deleted.
  local found = nil
  for _, definition in ipairs(turtleOs.services()) do
    if definition.id == "legacy" then
      found = definition
    end
  end

  expect.falsy(assert(found, "registered").critical, "registered, and not critical")
end)
