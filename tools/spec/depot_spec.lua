--- Unloading, and flying over terrain instead of through it.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

local GROUND = 64

it("depot overflows into neighbouring containers before reporting full", function()
  local w = scenario.new({ groundY = GROUND, x = 0, y = GROUND + 1, z = 0, facing = 0 })
  local depot = require("device.depot")
  local fuel = require("device.fuel")

  w:set(0, GROUND, 0, "minecraft:chest")
  w.chests["0,64,0"] = { capacity = 4, stored = 0 }
  -- A second chest in front of the home block. Heading 0 faces -z.
  w:set(0, GROUND + 1, -1, "minecraft:barrel")
  w.chests["0,65,-1"] = { capacity = 100, stored = 0 }

  w:give(1, "minecraft:diamond", 10)
  w:give(2, "minecraft:coal", 8)

  local delivered, remaining, used = depot.unload(function(detail, slot)
    return fuel.isFuel(detail, slot)
  end)

  expect.equal(delivered, 10, "everything non-fuel was delivered")
  expect.equal(remaining, 0, "nothing left aboard")
  expect.equal(#used, 2, "both containers were used")
  expect.equal(w.chests["0,64,0"].stored, 4, "home chest filled first")
  expect.equal(w.chests["0,65,-1"].stored, 6, "the rest overflowed")
  expect.equal(w:count("minecraft:coal"), 8, "fuel stayed aboard")
end)

it("depot never drops a haul into open air", function()
  local w = scenario.new({ groundY = GROUND, x = 0, y = GROUND + 4, z = 0, facing = 0 })
  local depot = require("device.depot")
  w:give(1, "minecraft:diamond", 5)

  local delivered, remaining = depot.unload(function()
    return false
  end)

  expect.equal(delivered, 0, "nothing delivered with no container")
  expect.equal(remaining, 5, "the haul is still aboard")
  expect.equal(w:count("minecraft:diamond"), 5, "not scattered on the floor")
end)

it("travel flies over a hill instead of tunnelling through it", function()
  local w = scenario.new({ groundY = GROUND, x = 0, y = GROUND + 1, z = 0, facing = 0 })
  local nav = require("device.nav")
  nav.setOrigin(0, GROUND + 1, 0, 0)

  -- A ridge ten blocks high across the route, with open sky above it.
  w:fill(3, GROUND + 1, -10, 3, GROUND + 10, 10, "minecraft:stone")
  local before = w.digs

  -- Cruise altitude is only four blocks up, well inside the ridge.
  expect.truthy(nav.goTo(8, 4, 0, nil, { climb = nav.CLIMB_LIMIT }), "crossed the ridge")

  expect.equal(w.digs, before, "flew over it without digging")
  expect.equal(w:get(3, GROUND + 5, 0), "minecraft:stone", "the ridge is intact")
  local x, y, z = nav.position()
  expect.equal(("%d,%d,%d"):format(x, y, z), "8,4,0", "arrived at the lane")
end)

it("travel does not climb and sink over stepped terrain", function()
  local w = scenario.new({ groundY = GROUND, x = 0, y = GROUND + 1, z = 0, facing = 0 })
  local nav = require("device.nav")
  nav.setOrigin(0, GROUND + 1, 0, 0)

  -- A staircase shoreline: ground steps up and down every couple of blocks,
  -- which is what a real coast or ravine wall looks like from the air.
  for step = 1, 12 do
    local height = GROUND + ((step % 3 == 0) and 6 or 1)
    for y = GROUND + 1, height do
      w:fill(step, y, -6, step, y, 6, "minecraft:stone")
    end
  end

  local before = w.moves
  expect.truthy(nav.goTo(14, 3, 0, nil, { climb = nav.CLIMB_LIMIT }), "crossed the steps")
  local spent = w.moves - before

  -- Fourteen forward plus one climb up and one descent back down is the honest
  -- cost. Sinking back to the lane after every step turns this into dozens.
  expect.truthy(spent <= 30, "crossing cost " .. spent .. " moves, expected no thrashing")
  expect.equal(w.digs, 0, "and nothing was dug")

  local x, y, z = nav.position()
  expect.equal(("%d,%d,%d"):format(x, y, z), "14,3,0", "arrived at the lane")
end)

it("travel still tunnels when the ground is genuinely enclosed", function()
  local w = scenario.new({ groundY = GROUND, x = 0, y = GROUND - 4, z = 0, facing = 0 })
  local nav = require("device.nav")
  nav.setOrigin(0, GROUND - 4, 0, 0)

  -- Underground: there is no sky to climb into, so digging is the only way.
  expect.truthy(nav.goTo(4, 0, 0, nil, { climb = nav.CLIMB_LIMIT }), "tunnelled")
  expect.truthy(w.digs > 0, "it had to dig")
  local x, y, z = nav.position()
  expect.equal(("%d,%d,%d"):format(x, y, z), "4,0,0", "arrived")
end)
