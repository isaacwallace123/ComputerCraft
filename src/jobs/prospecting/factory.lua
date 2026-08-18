--- Factory for focused, repeatable branch-mining jobs.
---
--- A job built here no longer chooses where to mine. That decision moved to the
--- shared mine plan: the turtle claims a sector, and the sector's shaft, trunk,
--- and cruise lane all fall out of arithmetic both the base and the turtle can
--- do. What is left in this file is the per-profile part - what counts as ore,
--- how deep to go, and what a safe trip costs.

local access = require("device.access")
local config = require("adapters.cc.config")
local fuel = require("device.fuel")
local nav = require("device.nav")
local ore = require("device.ore")
local plan = require("domain.mine.plan")
local profiles = require("jobs.prospecting.profiles")
local runner = require("jobs.prospecting.runner")
local site = require("legacy.mine.site")
local surface = require("jobs.prospecting.surface")

local factory = {}

local SAFETY_MARGIN = 150
local MINING_ALLOWANCE = 32

--- Cost of the route from home to the current frontier, one way.
---
--- Deliberately the route the turtle actually flies and walks - up to the lane,
--- across to the shaft, down the shaft, out along the trunk - rather than a
--- straight line. Under-counting here is how a turtle strands itself.
local function routeCost(job)
  local origin = nav.origin()
  if not origin then
    return math.abs(job.laneY - job.surfaceY) + math.abs(job.laneY - job.targetY) + 128
  end

  -- The head may have been slid along the trunk to clear water at the sector's
  -- centre, and the route is flown to where the hole actually is.
  local headX = job.shaftX + (tonumber(job.shaftOffset) or 0)
  local climb = math.abs(job.laneY - origin.y)
  local across = math.abs(headX - origin.x) + math.abs(job.shaftZ - origin.z)
  local drop = math.abs(job.laneY - job.targetY)
  local last = math.max(0, (job.trunkLength or 1) - 1)
  local nextCell = (job.trunkFromX or job.shaftX) + math.min(job.frontier or 0, last)
  local trunk = math.abs(nextCell - headX)
  return climb + across + drop + trunk
end

