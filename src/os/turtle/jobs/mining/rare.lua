local factory = require("os.turtle.jobs.prospecting.factory")

return factory.create({
  name = "rare",
  label = "Rare ore prospecting",
  path = ".expedition",
  profile = "rare",
  -- A hundred blocks down for diamonds: keep ore and metal, drop the rest.
  strictHaul = true,
  targetY = -59,
  description = "Targets diamonds, redstone, emeralds, and non-common modded ores.",
})
