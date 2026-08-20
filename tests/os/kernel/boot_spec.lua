local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local osBoot = require("os.kernel.boot")
local roles = require("os.kernel.roles")

local booted = fleet.booted
local scripted = fleet.scripted

it("every role has an operating system, and an unknown one says so", function()
  for _, role in ipairs({ roles.SERVER, roles.CLIENT, roles.TURTLE, roles.MOBILE }) do
    expect.truthy(osBoot.ROOTS[role], role .. " has a root")
  end

  local machine, why = osBoot.machine({}, { role = "toaster", ports = {} })
  expect.falsy(machine, "no machine")
  expect.contains(why, "toaster", "and it names the role")
end)

it("terminate reaches the services before the loop unwinds", function()
  -- pullEventRaw rather than pullEvent, so services are stopped in order
  -- rather than having the loop pulled out from under them.
  local machine = booted(roles.CLIENT)
  local outcome = osBoot.run(machine, scripted({ { "timer", 1 }, { "terminate" } }))

  expect.equal(outcome, "terminated", "stopped cleanly")
  expect.equal(machine.supervisor:running(), 0, "and nothing is left running")
end)

it("a machine whose services have all given up returns rather than spinning", function()
  -- A base sat in a loop resuming nothing looks, from across the room, exactly
  -- like a base that is working.
  local machine = booted(roles.CLIENT, {
    draw = function()
      error("no screen", 0)
    end,
  })
  machine.context.transport.broadcast = function()
    error("no modem", 0)
  end

  -- A client hosts GPS now, so "every service" is three rather than two. It
  -- stops of its own accord when the beacon will not open, which is the shape
  -- this test needs and is also the honest behaviour: a machine with no
  -- wireless modem is not a host and never will be without one being attached.
  machine.context.beacon.open = function()
    return false, "no wireless modem"
  end

  -- And the ticker, which is the fourth. It is the one service here that cannot
  -- fail by itself - it needs only a clock, and a clock does not break - so a
  -- machine with a dead screen, a dead radio and no modem would still have one
  -- coroutine alive and `boot.run` would never reach its exit.
  --
  -- Breaking it deliberately is the honest way to test "everything gave up",
  -- and it is worth knowing that the exit is only reachable when *literally*
  -- nothing is left: a machine repainting a screen nobody can see is still, by
  -- this definition, running.
  machine.context.clock.sleep = function()
    error("no clock", 0)
  end

  -- And hotplug, which is the fifth and cannot fail by itself either: it needs
  -- only an event queue, and waiting for hardware that never arrives is a
  -- service working correctly. Same reasoning as the ticker above - "everything
  -- gave up" has to mean everything, including the services whose whole job is
  -- to sit still.
  machine.context.input.pull = function()
    error("no input", 0)
  end

  local index = 0
  local outcome = osBoot.run(machine, function()
    index = index + 1
    -- Advance as it goes, so the supervisor's backoff actually elapses and both
    -- services reach "gave up" rather than sitting in "waiting" forever.
    machine.clock.advance(60)
    return index < 200 and { "timer", index } or { "terminate" }
  end)

  expect.equal(outcome, "stopped", "it stopped")
  expect.equal(machine.supervisor:running(), 0, "with nothing left running")

  -- And this is why the loop tests `running()` rather than `healthy()`. Both of
  -- a client's services are non-critical - correctly, because a client that has
  -- lost its server should keep drawing and one that has lost its monitor is a
  -- machine nobody is looking at. So a client with neither reports *healthy*
  -- while doing nothing at all, and only the running count catches it.
  expect.truthy(machine.supervisor:healthy(), "while still reporting healthy")
end)

it("the halt flag stops the machine, because a service cannot stop itself", function()
  -- A coroutine that returns is a fault, so `stop` is checked by the loop
  -- rather than acted on by the service that received it.
  local machine = booted(roles.TURTLE)
  local outcome = osBoot.run(machine, function()
    machine.context.halt = true
    return { "timer", 1 }
  end)

  expect.equal(outcome, "halted", "halted rather than terminated")
  expect.equal(machine.supervisor:running(), 0, "and everything was stopped")
end)
