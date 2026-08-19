local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local bridge = require("os.server.services.bridge")
local osBoot = require("os.kernel.boot")
local roles = require("os.kernel.roles")
local server = require("os.server.main")

local fakeClock = fleet.clock
local fakePorts = fleet.ports
local legacy = fleet.legacy

---------------------------------------------------------------------------
-- Booting one
---------------------------------------------------------------------------

it("a server boots its services and reports healthy", function()
  local clock = fakeClock(0)
  local ports = fakePorts(clock)
  local machine = server.boot(ports)

  machine.supervisor:step()
  expect.truthy(machine.supervisor:healthy(), "healthy")
  expect.equal(machine.supervisor:running(), #server.services(), "with everything running")

  local health = machine.supervisor:health()
  expect.equal(health[1].id, "discovery", "discovery among them")
  expect.truthy(health[1].critical, "and marked critical, because a deaf server is not a server")
end)

it("booting opens the radio, because nothing else was going to", function()
  -- `adapters/cc/transport.lua` declines to open a modem on construction, so
  -- that a missing one is a setup problem with a message rather than messages
  -- quietly going nowhere. For a while nothing called `open` either, which
  -- produced the very outcome that rule exists to prevent: every send returning
  -- false and every receive timing out, on a server reporting itself healthy.
  local opened = false
  local ports = fakePorts(fakeClock(0))
  ports.transport.open = function()
    opened = true
    return true
  end

  local machine = osBoot.machine({ role = "server" }, { ports = ports })
  expect.truthy(machine, "booted")
  expect.truthy(opened, "and the radio was opened")
end)

it("a turtle boots with an engine, so it does not silently never mine", function()
  -- `runJob` defaults to a function that does nothing, so a turtle wired by
  -- nobody heartbeats, obeys recall, and never moves - which looks identical
  -- from the base to a turtle that is working. The wiring is what stops that
  -- being the default, and `when` is what stops it firing on a caller that
  -- brought its own.
  local built = false
  local previous = osBoot.WIRING[roles.TURTLE]
  osBoot.WIRING[roles.TURTLE] = {
    when = "runJob",
    build = function()
      built = true
      return { runJob = function() end, runControls = function() end }
    end,
  }

  local ports = fakePorts(fakeClock(0))
  osBoot.machine({ role = "turtle" }, { ports = ports, snapshot = function() end })
  expect.truthy(built, "the engine was built")

  built = false
  osBoot.machine({ role = "turtle" }, {
    ports = fakePorts(fakeClock(0)),
    snapshot = function() end,
    runJob = function() end,
    runControls = function() end,
  })
  expect.falsy(built, "and not built for a caller that brought its own")

  osBoot.WIRING[roles.TURTLE] = previous
end)

it("a machine with no modem still boots, and says so", function()
  -- D004 as hardware: a turtle with no radio keeps mining. Refusing to boot
  -- would turn a missing peripheral into a machine that cannot be used to
  -- diagnose the missing peripheral.
  local ports = fakePorts(fakeClock(0))
  ports.transport.open = function()
    return false, "no modem attached"
  end

  -- `wire = false`: this is a question about the radio, not the arms. Without it
  -- the turtle's engine would be built, and an ICOS 1 context wants a real
  -- terminal and a real `turtle` global.
  local machine = osBoot.machine({ role = "turtle" }, { ports = ports, wire = false })
  expect.truthy(machine, "booted anyway")
end)

it("a server makes itself findable under the name ICOS 1 devices look for", function()
  -- Heartbeats are broadcast and arrive without this. Everything *addressed*
  -- does not: an unupgraded Pocket controller resolves `base` for every
  -- authoritative request and reports the base offline when nothing answers.
  local clock = fakeClock(0)
  local ports = fakePorts(clock)
  local machine = server.boot(ports)
  machine.supervisor:step()

  local found = nil
  for _, entry in ipairs(ports.hosted) do
    if entry.name == bridge.HOSTNAME and entry.protocol == bridge.PROTOCOL then
      found = entry
    end
  end
  expect.truthy(found, "hosted on the ICOS 1 protocol")
end)

it("the bridge still answers to the name ICOS 1 devices call", function()
  -- This used to compare against `legacy/net.lua`, which is deleted. The
  -- constant did not stop mattering when the file did: it is fixed by what is
  -- **installed on the turtles**, not by anything in this repository, and every
  -- device still running ICOS 1 looks up "base" on "ccfleet".
  --
  -- So it is asserted as a literal now, which is the honest form. Changing
  -- either value is not a rename - it is a deployment that has to reach every
  -- device first, and a test that compared two files in one repo would have
  -- said nothing about that.
  expect.equal(bridge.HOSTNAME, "base", "the hostname deployed turtles resolve")
  expect.equal(bridge.PROTOCOL, "ccfleet", "on the protocol they speak")
end)

it("a server with no saved state starts empty rather than refusing", function()
  local clock = fakeClock(0)
  local machine = server.boot(fakePorts(clock))

  expect.truthy(machine.state.fleet, "a registry")
  expect.truthy(machine.state.depots, "and a drop-off list")
  expect.equal(#machine.state.depots.depots, 0, "both empty")
end)

it("state is written to separate files, so a busy one cannot corrupt a quiet one", function()
  -- The registry changes on every heartbeat and the drop-off list perhaps
  -- monthly. One file would mean rewriting the depots ten times a minute.
  local clock = fakeClock(0)
  local ports = fakePorts(clock)
  local machine = server.boot(ports)

  server.save(ports, machine.state)
  expect.truthy(ports.files[server.PATHS.fleet], "the registry has its own file")
  expect.truthy(ports.files[server.PATHS.depots], "and so do the depots")
  expect.falsy(server.PATHS.fleet == ".fleet", "and neither is the ICOS 1 roster")
end)
