--- Coordinated absolute-area quarry. Fleet assigns disjoint, balanced cell ranges.

local config = require("core.config")
local fuel = require("turtle.fuel")
local inv = require("turtle.inv")
local nav = require("turtle.nav")
local safety = require("jobs.common.safety")

local quarry = {
  name = "quarry",
  label = "Coordinated area quarry",
  PATH = ".quarry",
  SAFETY_MARGIN = 128,
  settingFields = {
    { label = "Minimum X", key = "minX", step = 8, min = -30000000, max = 30000000 },
    { label = "Maximum X", key = "maxX", step = 8, min = -30000000, max = 30000000 },
    { label = "Minimum Z", key = "minZ", step = 8, min = -30000000, max = 30000000 },
    { label = "Maximum Z", key = "maxZ", step = 8, min = -30000000, max = 30000000 },
    { label = "Top Y", key = "topY", step = 1, min = -63, max = 319 },
    { label = "Bottom Y", key = "bottomY", step = 1, min = -64, max = 318 },
  },
}

local DEFAULTS = {
  minX = 0,
  maxX = 15,
  minZ = 0,
  maxZ = 15,
  topY = 64,
  bottomY = -59,
  workerIndex = 1,
  workerCount = 1,
  layer = 0,
  cell = 0,
  delivered = 0,
  configured = false,
  active = false,
  startedAt = 0,
}

function quarry.load()
  local job = config.load(quarry.PATH, DEFAULTS)
  -- The old quarry stored width/length/depth relative to each turtle. Never
  -- reinterpret that file as absolute world coordinates after an update.
  if fs.exists(quarry.PATH) then
    local handle = fs.open(quarry.PATH, "r")
    local ok, saved = false, nil
    if handle then
      ok, saved = pcall(textutils.unserialise, handle.readAll())
    end
    if handle then
      handle.close()
    end
    if ok and type(saved) == "table" and saved.width ~= nil and saved.minX == nil then
      job.configured = false
      job.active = false
    end
  end
  return job
end

function quarry.save(job)
  config.save(quarry.PATH, job)
end

local function areaCells(job)
  return (job.maxX - job.minX + 1) * (job.maxZ - job.minZ + 1)
end

local function workerRange(job)
  local total = areaCells(job)
  local first = math.floor(total * (job.workerIndex - 1) / job.workerCount)
  local after = math.floor(total * job.workerIndex / job.workerCount)
  return first, after
end

local function workerCells(job)
  local first, after = workerRange(job)
  return math.max(0, after - first)
end

local function layerCount(job)
  return math.ceil((job.topY - job.bottomY + 1) / 2)
end

local function layerY(job)
  return job.topY - job.layer * 2
end

local function cruiseY(job)
  local origin = nav.origin()
  return math.min(319, math.max(origin and origin.y or job.topY, job.topY) + 8)
end

local function worldForFlat(job, flat, y)
  local length = job.maxZ - job.minZ + 1
  local column = math.floor(flat / length)
  local row = flat % length
  local x = job.minX + column
  local z = column % 2 == 0 and (job.minZ + row) or (job.maxZ - row)
  return x, y, z
end

local function cellWorld(job, index)
  local first, after = workerRange(job)
  local flat = first + index
  if flat >= after then
    return nil
  end
  return worldForFlat(job, flat, layerY(job))
end

local function returnDistance(job)
  if nav.distanceHome() == 0 then
    return 0
  end
  local x, y, z = nav.position()
  local cruise = cruiseY(job) - nav.origin().y
  if y >= cruise then
    return nav.distanceHome()
  end
  local first = workerRange(job)
  local firstX, _, firstZ = worldForFlat(job, first, layerY(job))
  local shaft = assert(nav.worldToRelative(firstX, layerY(job), firstZ))
  return math.abs(x - shaft.x)
    + math.abs(z - shaft.z)
    + math.abs(cruise - y)
    + math.abs(shaft.x)
    + math.abs(cruise)
    + math.abs(shaft.z)
end

