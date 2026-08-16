local factory = require("jobs.prospecting.factory")

return factory.create({
  name = "rare",
  label = "Rare ore prospecting",
  path = ".expedition",
  profile = "rare",
  distance = 100,
  targetY = -59,
  tunnelLength = 64,
  branchLength = 16,
  description = "Targets diamonds, redstone, emeralds, and non-common modded ores.",
})
