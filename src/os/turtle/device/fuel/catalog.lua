--- The only fuels this fleet burns, and what a turtle gets for one.
---
--- Deliberately a closed list rather than "whatever the game will burn".
--- `turtle.refuel(0)` reports a stick, a sapling, an oak plank, a wooden shovel
--- and a bamboo shoot as fuel, and a prospecting turtle cutting down through a
--- canopy picks up all of those. Anything counted as fuel is retained at every
--- unload, so tree litter accumulated in slots that ore should have been in and
--- never left the turtle again.
---
--- Coal and charcoal, loose and in block form. Nothing else.

local catalog = {}

--- Exact names with a known value, in turtle moves.
---
--- Only the vanilla ids get a number. A modded charcoal block is accepted and
--- burnable, but its burn time is the mod's business, and guessing high is the
--- dangerous direction: a turtle that over-counts its range strands itself.
--- Unvalued fuel contributes zero until this turtle has actually burned one and
--- measured it.
local VALUES = {
  ["minecraft:coal"] = 80,
  ["minecraft:charcoal"] = 80,
  ["minecraft:coal_block"] = 800,
}

--- Item ids, namespace stripped, so a modded coal or charcoal block counts
--- without every mod having to be listed.
local ACCEPTED = {
  coal = true,
  charcoal = true,
  coal_block = true,
  charcoal_block = true,
  block_of_coal = true,
  block_of_charcoal = true,
}

local function bareId(name)
  name = tostring(name)
  return name:match("[^:]+$") or name
end

--- May this item be burned, and kept aboard for burning later?
function catalog.accepts(name)
  return ACCEPTED[bareId(name)] == true
end

function catalog.value(name)
  return VALUES[tostring(name)]
end

return catalog
