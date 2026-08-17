--- Fuel is a closed list, and canopy litter is not on it.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

it("only coal and charcoal count as fuel", function()
  scenario.new({ groundY = 64 })
  local fuel = require("turtle.fuel")

  local function burns(name)
    return fuel.isFuel({ name = name, count = 1 }, 1)
  end

  expect.truthy(burns("minecraft:coal"), "coal")
  expect.truthy(burns("minecraft:charcoal"), "charcoal")
  expect.truthy(burns("minecraft:coal_block"), "coal block")
  expect.truthy(burns("thermal:charcoal_block"), "a modded charcoal block")
  expect.truthy(burns("somemod:block_of_coal"), "a modded coal block")

  -- Everything below burns in a furnace, and turtle.refuel(0) used to say yes.
  expect.falsy(burns("minecraft:stick"), "sticks")
  expect.falsy(burns("minecraft:oak_sapling"), "saplings")
  expect.falsy(burns("minecraft:oak_planks"), "planks")
  expect.falsy(burns("minecraft:oak_log"), "logs")
  expect.falsy(burns("minecraft:bamboo"), "bamboo")
  expect.falsy(burns("minecraft:wooden_shovel"), "wooden tools")
  expect.falsy(burns("minecraft:lava_bucket"), "lava buckets")
  expect.falsy(burns("minecraft:blaze_rod"), "blaze rods")
  expect.falsy(burns("minecraft:dried_kelp_block"), "dried kelp")
end)

it("an unknown accepted fuel counts as zero until it has been burned", function()
  local w = scenario.new({ groundY = 64, fuel = 0 })
  local fuel = require("turtle.fuel")

  w:give(1, "minecraft:coal", 3)
  expect.equal(fuel.inventoryPotential(), 240, "vanilla coal is counted exactly")

  w:give(2, "modpack:charcoal_block", 2)
  expect.equal(
    fuel.inventoryPotential(),
    240,
    "a modded block with no known burn time counts zero rather than guessing high"
  )
end)

it("canopy litter is dropped rather than hauled home", function()
  scenario.new({ groundY = 64 })
  local ore = require("turtle.ore")
  local isJunk = ore.junkMatcher({})

  expect.truthy(isJunk("minecraft:stick"), "sticks")
  expect.truthy(isJunk("minecraft:oak_sapling"), "saplings")
  expect.truthy(isJunk("minecraft:apple"), "apples")
  expect.truthy(isJunk("minecraft:wheat_seeds"), "seeds")
  expect.truthy(isJunk("minecraft:oak_leaves"), "leaves")

  -- The substring these would have been caught by takes something real with it.
  expect.falsy(isJunk("minecraft:sticky_piston"), "sticky pistons are not sticks")
  expect.falsy(isJunk("minecraft:golden_apple"), "golden apples are not apples")

  expect.falsy(isJunk("minecraft:coal"), "fuel is never dropped")
  expect.falsy(isJunk("minecraft:charcoal"), "charcoal is never dropped")
  expect.falsy(isJunk("minecraft:diamond"), "the haul is never dropped")
end)

it("tree litter picked up on the way down does not survive a cycle", function()
  local w = scenario.new({ groundY = 64, x = 0, y = 65, z = 0, facing = 0 })
  local sector = scenario.prospecting(w, { cellSize = 16, surfaceY = 64, targetY = 56 })

  -- A tree standing over the sector's shaft, exactly what the descent cuts.
  for y = 65, 70 do
    w:set(sector.shaftX, y, sector.shaftZ, "minecraft:oak_log")
  end
  w:fill(
    sector.shaftX - 1,
    71,
    sector.shaftZ - 1,
    sector.shaftX + 1,
    71,
    sector.shaftZ + 1,
    "minecraft:oak_leaves"
  )

  local ok, outcome = scenario.cycle(w)
  expect.truthy(ok, "cycle ran: " .. tostring(outcome))
  expect.truthy(outcome.ok, "cycle succeeded: " .. tostring(outcome.reason))

  expect.equal(w:count("minecraft:oak_sapling"), 0, "no saplings aboard")
  expect.equal(w:count("minecraft:stick"), 0, "no sticks aboard")
  expect.equal(w:count("minecraft:oak_leaves"), 0, "no leaves aboard")
end)

it("a rare-ore trip keeps ore and metal and nothing else", function()
  scenario.new({ groundY = 64 })
  local rare = require("jobs.rare")
  local isJunk = rare.junkMatcher(rare.load())

  -- Everything that came home in the chest and should not have.
  expect.truthy(isJunk("minecraft:cobblestone"), "cobblestone")
  expect.truthy(isJunk("minecraft:cobbled_deepslate"), "deepslate")
  expect.truthy(isJunk("minecraft:dirt"), "dirt")
  expect.truthy(isJunk("minecraft:clay_ball"), "clay")
  expect.truthy(isJunk("minecraft:oak_log"), "wood")
  expect.truthy(isJunk("minecraft:oak_planks"), "planks")
  expect.truthy(isJunk("minecraft:moss_block"), "moss")
  expect.truthy(isJunk("minecraft:grass_block"), "grass")
  expect.truthy(isJunk("minecraft:gravel"), "gravel")
  expect.truthy(isJunk("minecraft:andesite"), "andesite")
  expect.truthy(isJunk("minecraft:tuff"), "tuff")
  expect.truthy(isJunk("minecraft:snowball"), "snowballs")

  -- What the trip is actually for.
  expect.falsy(isJunk("minecraft:diamond"), "diamonds")
  expect.falsy(isJunk("minecraft:emerald"), "emeralds")
  expect.falsy(isJunk("minecraft:redstone"), "redstone")
  expect.falsy(isJunk("minecraft:lapis_lazuli"), "lapis")
  expect.falsy(isJunk("minecraft:raw_iron"), "raw iron")
  expect.falsy(isJunk("minecraft:raw_gold"), "raw gold")
  expect.falsy(isJunk("minecraft:iron_ingot"), "ingots")
  expect.falsy(isJunk("minecraft:ancient_debris"), "ancient debris")
  expect.falsy(isJunk("minecraft:amethyst_shard"), "amethyst")
  expect.falsy(isJunk("mekanism:raw_osmium"), "a modded raw metal")
  expect.falsy(isJunk("thermal:sulfur_dust"), "a modded dust")
  expect.falsy(isJunk("minecraft:coal"), "fuel is never dropped")
end)

it("the resources profile keeps its conservative haul policy", function()
  scenario.new({ groundY = 64 })
  local resources = require("jobs.resources")
  local isJunk = resources.junkMatcher(resources.load())

  expect.truthy(isJunk("minecraft:cobblestone"), "still drops cobble")
  expect.falsy(isJunk("minecraft:andesite"), "but keeps the andesite it went for")
  expect.falsy(isJunk("somemod:mystery_widget"), "and unknown drops still come home")
end)
