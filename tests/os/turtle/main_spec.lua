local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local turtleOs = require("os.turtle.main")

local context = fleet.context
local heartbeat = fleet.heartbeat
local turtleContext = fleet.turtleMachine

---------------------------------------------------------------------------
-- The turtle OS: a turtle that keeps working when the radio stops
---------------------------------------------------------------------------

it("an order becomes a control flag the existing runtime already reads", function()
  local machine = turtleContext({ node = { parked = true } })
  local goal = { mode = "deploy", generation = 4 }

  local outcome = assert(turtleOs.orders(machine.context, { kind = "desired", desired = goal }))
  expect.truthy(outcome.applied, "applied")
  expect.truthy(machine.context.flags.deploy, "the flag legacy/miner/runtime.lua reads")
  expect.equal(machine.context.state.applied, 4, "and the generation was recorded")
end)

it("a job change on a running turtle waits instead of being lost", function()
  -- ICOS 1 replied "recall this turtle first" and dropped the order. Under
  -- desired state the goal stays on the server, the turtle keeps reporting a
  -- generation it has not applied, and the base shows it as pending.
  local machine = turtleContext({ node = { parked = false } })
  local goal = { mode = "deploy", job = "rare", generation = 9 }

  local outcome = assert(turtleOs.orders(machine.context, { kind = "desired", desired = goal }))
  expect.falsy(outcome.applied, "not yet")
  expect.falsy(machine.context.flags.assignment, "no half-applied assignment")
  expect.equal(machine.context.state.applied, 0, "and it still reports being behind")

  -- Park it, send the same goal again, and it lands.
  machine.context.node.parked = true
  outcome = assert(turtleOs.orders(machine.context, { kind = "desired", desired = goal }))
  expect.truthy(outcome.applied, "now it applies")
  expect.equal(machine.context.flags.assignment.name, "rare", "with the job attached")
  expect.equal(machine.context.state.applied, 9, "and the generation catches up")
end)

it("an update comes home before replacing the code that is driving", function()
  local machine = turtleContext({ node = { parked = false } })
  local goal = { mode = "update", generation = 3 }
  local outcome = assert(turtleOs.orders(machine.context, { kind = "desired", desired = goal }))

  expect.truthy(outcome.applied, "accepted")
  expect.truthy(machine.context.flags.recall, "returning home first")
  expect.truthy(machine.context.flags.update, "with the update queued behind it")
end)

it("recalling a parked turtle is free, and doing it twice is free twice", function()
  -- Idempotence is what lets the server re-send an order it is not sure
  -- arrived, and it only works if arriving twice costs nothing. It costs
  -- nothing at two layers, which is worth pinning down separately.
  local machine = turtleContext({ node = { parked = true } })
  local goal = { mode = "recall", generation = 2 }

  local outcome = assert(turtleOs.orders(machine.context, { kind = "desired", desired = goal }))
  expect.truthy(outcome.applied, "applied")
  expect.contains(outcome.reason, "already parked", "and it says so")
  expect.falsy(machine.context.flags.recall, "without asking a parked turtle to come home")

  -- The duplicate never reaches the control flags at all: the agent recognises
  -- a generation it has already applied and says nothing. The turtle does not
  -- re-decide, which is one layer better than deciding the same thing again.
  expect.falsy(
    turtleOs.orders(machine.context, { kind = "desired", desired = goal }),
    "the second copy stops at the agent"
  )

  -- And an ICOS 1 command, which carries no generation, is still obeyed - it
  -- reaches the flags every time, exactly as it does today.
  machine.context.node.parked = false
  local again =
    assert(turtleOs.orders(machine.context, { kind = "command", command = { action = "recall" } }))
  expect.truthy(again.applied, "the old protocol still works during the rolling update")
  expect.truthy(machine.context.flags.recall, "and raises the flag")
end)

it("a dead radio does not stop the job", function()
  -- The bug this file exists to fix. legacy/apps/miner.lua runs four coroutines under
  -- parallel.waitForAny, which returns when ANY of them finishes - so a
  -- heartbeat that throws on a missing modem takes the job down with it.
  local mined = 0
  local machine = turtleContext({
    runJob = function(context)
      while true do
        mined = mined + 1
        context.clock.sleep(1)
        coroutine.yield()
      end
    end,
  })

  machine.context.transport.broadcast = function()
    error("no modem", 0)
  end

  for _ = 1, 12 do
    machine.supervisor:step()
    machine.clock.advance(30)
  end

  expect.truthy(mined > 1, "the job kept running")

  -- And the machine is still healthy, because talking about mining is not
  -- mining. A turtle that cannot reach the base keeps mining, which is D004.
  expect.truthy(machine.supervisor:healthy(), "and the turtle is not reported broken")

  local health = machine.supervisor:health()
  local heartbeat
  for _, row in ipairs(health) do
    if row.id == "heartbeat" then
      heartbeat = row
    end
  end
  expect.truthy(heartbeat.failures > 0 or heartbeat.gaveUp, "while the radio is honestly failing")
end)

it("a job that gives up makes the turtle unhealthy", function()
  -- The other half: the job is the machine's entire purpose, so if it stops the
  -- supervisor must say so rather than report a healthy box in a hole.
  local machine = turtleContext({
    runJob = function()
      error("bedrock", 0)
    end,
  })

  for _ = 1, 12 do
    machine.supervisor:step()
    machine.clock.advance(60)
  end

  local healthy, why = machine.supervisor:healthy()
  expect.falsy(healthy, "not healthy")
  expect.contains(why, "job", "and it names the job")
end)

it("a turtle does not bind its radio to another turtle", function()
  -- The bug this is written about took a whole fleet offline while every machine
  -- in it kept working.
  --
  -- Until a device has bound it *broadcasts*, and every other device in range
  -- hears it. Binding to the sender of anything that arrived meant two turtles
  -- booting together each heard the other's heartbeat, each bound to the other,
  -- and both spent the day unicasting their status to a machine that keeps no
  -- registry. The Fleet page showed them offline; they were fine.
  local peer = require("domain.protocol.peer")
  local wire = require("domain.protocol.message")

  local machine = turtleContext({ node = { parked = true } })
  local context = machine.context

  --- Deliver one message and then behave like a quiet radio.
  ---
  --- Yielding on the second call matters: `fleet.ports`'s own receive does it,
  --- because a fake that returns instantly turns the heartbeat loop into an
  --- infinite one inside a single resume and hangs the suite rather than failing
  --- it.
  local function delivers(id, message)
    local sent = false
    context.transport.receive = function()
      if sent then
        if coroutine.isyieldable() then
          coroutine.yield()
        end
        return nil
      end
      sent = true
      return id, wire.stamp(message), "icos"
    end
  end

  local now = machine.clock.port.now()

  -- Another turtle's heartbeat, which is most of what a broadcast on this
  -- protocol is.
  delivers(7, { kind = "status", snapshot = { label = "miner-7" } })
  machine.supervisor:step()
  expect.equal(peer.address(context.peer, now), nil, "a peer's heartbeat binds nothing")

  -- The base's reply, which only the base sends.
  delivers(5, { kind = "desired", desired = { mode = "recall", generation = 1 } })
  machine.supervisor:step({ "icos_tick" })
  expect.equal(peer.address(context.peer, now), 5, "and the base's reply does")
end)
