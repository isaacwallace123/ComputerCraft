local factory = require("jobs.prospecting.factory")

return factory.create({
  name = "resources",
  label = "Common resource mining",
  path = ".resources",
  profile = "resources",
  distance = 64,
  targetY = 16,
  tunnelLength = 64,
  branchLength = 16,
  description = "Targets iron, copper, zinc, and andesite veins.",
})
