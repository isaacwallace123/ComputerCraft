--- Surface access primitives: classification, cap material, verified placement.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

local function anyOre(name)
  return tostring(name):find("_ore", 1, true) ~= nil
end

it("access classifies ground, canopy, liquid, and protected blocks", function()
  local w = scenario.new({ groundY = 64, x = 0, y = 70, z = 0 })
  local access = require("device.access")

  local cases = {
    { "minecraft:grass_block", "solid" },
    { "minecraft:stone", "solid" },
    { "minecraft:oak_leaves", "soft" },
    { "minecraft:oak_log", "soft" },
    { "minecraft:grass", "soft" }, -- the 1.20.1 tuft, not the ground
    { "minecraft:short_grass", "soft" },
    { "minecraft:snow", "soft" },
    { "minecraft:water", "liquid" },
    { "minecraft:lava", "liquid" },
    { "minecraft:chest", "protected" },
    { "computercraft:turtle_advanced", "protected" },
  }

  for _, case in ipairs(cases) do
    w:set(0, 69, 0, case[1])
    expect.equal(access.below(), case[2], case[1])
  end

  w:set(0, 69, 0, nil)
  expect.equal(access.below(), "air", "air")
end)

it("access refuses valuable, gravity, and wanted blocks as cap material", function()
  scenario.new({ groundY = 64 })
  local access = require("device.access")

  local function filler(name)
    return access.isFiller({ name = name, count = 1 }, 1, anyOre)
  end

  expect.truthy(filler("minecraft:cobblestone"), "cobblestone is filler")
  expect.truthy(filler("minecraft:dirt"), "dirt is filler")
  expect.truthy(filler("minecraft:cobbled_deepslate"), "cobbled deepslate is filler")

  expect.falsy(filler("minecraft:sand"), "sand falls and would reopen the hole")
  expect.falsy(filler("minecraft:gravel"), "gravel falls")
  expect.falsy(filler("minecraft:redstone"), "redstone is not rubble")
  expect.falsy(filler("minecraft:diamond"), "diamonds are not rubble")
  expect.falsy(filler("minecraft:coal"), "coal is fuel")
  expect.falsy(filler("minecraft:iron_ore"), "the profile wants ore")
  expect.falsy(filler("minecraft:oak_leaves"), "leaves are not a floor")
end)

it("access moves filler into the reserved slot and restores the selection", function()
  local w = scenario.new({ groundY = 64 })
  w:give(3, "minecraft:cobblestone", 12)
  w:give(1, "minecraft:diamond", 2)
  local access = require("device.access")

  local turtleApi = _ENV.turtle
  turtleApi.select(1)
  expect.truthy(access.reserve(anyOre), "reserve finds the cobblestone")
  expect.equal(turtleApi.getItemCount(access.SLOT), 12, "cobblestone is in the cap slot")
  expect.equal(turtleApi.getSelectedSlot(), 1, "selection restored")
  expect.equal(w:count("minecraft:diamond"), 2, "haul untouched")
end)

it("access reports a placement only once the block is observed", function()
  local w = scenario.new({ groundY = 64, x = 0, y = 70, z = 0 })
  local access = require("device.access")

  -- Nothing to place with.
  local placed, reason = access.capUp()
  expect.falsy(placed, "cannot cap with an empty inventory")
  expect.contains(reason, "refused", "says the placement was refused")

  w:give(access.SLOT, "minecraft:cobblestone", 4)
  expect.truthy(access.capUp(), "caps with cobblestone")
  expect.equal(w:get(0, 71, 0), "minecraft:cobblestone", "block really is there")

  -- An unplaceable item must not be reported as a successful cap.
  w:set(0, 71, 0, nil)
  w.inventory[access.SLOT] = { name = "minecraft:clay_ball", count = 4 }
  local faked, fakeReason = access.capUp()
  expect.falsy(faked, "clay balls are not a cap")
  expect.contains(fakeReason, "refused", "reports the refusal")
  expect.equal(w:get(0, 71, 0), nil, "nothing was placed")
end)

it("access recognises an enclosed shaft column", function()
  local w = scenario.new({ groundY = 64, x = 0, y = 64, z = 0 })
  local access = require("device.access")

  -- Standing at ground level inside a one-block hole: walls on all four sides.
  w:set(0, 64, 0, nil)
  expect.truthy(access.enclosed(), "walls all round")

  w:set(1, 64, 0, nil)
  expect.falsy(access.enclosed(), "one side open is not a shaft")
end)

it("access clears a cap that gravel keeps refilling", function()
  local w = scenario.new({ groundY = 64, x = 0, y = 60, z = 0 })
  local access = require("device.access")
  w:set(0, 61, 0, "minecraft:cobblestone")

  expect.truthy(access.clearUp(), "cap removed")
  expect.equal(w:get(0, 61, 0), nil, "gap is open")
  expect.equal(w:count("minecraft:cobblestone"), 1, "the cap block came back aboard")
end)
