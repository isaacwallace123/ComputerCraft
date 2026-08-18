--- Lava is a delay, not the end of a trip.
---
--- At Y -59 a fleet meets lava constantly. Refusing to mine it is correct;
--- ending the cycle over it means one pocket of lava in one rib costs a whole
--- round trip, and a permanent one costs every round trip forever.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

local GROUND = 64
local TARGET = GROUND - 8

local function newMiner(options)
  options = options or {}
  local w = scenario.new({ groundY = GROUND, x = 0, y = GROUND + 1, z = 0, facing = 0 })
  local sector = scenario.prospecting(w, {
    cellSize = 16,
    surfaceY = GROUND,
    targetY = TARGET,
    frontier = options.frontier or 0,
    trunkLength = options.trunkLength or 16,
    scanEvery = options.scanEvery,
  })
  return w, sector
end

it("a rib blocked by lava does not end the cycle", function()
  local w, sector = newMiner()
  -- Lava one block into the rib cut at the third trunk cell.
  local ribX = sector.trunkFromX + 2
  w:set(ribX, TARGET, sector.trunkZ - 1, "minecraft:lava")

  local ok, outcome = scenario.cycle(w)
  expect.truthy(ok, "cycle ran: " .. tostring(outcome))
  expect.truthy(outcome.ok, "lava must not fail the cycle: " .. tostring(outcome.reason))

  local rare = require("os.turtle.jobs.mining.rare")
  local job = rare.load()
  expect.truthy(job.frontier > 3, "the trunk carried on past the blocked rib")
  expect.equal(w:get(ribX, TARGET, sector.trunkZ - 1), "minecraft:lava", "lava was not mined")
end)

it("the trunk steps over lava in its path", function()
  local w, sector = newMiner()
  -- Lava sitting in the trunk itself, with clear rock above it.
  local blockedX = sector.trunkFromX + 4
  w:set(blockedX, TARGET, sector.trunkZ, "minecraft:lava")

  local ok, outcome = scenario.cycle(w)
  expect.truthy(ok, "cycle ran: " .. tostring(outcome))
  expect.truthy(outcome.ok, "cycle survived: " .. tostring(outcome.reason))

  local rare = require("os.turtle.jobs.mining.rare")
  local job = rare.load()
  expect.truthy(job.frontier > 5, "frontier advanced past the lava, got " .. job.frontier)
  expect.equal(w:get(blockedX, TARGET, sector.trunkZ), "minecraft:lava", "lava untouched")
end)

it("a permanently blocked trunk gives the sector up instead of retrying forever", function()
  local w, sector = newMiner()
  -- A wall of lava across the trunk and both detour routes.
  local blockedX = sector.trunkFromX + 4
  for dy = -1, 1 do
    w:set(blockedX, TARGET + dy, sector.trunkZ, "minecraft:lava")
  end

  local rare = require("os.turtle.jobs.mining.rare")
  local released = false

  for _ = 1, 5 do
    local ok, outcome = scenario.cycle(w)
    expect.truthy(ok, "cycle ran: " .. tostring(outcome))
    if require("legacy.mine.site").load().sector == 0 then
      released = true
      break
    end
    local job = rare.load()
    rare.restart(job)
    require("os.turtle.device.nav").setHome()
  end

  expect.truthy(released, "the fleet gave the sector back rather than looping")
end)

it("a vein beside lava is still followed", function()
  local w, sector = newMiner({ frontier = 0, scanEvery = 1 })
  local oreX = sector.trunkFromX + 1
  -- Ore on one side of the trunk cell, lava on the other.
  w:set(oreX, TARGET, sector.trunkZ + 1, "minecraft:deepslate_diamond_ore")
  w:set(oreX, TARGET, sector.trunkZ - 1, "minecraft:lava")
  w:set(oreX, TARGET - 1, sector.trunkZ + 1, "minecraft:deepslate_diamond_ore")

  local ok, outcome = scenario.cycle(w)
  expect.truthy(ok, "cycle ran: " .. tostring(outcome))
  expect.truthy(outcome.ok, "cycle survived lava beside ore: " .. tostring(outcome.reason))
  local haul = require("os.turtle.jobs.mining.rare").load().haul or {}
  expect.truthy((haul["minecraft:deepslate_diamond_ore"] or 0) >= 1, "the diamonds were taken")
  expect.equal(w:get(oreX, TARGET, sector.trunkZ - 1), "minecraft:lava", "lava untouched")
end)

it("a turtle that can make no progress at all eventually parks", function()
  local w, sector = newMiner()
  -- Lava wrapped around the shaft head's own column at depth: the turtle can
  -- reach the sector but can never work it.
  for dx = -1, 1 do
    for dz = -1, 1 do
      w:set(sector.shaftX + dx, TARGET, sector.shaftZ + dz, "minecraft:lava")
    end
  end

  local rare = require("os.turtle.jobs.mining.rare")
  local parked = false
  for _ = 1, 6 do
    local ok, outcome = scenario.cycle(w)
    expect.truthy(ok, "cycle ran: " .. tostring(outcome))
    if not outcome.ok then
      parked = true
      break
    end
    local job = rare.load()
    rare.restart(job)
    require("os.turtle.device.nav").setHome()
  end

  expect.truthy(parked, "repeated no-progress cycles must stop, not loop")
end)
