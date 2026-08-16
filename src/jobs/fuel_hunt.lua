local factory = require("jobs.prospecting.factory")

return factory.create({
  name = "fuel",
  label = "Coal and fuel hunting",
  path = ".fuel-hunt",
  profile = "fuel",
  distance = 48,
  targetY = 96,
  cruise = 40,
  tunnelLength = 64,
  branchLength = 16,
  veinBudget = 96,
  description = "Targets coal veins and keeps the fuel aboard for future cycles.",
})
