--- Factory for focused, repeatable branch-mining jobs.

local config = require("core.config")
local fuel = require("turtle.fuel")
local nav = require("turtle.nav")
local ore = require("turtle.ore")
local profiles = require("jobs.prospecting.profiles")
local runner = require("jobs.prospecting.runner")

local factory = {}

local SAFETY_MARGIN = 150
local MINING_ALLOWANCE = 32

local function routeCost(job)
  local travelY = math.min(319 - job.surfaceY, math.max(job.cruise, job.targetY - job.surfaceY + 8))
  local targetY = job.targetY - job.surfaceY
  local vertical = math.abs(travelY) + math.abs(travelY - targetY)
  local outbound = math.abs(job.bearingX or 0) + math.abs(job.bearingZ or 0)
  if outbound == 0 then
    -- A diagonal route can cost sqrt(2) times the configured radial distance.
    outbound = math.ceil(job.distance * 1.415)
  end
  return outbound + vertical
end

local function copyDefaults(definition)
  return {
    distance = definition.distance,
    cruise = definition.cruise or 12,
    surfaceY = 64,
    targetY = definition.targetY,
    tunnelLength = definition.tunnelLength or 48,
    branchLength = definition.branchLength or 12,
    branchSpacing = 3,
    veinBudget = definition.veinBudget or 48,
    scanEvery = 1,
    extraPatterns = definition.extraPatterns or {},
    phase = "travel",
    bearingX = 0,
    bearingZ = 0,
    tunnelFacing = 0,
    travelY = definition.cruise or 12,
    tunnelDone = 0,
    haul = {},
    delivered = 0,
    active = false,
    startedAt = 0,
  }
end

function factory.create(definition)
  local jobType = {
    name = definition.name,
    label = definition.label,
    PATH = definition.path,
    continuous = true,
    usesSurfaceY = true,
    SAFETY_MARGIN = SAFETY_MARGIN,
    settingFields = {
      { label = "Distance", key = "distance", step = 10, min = 1, max = 1000 },
      { label = "Target Y", key = "targetY", step = 1, min = -63, max = 319 },
      { label = "Tunnel", key = "tunnelLength", step = 8, min = 1, max = 512 },
    },
  }
  local defaults = copyDefaults(definition)

  function jobType.load()
    return config.load(jobType.PATH, defaults)
  end

  function jobType.save(job)
    config.save(jobType.PATH, job)
  end

  function jobType.matcher(job)
    return profiles.matcher(definition.profile, job.extraPatterns)
  end

  function jobType.junkMatcher()
    return ore.junkMatcher(definition.profile == "resources" and { "andesite" } or {})
  end

  function jobType.estimateFuel(job)
    local ribs = math.floor(job.tunnelLength / job.branchSpacing) * job.branchLength * 4
    return 2 * routeCost(job) + job.tunnelLength + ribs + SAFETY_MARGIN
  end

  function jobType.minimumFuel(job)
    return 2 * routeCost(job) + SAFETY_MARGIN + MINING_ALLOWANCE
  end

  function jobType.progress(job)
    local x, y, z = nav.position()
    if job.phase == "travel" then
      local total = math.abs(job.bearingX) + math.abs(job.bearingZ) + job.travelY
      local done = math.abs(x) + math.abs(z) + math.max(0, y)
      return total > 0 and 0.2 * math.min(1, done / total) or 0
    elseif job.phase == "shaft" then
      return 0.2
    elseif job.phase == "mining" then
      return 0.5 + 0.45 * math.min(1, job.tunnelDone / math.max(1, job.tunnelLength))
    elseif job.phase == "home" then
      return 0.95
    end
    return 0
  end

  function jobType.ready(job)
    local needed = jobType.minimumFuel(job)
    if fuel.available() >= needed then
      return true
    end
    return false,
      ("needs %d total fuel, has %d including inventory"):format(
        needed,
        math.floor(fuel.available())
      )
  end

  function jobType.restart(job)
    math.randomseed(os.epoch("utc") + os.getComputerID() * 7919)
    local angle = math.random() * 2 * math.pi
    job.bearingX = math.floor(math.cos(angle) * job.distance + 0.5)
    job.bearingZ = math.floor(math.sin(angle) * job.distance + 0.5)
    if math.abs(job.bearingX) > math.abs(job.bearingZ) then
      job.tunnelFacing = job.bearingX >= 0 and 1 or 3
    else
      job.tunnelFacing = job.bearingZ >= 0 and 0 or 2
    end
    job.travelY = math.min(319 - job.surfaceY, math.max(job.cruise, job.targetY - job.surfaceY + 8))
    job.phase = "travel"
    job.tunnelDone = 0
    job.active = true
    job.startedAt = os.epoch("utc")
    jobType.save(job)
    return job
  end

  function jobType.status(job)
    return {
      progress = jobType.progress(job),
      haul = job.haul,
      delivered = job.delivered,
      target = job.targetY,
      settings = {
        distance = job.distance,
        targetY = job.targetY,
        tunnelLength = job.tunnelLength,
      },
    }
  end

  function jobType.configure(job, settings)
    for _, field in ipairs(jobType.settingFields) do
      if settings[field.key] ~= nil then
        local value = tonumber(settings[field.key])
        if not value then
          return false, field.key .. " must be a number"
        end
        value = math.floor(value)
        if value < field.min or value > field.max then
          return false, ("%s must be %d..%d"):format(field.key, field.min, field.max)
        end
        job[field.key] = value
      end
    end
    jobType.save(job)
    return true
  end

  function jobType.setup(ui)
    local job = jobType.load()
    ui.clear()
    print(definition.label .. "\n")
    print("Chest goes directly BELOW the turtle.")
    print(definition.description .. "\n")

    local here = nav.worldPosition()
    if here then
      job.surfaceY = here.y
    else
      job.surfaceY = ui.askNumber("Current Y", job.surfaceY)
    end
    job.distance = ui.askNumber("Distance from base", job.distance)
    job.targetY = ui.askNumber("Mine at Y", job.targetY)
    job.tunnelLength = ui.askNumber("Tunnel length", job.tunnelLength)
    job.haul = {}
    job.delivered = 0
    jobType.restart(job)

    local needed = jobType.minimumFuel(job)
    print(("\nFuel minimum: %d, have %d aboard"):format(needed, fuel.available()))
    if fuel.available() < needed then
      printError("Not enough total fuel. Add fuel and run again.")
      job.active = false
      jobType.save(job)
    end
    nav.setHome()
    return job
  end

  function jobType.run(job, ctx)
    return runner.run(jobType, job, ctx)
  end

  return jobType
end

return factory
