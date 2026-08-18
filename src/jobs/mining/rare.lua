local factory = require("jobs.prospecting.factory")

return factory.create({
  name = "rare",
  label = "Rare ore prospecting",
  path = ".expedition",
  profile = "rare",
  targetY = -59,
  description = "Targets diamonds, redstone, emeralds, and non-common modded ores.",
})
