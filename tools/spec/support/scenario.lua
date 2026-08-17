--- Building a turtle in a world, and rebooting it.
---
--- Order matters and is the whole reason this is not inline: every ICOS module
--- reads its persisted state at require time, so the world has to be installed
--- before the first `require` and the module cache has to be dropped between
--- runs. Getting that backwards produces tests that pass for the wrong reason.

local world = require("support.world")

local scenario = {}

--- Fresh world, fresh modules.
function scenario.new(options)
  local created = world.new(options)
  created:install()
  world.reboot()
  return created
end

--- Same world and same files, fresh modules. This is a reboot.
function scenario.reboot(existing)
  existing:install()
  world.reboot()
  return existing
end

--- Run `body`, reporting a simulated power loss as a normal outcome rather than
--- a test failure. Returns ok, error.
function scenario.survive(body)
  local ok, err = pcall(body)
  if ok then
    return true
  end
  if tostring(err):find(world.POWER_LOSS, 1, true) then
    return false, "power"
  end
  return false, tostring(err)
end

--- A minimal prospecting job table pointed at one sector of a real mine plan.
function scenario.mine(created, options)
  options = options or {}
  local plan = require("mine.plan")
  local normalised = plan.normalise({
    configured = true,
    centreX = options.centreX or 0,
    centreZ = options.centreZ or 0,
    surfaceY = options.surfaceY or created.groundY,
    cellSize = options.cellSize or 48,
    maxRing = 3,
    minRing = 1,
  })
  local sector = assert(plan.sector(normalised, options.sector or 1), "sector is outside the plan")
  return normalised, sector
end

--- Set a turtle up mid-mine: home over a chest, a real Rare job file written
--- against a real sector, and vein following turned off so a surface test is
--- about the surface. Returns the sector so the caller can inspect its shaft.
---
--- The job file is written through `core.config` and read back through the real
--- `jobs.rare` loader, so migration behaviour is exercised rather than bypassed.
function scenario.prospecting(created, options)
  options = options or {}
  local config = require("core.config")
  local nav = require("turtle.nav")
  local plan = require("mine.plan")
  local rare = require("jobs.rare")

  local normalised, sector = scenario.mine(created, options)
  local targetY = options.targetY or (created.groundY - 8)
  local trunkLength = options.trunkLength or sector.trunkLength

  created:set(created.x, created.y - 1, created.z, "minecraft:chest")
  nav.setOrigin(created.x, created.y, created.z, created.facing)

  config.save(rare.PATH, {
    targetY = targetY,
    surfaceY = normalised.surfaceY,
    veinBudget = 64,
    veinRadius = 8,
    veinGapBudget = 4,
    scanEvery = options.scanEvery or 10000,
    extraPatterns = {},
    sector = sector.index,
    frontier = options.frontier or trunkLength,
    shaftX = sector.shaftX,
    shaftZ = sector.shaftZ,
    laneY = plan.laneY(normalised, sector.index),
    trunkZ = sector.trunkZ,
    trunkFromX = sector.trunkFromX,
    trunkToX = sector.trunkToX,
    trunkLength = trunkLength,
    ribReachLow = sector.ribReachLow,
    ribReachHigh = sector.ribReachHigh,
    branchSpacing = normalised.branchSpacing,
    phase = options.phase or "travel",
    returnViaShaft = options.returnViaShaft or false,
    access = options.access,
    haul = {},
    delivered = 0,
    active = true,
    startedAt = 0,
  })

  -- `workKey` is what `site.claim` would have written. Without it the turtle's
  -- own progress reports do not match its cached claim and are silently ignored.
  config.save(require("mine.site").PATH, {
    plan = normalised,
    sector = sector.index,
    frontier = 0,
    workKey = ("rare@%d"):format(targetY),
  })
  return sector, normalised
end

--- A recording job context. `phases` is every phase the job reported, in order.
function scenario.context(options)
  options = options or {}
  local recorded = { phases = {}, details = {} }
  local calls = 0
  return {
    report = function(phase, detail)
      recorded.phases[#recorded.phases + 1] = phase
      recorded.details[#recorded.details + 1] = tostring(detail or "")
    end,
    aborted = function()
      calls = calls + 1
      if options.recallAfter and calls >= options.recallAfter then
        return "recalled by base"
      end
      return nil
    end,
  },
    recorded
end

--- Run one Rare cycle, rebooting through any simulated power loss until it
--- finishes. Returns ok, result-or-error, reboot count.
function scenario.cycle(created, options)
  options = options or {}
  local reboots = 0

  while true do
    local rare = require("jobs.rare")
    local job = rare.load()
    local ctx = options.ctx or scenario.context()
    local outcome = {}
    local ok, err = scenario.survive(function()
      outcome.ok, outcome.reason, outcome.kind = rare.run(job, ctx)
    end)

    if ok then
      return true, outcome, reboots
    end
    if err ~= "power" then
      return false, err, reboots
    end

    reboots = reboots + 1
    if reboots > (options.maxReboots or 30) then
      return false, "kept losing power", reboots
    end
    scenario.reboot(created)
  end
end

return scenario