function quarry.minimumFuel(job)
  local origin = nav.origin()
  if not origin then
    return quarry.SAFETY_MARGIN
  end
  local first = workerRange(job)
  local startX, _, startZ = worldForFlat(job, first, job.topY)
  local travel = math.abs(startX - origin.x)
    + math.abs(startZ - origin.z)
    + math.abs(cruiseY(job) - origin.y)
    + math.abs(cruiseY(job) - job.topY)
  return travel * 2 + quarry.SAFETY_MARGIN + 32
end

function quarry.estimateFuel(job)
  return quarry.minimumFuel(job) + workerCells(job) * layerCount(job)
end

function quarry.ready(job)
  if not nav.hasOrigin() then
    return false, "run where on this turtle before assigning a world-area quarry"
  end
  if not job.configured then
    return false, "configure absolute quarry corners before deploying"
  end
  if job.maxX < job.minX or job.maxZ < job.minZ or job.topY < job.bottomY then
    return false, "invalid quarry corners"
  end
  if job.workerCount > areaCells(job) or workerCells(job) == 0 then
    return false, "more quarry workers than horizontal cells"
  end
  if fuel.available() < quarry.minimumFuel(job) then
    return false,
      ("needs %d total fuel, has %d"):format(quarry.minimumFuel(job), math.floor(fuel.available()))
  end
  return true
end

function quarry.restart(job)
  job.layer = 0
  job.cell = 0
  job.active = true
  job.startedAt = os.epoch("utc")
  quarry.save(job)
  return job
end

function quarry.status(job)
  local perLayer = workerCells(job)
  local total = math.max(1, perLayer * layerCount(job))
  return {
    progress = math.min(1, (job.layer * perLayer + job.cell) / total),
    haul = {},
    delivered = job.delivered,
    settings = {
      minX = job.minX,
      maxX = job.maxX,
      minZ = job.minZ,
      maxZ = job.maxZ,
      topY = job.topY,
      bottomY = job.bottomY,
      workerIndex = job.workerIndex,
      workerCount = job.workerCount,
    },
  }
end

function quarry.configure(job, settings)
  local numeric = {
    minX = { -30000000, 30000000 },
    maxX = { -30000000, 30000000 },
    minZ = { -30000000, 30000000 },
    maxZ = { -30000000, 30000000 },
    topY = { -63, 319 },
    bottomY = { -64, 318 },
    workerIndex = { 1, 1024 },
    workerCount = { 1, 1024 },
  }
  for key, range in pairs(numeric) do
    if settings[key] ~= nil then
      local value = tonumber(settings[key])
      if not value then
        return false, key .. " must be a number"
      end
      value = math.floor(value)
      if value < range[1] or value > range[2] then
        return false, ("%s must be %d..%d"):format(key, range[1], range[2])
      end
      job[key] = value
    end
  end
  if job.maxX < job.minX or job.maxZ < job.minZ or job.topY < job.bottomY then
    return false, "maximum corners must exceed minimum corners"
  end
  if job.workerIndex > job.workerCount then
    return false, "worker index exceeds worker count"
  end
  if job.workerCount > areaCells(job) then
    return false, "worker count exceeds horizontal quarry cells"
  end
  job.configured = true
  quarry.save(job)
  return true
end

function quarry.setup(ui)
  local job = quarry.load()
  ui.clear()
  print("Coordinated world-area quarry\n")
  print("Run where first. Chest goes BELOW every turtle.")
  print("Enter opposite X/Z corners and the full vertical range.\n")
  job.minX = ui.askNumber("Minimum X", job.minX)
  job.maxX = ui.askNumber("Maximum X", job.maxX)
  job.minZ = ui.askNumber("Minimum Z", job.minZ)
  job.maxZ = ui.askNumber("Maximum Z", job.maxZ)
  job.topY = ui.askNumber("Top block Y", job.topY)
  job.bottomY = ui.askNumber("Bottom block Y", job.bottomY)
  job.workerIndex, job.workerCount = 1, 1
  job.configured = true
  job.delivered = 0
  nav.setHome()
  quarry.restart(job)
  return job
