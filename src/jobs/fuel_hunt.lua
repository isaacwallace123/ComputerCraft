local factory = require("jobs.prospecting.factory")

return factory.create({
  name = "fuel",
  label = "Coal and fuel hunting",
  path = ".fuel-hunt",
  profile = "fuel",
  targetY = 96,
  -- Coal seams are small and common. A large budget would spend the whole trip
  -- on one seam when the point of this job is to cover ground and come back
  -- with a tank, not to strip a single vein.
  veinBudget = 96,
  description = "Targets coal veins and keeps the fuel aboard for future cycles.",
})