local function copyDefaults(definition)
  return {
    -- Profile settings the user owns.
    targetY = definition.targetY,
    surfaceY = 64,
    veinBudget = definition.veinBudget or ore.DEFAULT_BUDGET,
    veinRadius = definition.veinRadius or ore.DEFAULT_RADIUS,
    veinGapBudget = definition.veinGapBudget or ore.DEFAULT_GAP_BUDGET,
    scanEvery = 1,
    extraPatterns = definition.extraPatterns or {},

    -- Sector geometry, refreshed from the mine plan before every restart. Persisted
    -- so a reboot mid-trip resumes the same route instead of re-deriving one
    -- from a plan that may have changed while the turtle was underground.
    sector = 0,
    frontier = 0,
    shaftX = 0,
    shaftZ = 0,
    -- Where the head actually is along the trunk, when the sector's centre
    -- turned out to be under water or otherwise unsealable.
    shaftOffset = 0,
    laneY = 72,
    trunkZ = 0,
    trunkFromX = 0,
    trunkToX = 0,
    trunkLength = 48,
    -- `ribReach` is retained only to migrate a route saved by the first shared-
    -- mine build. New routes persist the two edge-accurate reaches below.
    ribReach = 24,
    branchSpacing = 3,

    phase = "travel",
    returnViaShaft = false,
    pendingVein = nil,
    -- Surface access for this sector's shaft. Deliberately absent from the
    -- defaults table rather than shared by reference across loads: `load`
    -- normalises it into a fresh record every time.
    access = nil,
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
      { label = "Target Y", key = "targetY", step = 1, min = -63, max = 319 },
      { label = "Vein budget", key = "veinBudget", step = 32, min = 16, max = 2048 },
      { label = "Vein radius", key = "veinRadius", step = 4, min = 4, max = 64 },
    },
  }
  local defaults = copyDefaults(definition)

  local function workKey(job)
    -- Frontiers are per profile and depth. Different jobs can share the shaft,
    -- but completing Rare at Y -59 must not exhaust Resources at Y 16.
    return ("%s@%d"):format(jobType.name, math.floor(job.targetY))
  end
  jobType.workKey = workKey

  local function applyRoute(job, state)
    local sector = site.sector(state)
    if not sector then
      return false, "no shared mine sector is available"
    end

    local previousSector = job.sector
    local previousShaftX, previousShaftZ = job.shaftX, job.shaftZ
    local pending = job.pendingVein
    if
      pending
      and (
        (pending.sector or previousSector) ~= sector.index
        or (pending.shaftX ~= nil and pending.shaftX ~= sector.shaftX)
        or (pending.shaftZ ~= nil and pending.shaftZ ~= sector.shaftZ)
        or (pending.targetY ~= nil and pending.targetY ~= job.targetY)
      )
    then
      -- A pending coordinate belongs to one physical route. Never carry it into
      -- a replacement lease or a mine plan whose sector number moved.
      job.pendingVein = nil
    end

    job.sector = sector.index
    job.frontier = math.max(0, math.min(state.frontier, sector.trunkLength))
    job.shaftX, job.shaftZ = sector.shaftX, sector.shaftZ
    job.trunkZ = sector.trunkZ
    job.trunkFromX, job.trunkToX = sector.trunkFromX, sector.trunkToX
    job.trunkLength = sector.trunkLength
    job.ribReachLow = sector.ribReachLow
    job.ribReachHigh = sector.ribReachHigh
    job.branchSpacing = state.plan.branchSpacing
    job.laneY = plan.laneY(state.plan, sector.index)
    job.surfaceY = state.plan.surfaceY

    if
      job.sector ~= previousSector
      or job.shaftX ~= previousShaftX
      or job.shaftZ ~= previousShaftZ
    then
      -- A recorded cap describes one physical hole. A replacement lease, or a
      -- plan whose sector numbers moved, is a different hole in different
      -- ground, and applying the old coordinate to it would cap thin air while
      -- leaving the real opening exposed. The shaft being left behind was
      -- sealed at the end of its own last trip, so nothing is orphaned here.
      job.access = access.normalise(nil)
      job.shaftOffset = 0
      job.stalls = 0
    end

    -- The base may already know where this sector's head is, because another
    -- turtle found it. Advisory only - the descent still verifies the ground it
    -- is standing over - but it saves re-probing a column somebody already
    -- established is under water.
    local known = type(state.surface) == "table" and state.surface or nil
    if known and tonumber(known.headOffset) then
      job.shaftOffset = math.floor(known.headOffset)
    end
    return true
  end

  local PHASES = {
    travel = true,
    descend = true,
    transit = true,
    mining = true,
    home = true,
  }

  function jobType.load()
    local job = config.load(jobType.PATH, defaults)

    if job.ribReachLow == nil then
      job.ribReachLow = job.ribReach or 24
    end
    if job.ribReachHigh == nil then
      job.ribReachHigh = math.max(0, (job.ribReach or 24) - 1)
    end
    if
      type(job.pendingVein) ~= "table"
      or type(job.pendingVein.x) ~= "number"
      or type(job.pendingVein.y) ~= "number"
      or type(job.pendingVein.z) ~= "number"
    then
      job.pendingVein = nil
    end

    -- Files from v1.2.6 and earlier have no surface record at all, and a file
    -- interrupted between the two halves of a cap move may have one that cannot
    -- be acted on. Both normalise to a state the runner can resolve safely
    -- rather than to a coordinate it would trust.
    job.access = access.normalise(job.access)

    -- Files written by the random-bearing builds carry phases that no longer
    -- exist. `shaft` is the direct ancestor of `descend`; anything else unknown
    -- restarts the route, which is safe because a route is cheap to redo and a
    -- turtle acting on a phase it does not understand is not.
    if job.phase == "shaft" then
      job.phase = "descend"
    elseif not PHASES[job.phase] then
      job.phase = "travel"
    end

    return job
  end

  function jobType.save(job)
    config.save(jobType.PATH, job)
  end

  function jobType.matcher(job)
    return profiles.matcher(definition.profile, job.extraPatterns)
  end

  function jobType.junkMatcher(job)
    local keep = {}
    if definition.profile == "resources" then
      keep[#keep + 1] = "andesite"
    end
    -- A manually configured extra target must also be retained as an item. The
    -- previous split detected (for example) granite as wanted ore, then dropped
    -- the resulting granite because the junk policy never saw `extraPatterns`.
    for _, pattern in ipairs(job.extraPatterns or {}) do
      keep[#keep + 1] = pattern
    end
    return ore.junkMatcher(keep)
  end

  function jobType.estimateFuel(job)
    local remaining = math.max(0, (job.trunkLength or 0) - (job.frontier or 0))
    local spacing = math.max(1, job.branchSpacing)
    local ribCount = math.floor((job.trunkLength or 0) / spacing)
      - math.floor((job.frontier or 0) / spacing)
    -- Each rib is walked out and back. Low/high reaches differ by one for an
    -- even cell size so the whole sector is covered without crossing its edge.
    local low = job.ribReachLow or job.ribReach or 0
    local high = job.ribReachHigh or math.max(0, low - 1)
    local ribs = ribCount * (low + high) * 2
    return 2 * routeCost(job) + remaining + ribs + SAFETY_MARGIN + 2 * surface.RESERVE
  end

  function jobType.minimumFuel(job)
    return 2 * routeCost(job) + SAFETY_MARGIN + MINING_ALLOWANCE + 2 * surface.RESERVE
  end

  function jobType.progress(job)
    local x, y, z = nav.position()
    local origin = nav.origin()
    if job.phase == "travel" then
      if not origin then
        return 0
      end
      local total = math.abs(job.shaftX - origin.x)
        + math.abs(job.shaftZ - origin.z)
        + math.abs(job.laneY - origin.y)
      local done = math.abs(x) + math.abs(z) + math.max(0, y)
      return total > 0 and 0.15 * math.min(1, done / total) or 0
    elseif job.phase == "descend" then
      return 0.2
    elseif job.phase == "transit" then
      return 0.3
    elseif job.phase == "mining" then
      return 0.4 + 0.55 * math.min(1, (job.frontier or 0) / math.max(1, job.trunkLength or 1))
    elseif job.phase == "home" then
      return 0.95
    end
    return 0
  end

  function jobType.ready(job)
    -- The shared mine is defined in world coordinates, so a turtle that does not
    -- know where it is cannot take part. This is the same prerequisite the
    -- coordinated quarry has had all along.
    if not nav.hasOrigin() then
      return false, "run where on this turtle so it can find the shared mine", "setup"
    end

    if (job.sector or 0) < 1 then
      return false, "no shared mine sector - configure Operations on the running base", "setup"
    end

    local needed = jobType.minimumFuel(job)
    local available = fuel.available()
    if available >= needed then
      return true
    end
    return false,
      ("needs %d total fuel, has %d including inventory"):format(needed, math.floor(available)),
      "fuel"
  end

  --- Take a sector from the base and lay this job's route over it.
  ---
  --- The old version rolled a random bearing here, which is precisely why the
  --- surface filled up with holes: a new bearing meant a new shaft, every cycle,
  --- forever. Claiming instead means the common case - an unfinished sector this
  --- turtle already holds - reuses a hole that is already dug.
  function jobType.prepare(job)
    local state, claimError = site.claim(workKey(job), job.sector, job.frontier)
    if claimError then
      return false, claimError, "setup"
    end
    local applied, applyError = applyRoute(job, state)
    if not applied then
      return false,
        claimError or applyError or "no mine plan - configure Operations on the running base",
        "setup"
    end

    jobType.save(job)
    return true
  end

  function jobType.restart(job)
    job.phase = "travel"
    job.returnViaShaft = false
    -- A restart happens standing on the home block, above ground, immediately
    -- after `nav.setHome`. Whatever the last trip believed about being under a
    -- cap is no longer true, and a stale "below" would make the next descent
    -- skip opening the surface and sink an uncapped shaft instead. The descent
    -- re-finds the head anyway: the cap it placed last cycle reads as ground.
    job.access = access.normalise(nil)
    job.active = true
    job.startedAt = os.epoch("utc")
    jobType.save(job)
    return job
  end

  --- What is still true about this job while the turtle is parked.
  ---
  --- Route phase is meaningless standing at the depot; how much of the sector is
  --- worked is not, and it is the number that actually predicts the next cycle.
  local function standing(job)
    return math.min(1, (job.frontier or 0) / math.max(1, job.trunkLength or 1))
  end

  function jobType.status(job)
    return {
      progress = jobType.progress(job),
      standing = standing(job),
      haul = job.haul,
      delivered = job.delivered,
      target = job.targetY,
      sector = job.sector,
      workKey = workKey(job),
      settings = {
        targetY = job.targetY,
        veinBudget = job.veinBudget,
        veinRadius = job.veinRadius,
        sector = job.sector,
        frontier = job.frontier,
        pendingVein = job.pendingVein ~= nil,
        -- Which side of the surface this turtle believes it is on. The one
        -- reading that says whether a sector shaft is closed right now.
        shaft = (job.access or {}).state,
      },
    }
  end

  function jobType.configure(job, settings)
    local updates = {}
    local previousTargetY = job.targetY
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
        updates[field.key] = value
      end
    end
    for key, value in pairs(updates) do
      job[key] = value
    end
    if job.targetY ~= previousTargetY then
      job.pendingVein = nil
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
    job.targetY = ui.askNumber("Mine at Y", job.targetY)
    job.haul = {}
    job.delivered = 0

    if not nav.hasOrigin() then
      printError("\nRun `where` on this turtle first - the shared mine needs")
      printError("world coordinates to place its shafts.")
      job.active = false
      jobType.save(job)
      return job
    end

    print("\nClaiming a sector from base...")
    nav.setHome()
    local prepared, prepareError = jobType.prepare(job)

    if not prepared then
      printError("\n" .. tostring(prepareError))
      printError("Configure the shared mine in Operations on the running base,")
      printError("then configure this turtle again.")
      job.active = false
      jobType.save(job)
      return job
    end
    print(plan.describe(site.load().plan, job.sector))
    jobType.restart(job)

    local needed = jobType.minimumFuel(job)
    print(("Fuel minimum: %d, have %d aboard"):format(needed, fuel.available()))
    if fuel.available() < needed then
      printError("Not enough total fuel. Add fuel and run again.")
      job.active = false
      jobType.save(job)
    end
    return job
  end

  function jobType.run(job, ctx)
    return runner.run(jobType, job, ctx)
  end

  return jobType
end

return factory