end

local function keepFuel(detail, slot)
  return fuel.isFuel(detail, slot)
end

local function dump(job)
  job.delivered = job.delivered + inv.dropAllExcept(keepFuel, turtle.dropDown)
  quarry.save(job)
  return inv.itemCount(function(detail, slot)
    return not keepFuel(detail, slot)
  end) == 0
end

local function relative(worldX, worldY, worldZ)
  local point, err = nav.worldToRelative(worldX, worldY, worldZ)
  if not point then
    return nil, err
  end
  return point
end

local function returnHome(job)
  if nav.distanceHome() == 0 then
    return true
  end
  local first = workerRange(job)
  local firstX, _, firstZ = worldForFlat(job, first, layerY(job))
  local _, currentY = nav.position()
  local shaft, shaftError = relative(firstX, layerY(job), firstZ)
  if currentY < cruiseY(job) - nav.origin().y then
    if not shaft then
      return false, shaftError
    end
    local reached, reachError = nav.goTo(shaft.x, currentY, shaft.z)
    if not reached then
      return false, reachError
    end
    local cruise = cruiseY(job) - nav.origin().y
    while select(2, nav.position()) < cruise do
      local moved, moveError = nav.up()
      if not moved then
        return false, moveError
      end
    end
  end
  return nav.goHome()
end

local function travelTo(job, worldX, worldY, worldZ, guard)
  local target, targetError = relative(worldX, worldY, worldZ)
  if not target then
    return false, targetError
  end
  local _, y = nav.position()
  if y == target.y and nav.distanceHome() > 0 then
    return nav.goTo(target.x, target.y, target.z, guard)
  end
  local cruise = cruiseY(job) - nav.origin().y
  local reached, reachError, kind = nav.goTo(target.x, cruise, target.z, guard)
  if not reached then
    return false, reachError, kind
  end
  return nav.goTo(target.x, target.y, target.z, guard)
end

function quarry.run(job, ctx)
  local function guard()
    return safety.check(ctx, quarry.SAFETY_MARGIN, returnDistance(job))
  end

  local perLayer = workerCells(job)
  while job.layer < layerCount(job) and perLayer > 0 do
    while job.cell < perLayer do
      local worldX, worldY, worldZ = cellWorld(job, job.cell)
      ctx.report(
        "quarrying",
        ("worker %d/%d  Y %d  %d/%d"):format(
          job.workerIndex,
          job.workerCount,
          worldY,
          job.cell + 1,
          perLayer
        )
      )
      local reached, reason, kind = travelTo(job, worldX, worldY, worldZ, guard)
      if not reached then
        local home, homeError = returnHome(job)
        if not home then
          return false, "could not return home: " .. tostring(homeError)
        end
        if not dump(job) then
          return false, "depot full - empty the chest below me"
        end
        if kind == "fuel" or kind == "recalled" then
          job.active = false
          quarry.save(job)
          return true, reason, kind
        end
        return false, reason
      end

      if worldY - 1 >= job.bottomY then
        local cleared, clearError = nav.digDown()
        if not cleared then
          local home, homeError = returnHome(job)
          if not home then
            return false, "could not return after blocked layer: " .. tostring(homeError)
          end
          if not dump(job) then
            return false, "depot full - empty the chest below me"
          end
          return false, "could not clear quarry layer: " .. tostring(clearError)
        end
      end
      job.cell = job.cell + 1
      quarry.save(job)

      if inv.isFull() then
        local home, homeError = returnHome(job)
        if not home then
          return false, "could not unload: " .. tostring(homeError)
        end
        if not dump(job) then
          return false, "depot full - empty the chest below me"
        end
      end
    end
    job.layer = job.layer + 1
    job.cell = 0
    quarry.save(job)
  end

  local home, homeError = returnHome(job)
  if not home then
    return false, "could not return home: " .. tostring(homeError)
  end
  if not dump(job) then
    return false, "depot full - empty the chest below me"
  end
  job.active = false
  quarry.save(job)
  return true, "assigned quarry cells complete", "complete"
end

return quarry
