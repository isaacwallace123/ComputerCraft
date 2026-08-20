--- What is planted, when it is ready, and what replants it.
---
--- Pure knowledge about Minecraft blocks, with no turtle anywhere near it. A
--- farming job asks "is this ready?" and "what do I put back?" and this answers
--- both from a table, which is why the interesting decisions in a farm can be
--- checked without a world.
---
--- ## Maturity is an age, and the age is not the same for every crop
---
--- Verified against the wiki rather than remembered: wheat, carrots and potatoes
--- run `age` 0-7 and are ripe at 7; beetroot runs 0-3 and is ripe at 3, as does
--- nether wart. A single hard-coded 7 would leave a beetroot field being walked
--- over forever and never harvested, and a single hard-coded 3 would harvest
--- wheat at less than half growth - which looks like the farm working, because
--- it does produce something.
---
--- ## An unknown crop is never harvested
---
--- The direction of the failure matters more than the failure. `mature` returns
--- false for anything not in the table, so a modded crop or one added by a
--- future version is walked past and left alone. The cost is a crop that does
--- not get farmed, which somebody notices and fixes; the alternative is a field
--- of seedlings destroyed at age 0, which they notice after it has happened.
---
--- ## Stems are deliberately absent
---
--- Melon and pumpkin grow a *fruit block* beside a stem rather than ripening in
--- place, so harvesting them is a different motion - find the fruit, not check
--- the age - and putting them in this table would make `mature` true for a stem
--- that has nothing to give. They belong in a second job, not a bigger table.

local crops = {}

--- Every crop this fleet knows how to farm.
---
--- `mature` is the `age` blockstate at which the crop is ready. `seed` is the
--- item that replants it, which for carrots and potatoes is the crop itself -
--- there is no separate seed item, and a farm that looked for
--- `minecraft:carrot_seeds` would find nothing and stop replanting.
crops.CROPS = {
  ["minecraft:wheat"] = { mature = 7, seed = "minecraft:wheat_seeds" },
  ["minecraft:carrots"] = { mature = 7, seed = "minecraft:carrot" },
  ["minecraft:potatoes"] = { mature = 7, seed = "minecraft:potato" },
  ["minecraft:beetroots"] = { mature = 3, seed = "minecraft:beetroot_seeds" },
  ["minecraft:nether_wart"] = { mature = 3, seed = "minecraft:nether_wart" },
}

--- What a crop can be planted on.
---
--- Checked before planting rather than assumed, because a turtle that places a
--- seed on dirt drops the seed as an item and moves on - so the row silently
--- stops being a farm and the only evidence is a slowly emptying seed stack.
crops.SOIL = {
  ["minecraft:farmland"] = {
    "minecraft:wheat",
    "minecraft:carrots",
    "minecraft:potatoes",
    "minecraft:beetroots",
  },
  ["minecraft:soul_sand"] = { "minecraft:nether_wart" },
}

--- Is this block a crop we know?
function crops.known(name)
  return crops.CROPS[name] ~= nil
end

--- Is this block ready to harvest?
---
--- `block` is what `turtle.inspectDown` returns: `{ name, state, tags }`. A
--- missing state, a missing age, or an unknown block are all "no", because every
--- one of them means the same thing here - we cannot tell, so leave it growing.
function crops.mature(block)
  if type(block) ~= "table" then
    return false
  end
  local entry = crops.CROPS[block.name]
  if entry == nil then
    return false
  end
  local age = block.state and block.state.age
  if type(age) ~= "number" then
    return false
  end
  return age >= entry.mature
end

--- How far along a crop is, 0 to 1, or nil if we cannot tell.
---
--- For the status line. A farm that says "walking row 3" tells somebody nothing;
--- one that says "row 3, 40% grown" tells them whether to come back in five
--- minutes or an hour.
function crops.progress(block)
  if type(block) ~= "table" then
    return nil
  end
  local entry = crops.CROPS[block.name]
  local age = block.state and block.state.age
  if entry == nil or type(age) ~= "number" then
    return nil
  end
  return math.min(1, math.max(0, age / entry.mature))
end

--- What replants this crop.
function crops.seedFor(name)
  local entry = crops.CROPS[name]
  return entry and entry.seed or nil
end

--- Is this item a seed for something we farm?
---
--- What the inventory rule is built from: a farming turtle keeps its seeds and
--- delivers everything else. Without this it would either deliver the seeds -
--- and stop being able to replant - or keep the harvest, and fill up in one pass.
function crops.isSeed(itemName)
  for _, entry in pairs(crops.CROPS) do
    if entry.seed == itemName then
      return true
    end
  end
  return false
end

--- Can this crop be planted on this block?
function crops.plantableOn(soilName, cropName)
  local allowed = crops.SOIL[soilName]
  if allowed == nil then
    return false
  end
  for _, name in ipairs(allowed) do
    if name == cropName then
      return true
    end
  end
  return false
end

--- Every seed this fleet plants, for a setup picker.
function crops.seeds()
  local out = {}
  for _, entry in pairs(crops.CROPS) do
    out[#out + 1] = entry.seed
  end
  table.sort(out)
  return out
end

return crops
