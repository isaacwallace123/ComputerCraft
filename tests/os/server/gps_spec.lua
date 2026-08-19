local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local gpsService = require("os.server.services.gps")
local server = require("os.server.main")

local fakeClock = fleet.clock
local fakePorts = fleet.ports

---------------------------------------------------------------------------
-- GPS: the one service that must never be confidently wrong
---------------------------------------------------------------------------

it("the beacon serves what setup wrote down, never a GPS fix", function()
  -- A host announcing the wrong position makes `gps.locate` return a confident
  -- number, and a turtle that believes it is thirty blocks from where it is
  -- drives into a wall and keeps going. Serving a fix would also let a
  -- constellation bootstrap off its own error.
  local ctx = {
    locator = {
      saved = function()
        return { x = 10, y = 64, z = -3 }
      end,
      gps = function()
        return 999, 999, 999
      end,
    },
  }
  local position = assert(gpsService.position(ctx))
  expect.equal(position.x, 10, "from the saved record")
  expect.equal(position.z, -3, "and not from the constellation")
end)

it("a half-written position is refused with something a person can act on", function()
  local ctx = {
    locator = {
      saved = function()
        return { x = 10, z = -3 }
      end,
    },
  }
  local position, reason = gpsService.position(ctx)
  expect.falsy(position, "no position")

  -- It used to say "run `where set`", which was not a command that existed
  -- anywhere - the message named a fix nobody could carry out, on the one
  -- service whose failure stops the whole fleet navigating. `commands/locate.lua`
  -- is now that command, so the sentence points at something real.
  expect.contains(reason, "locate", "and it names a command that exists")
end)

it("a server with no wireless modem says so and reports unhealthy", function()
  -- A service that is running and doing nothing is the worst of the three
  -- states: the health page would show green while nothing in the world could
  -- get a fix.
  local clock = fakeClock(0)
  local machine = server.boot(fakePorts(clock, { modem = false }))

  for _ = 1, 8 do
    machine.supervisor:step()
    clock.advance(60)
  end

  local healthy, why = machine.supervisor:healthy()
  expect.falsy(healthy, "not healthy")
  expect.contains(why, "gps", "and it names the service")
  expect.contains(machine.context.gpsReason, "wireless", "with the reason on the context")
end)
