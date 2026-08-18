local factory = require("jobs.prospecting.factory")

return factory.create({
  name = "resources",
  label = "Common resource mining",
  path = ".resources",
  profile = "resources",
  targetY = 16,
  -- Create needs andesite by the thousand, and 1.20 large ore veins run to
  -- dozens of blocks. The old 48-block cap is what left half-mined iron behind.
  veinBudget = 384,
  veinRadius = 32,
  description = "Targets iron, copper, zinc, and andesite veins.",
})
