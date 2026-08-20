local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local gpsService = require("os.kernel.services.gps")
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
    anchored = function()
      return true
    end,
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
    anchored = function()
      return true
    end,
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

it("a machine with no wireless modem stops hosting and says why", function()
  -- This used to assert that the server reported *unhealthy*, because `gps` was
  -- critical: one machine hosted for the whole fleet, so its beacon going quiet
  -- broke navigation for everybody.
  --
  -- Every machine hosts now, so a machine that cannot is ordinary rather than a
  -- fault - a mining turtle is not a host either. Keeping it critical would make
  -- `healthy` mean nothing on every machine that moves.
  --
  -- The signal did not disappear, it moved somewhere better: `icos status`
  -- checks the radio in its preflight, above the service list, because a machine
  -- with no modem shows five services running and hears nothing and the service
  -- list is the wrong place to learn that.
  local clock = fakeClock(0)
  local machine = server.boot(fakePorts(clock, { modem = false }))

  for _ = 1, 8 do
    machine.supervisor:step()
    clock.advance(60)
  end

  expect.contains(machine.context.gpsReason, "wireless", "the reason is on the context")

  -- And the machine is still doing its job. A base with no wireless modem
  -- cannot reach a turtle, which is a real problem - but it is the radio's
  -- problem, and reporting it as a GPS failure sent people to the wrong file.
  local found = false
  for _, row in ipairs(machine.supervisor:health()) do
    if row.id == "gps" then
      expect.falsy(row.critical, "gps is not critical any more")
      found = true
    end
  end
  expect.truthy(found, "and it is still registered")
end)

it("a pocket computer never hosts, however well it knows where it is", function()
  -- The one machine whose answer is always no. It travels in an inventory at
  -- ten blocks a second with no state to check and no event to receive, so
  -- there is no condition under which its position is worth serving.
  local mobile = require("os.mobile.main")

  for _, definition in ipairs(mobile.services()) do
    expect.falsy(definition.id == "gps", "no beacon on a handheld")
  end

  -- Left out rather than registered-and-declining, deliberately: a handheld that
  -- had the service and refused would look, on the Services page, exactly like
  -- one whose modem had failed.
end)

it("a turtle hosts while parked and stops when it deploys", function()
  local host = require("domain.gps.host")

  local parked = host.mayServe({
    position = { x = 1, y = 2, z = 3 },
    anchored = true,
    modem = true,
  })
  expect.truthy(parked, "parked and located")

  local moving, why = host.mayServe({
    position = { x = 1, y = 2, z = 3 },
    anchored = false,
    why = "mining - a turtle hosts only while parked",
    modem = true,
  })
  expect.falsy(moving, "under way")
  expect.contains(why, "parked", "and it says when it will be back")
end)

it("a fix updates the position but never the heading", function()
  -- Four hosts cannot tell a turtle which way it is facing - a stationary
  -- turtle looks identical from every direction. Overwriting it would make
  -- every boot with a working constellation forget which way home is.
  local host = require("domain.gps.host")

  local merged = host.merge({ x = 0, y = 0, z = 0, facing = 2 }, { x = 10, y = 64, z = -3 })
  expect.equal(merged.x, 10, "moved")
  expect.equal(merged.facing, 2, "and still knows which way it points")
  expect.equal(merged.source, "fix", "recorded as derived")
end)

it("a fix that agrees with the record is not written back", function()
  -- A boot that rewrote .location every time would cost a disk write on every
  -- machine in the fleet for no change.
  local host = require("domain.gps.host")

  expect.falsy(host.changed({ x = 1, y = 2, z = 3 }, { x = 1, y = 2, z = 3 }), "unchanged")
  expect.truthy(host.changed({ x = 1, y = 2, z = 3 }, { x = 1, y = 2, z = 4 }), "moved")
  expect.truthy(host.changed(nil, { x = 1, y = 2, z = 3 }), "first fix")
  expect.falsy(host.changed({ x = 1, y = 2, z = 3 }, nil), "and no fix is not a change")
end)
