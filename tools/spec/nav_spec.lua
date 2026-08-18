--- Navigation: dead reckoning, persistence, and refusals.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

it("nav tracks a confirmed move", function()
  scenario.new({ groundY = 64, x = 0, y = 70, z = 0 })
  local nav = require("device.nav")
  nav.setHome()

  expect.truthy(nav.forward(), "forward through air")
  local x, y, z = nav.position()
  expect.equal(x, 0, "relative x")
  expect.equal(y, 0, "relative y")
  expect.equal(z, 1, "relative z")
  expect.equal(nav.distanceHome(), 1, "distance home")
end)

it("nav world coordinates agree with the world for every heading", function()
  for heading = 0, 3 do
    local w = scenario.new({ groundY = 64, x = 10, y = 70, z = -20, facing = heading })
    local nav = require("device.nav")
    nav.setOrigin(10, 70, -20, heading)

    expect.truthy(nav.forward(), "forward")
    expect.truthy(nav.up(), "up")
    nav.turnRight()
    expect.truthy(nav.forward(), "forward after turn")

    local here = nav.worldPosition()
    expect.truthy(here, "world position is known")
    expect.equal(here and here.x, w.x, "world x for heading " .. heading)
    expect.equal(here and here.y, w.y, "world y for heading " .. heading)
    expect.equal(here and here.z, w.z, "world z for heading " .. heading)
  end
end)

it("nav position survives a reboot", function()
  local w = scenario.new({ groundY = 64, x = 0, y = 70, z = 0 })
  local nav = require("device.nav")
  nav.setOrigin(0, 70, 0, 0)
  nav.forward()
  nav.forward()
  nav.up()

  scenario.reboot(w)
  local rebooted = require("device.nav")
  local x, y, z = rebooted.position()
  expect.equal(x, 0, "x after reboot")
  expect.equal(y, 1, "y after reboot")
  expect.equal(z, 2, "z after reboot")
end)

it("nav never digs a chest or lava", function()
  -- Heading 0 is north, so the block the turtle faces is at -z.
  local w = scenario.new({ groundY = 64, x = 0, y = 70, z = 0, facing = 0 })
  w:set(0, 70, -1, "minecraft:chest")
  w:set(0, 71, 0, "minecraft:lava")
  local nav = require("device.nav")
  nav.setOrigin(0, 70, 0, 0)

  local moved, reason, kind = nav.forward()
  expect.falsy(moved, "must not enter a chest")
  expect.equal(kind, "protected", "chest is protected")
  expect.contains(reason, "chest", "reason names the block")
  expect.equal(w:get(0, 70, -1), "minecraft:chest", "chest still standing")

  local climbed, _, climbKind = nav.up()
  expect.falsy(climbed, "must not dig lava")
  expect.equal(climbKind, "hazard", "lava is a hazard")
end)

it("nav goTo reaches a target and returns home", function()
  local w = scenario.new({ groundY = 64, x = 0, y = 70, z = 0 })
  local nav = require("device.nav")
  nav.setHome()

  expect.truthy(nav.goTo(3, 2, -4), "goTo")
  local x, y, z = nav.position()
  expect.equal(("%d,%d,%d"):format(x, y, z), "3,2,-4", "arrived")

  expect.truthy(nav.goHome(), "goHome")
  expect.equal(nav.distanceHome(), 0, "home")
  expect.equal(w.y, 70, "back at the starting height")
end)
