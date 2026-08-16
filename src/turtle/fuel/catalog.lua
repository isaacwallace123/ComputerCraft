--- Vanilla fuel values in turtle moves.
---
--- CC:Tweaked converts furnace burn time into turtle fuel. Keeping the common
--- fuels here lets us account for inventory fuel without consuming it first.
--- Unknown modded fuels are still detected by turtle.refuel(0), but are not
--- counted until the running turtle has measured one.

local catalog = {}

local VALUES = {
  ["minecraft:coal"] = 80,
  ["minecraft:charcoal"] = 80,
  ["minecraft:coal_block"] = 800,
  ["minecraft:lava_bucket"] = 1000,
  ["minecraft:blaze_rod"] = 120,
  ["minecraft:dried_kelp_block"] = 200,
}

function catalog.value(name)
  return VALUES[tostring(name)]
end

return catalog
