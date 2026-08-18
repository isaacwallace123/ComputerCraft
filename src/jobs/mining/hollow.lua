--- Clear a three-block-tall rectangular floor at a configured world Y.

local config = require("adapters.cc.config")
local fuel = require("device.fuel")
local inv = require("device.inv")
local nav = require("device.nav")
local ore = require("device.ore")
local safety = require("jobs.common.safety")

local hollow = {
  name = "hollow",
  label = "Three-high hollow floor",
  PATH = ".hollow",
  usesSurfaceY = true,
  SAFETY_MARGIN = 96,
  settingFields = {
    { label = "Distance", key = "distance", step = 8, min = 2, max = 512 },
    { label = "Target Y", key = "targetY", step = 1, min = -63, max = 318 },
    { label = "Width", key = "width", step = 4, min = 1, max = 256 },
    { label = "Length", key = "length", step = 4, min = 1, max = 256 },
  },
}

local DEFAULTS = {
  distance = 16,
  targetY = -30,
  surfaceY = 64,
  width = 32,
  length = 32,
  travelY = 12,
  cell = 0,
  delivered = 0,
  haul = {},
  active = false,
  startedAt = 0,
}

function hollow.load()
  return config.load(hollow.PATH, DEFAULTS)
end

function hollow.save(job)
  config.save(hollow.PATH, job)
end

local function targetRelativeY(job)
  return job.targetY - job.surfaceY
end

local function routeY(job)
  return math.min(319 - job.surfaceY, math.max(12, targetRelativeY(job) + 1))
end

local function returnDistance(job)
  local x, y, z = nav.position()
  if y >= job.travelY then
    return nav.distanceHome()
  end
  return math.abs(x)
    + math.abs(z - job.distance)
    + math.abs(job.travelY - y)
    + math.abs(job.travelY)
    + job.distance
end

function hollow.minimumFuel(job)
  local travelY = job.active and job.travelY or routeY(job)
  local shaft = math.abs(travelY) + math.abs(travelY - targetRelativeY(job))
  return 2 * (job.distance + shaft) + hollow.SAFETY_MARGIN + 32
end

function hollow.estimateFuel(job)
  return hollow.minimumFuel(job) + job.width * job.length
end

function hollow.ready(job)
  local needed = hollow.minimumFuel(job)
  local available = fuel.available()
  if available >= needed then
    return true
  end
  return false,
    ("needs %d total fuel, has %d including inventory"):format(needed, math.floor(available))
end

function hollow.restart(job)
  -- Cruise above both home and the room. A room above home previously crossed
  -- directly at room level on the way back, tunnelling a second route through
  -- whatever stood between it and the depot instead of reusing its shaft.
  job.travelY = routeY(job)
  if job.cell >= job.width * job.length then
    job.cell = 0
  end
  job.active = true
  job.startedAt = os.epoch("utc")
  hollow.save(job)
  return job
end

function hollow.status(job)
  return {
    progress = job.cell / math.max(1, job.width * job.length),
    haul = job.haul,
    delivered = job.delivered,
    settings = {
      distance = job.distance,
      targetY = job.targetY,
      width = job.width,
      length = job.length,
    },
  }
end

function hollow.configure(job, settings)
  local updates = {}
  for _, field in ipairs(hollow.settingFields) do
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
  local changed = false
  for key, value in pairs(updates) do
    changed = changed or job[key] ~= value
    job[key] = value
  end
  if changed then
    job.cell = 0
  end
  job.travelY = routeY(job)
  hollow.save(job)
  return true
end

function hollow.setup(ui)
  local job = hollow.load()
  ui.clear()
  print("Three-high hollow floor\n")
  print("Chest goes directly BELOW the turtle.")
  print("The room begins forward from home and clears three blocks vertically.\n")
  local here = nav.worldPosition()
  job.surfaceY = here and here.y or ui.askNumber("Current Y", job.surfaceY)
  job.distance = ui.askNumber("Distance from base", job.distance)
  job.targetY = ui.askNumber("Middle floor Y", job.targetY)
  job.width = ui.askNumber("Width", job.width)
  job.length = ui.askNumber("Length", job.length)
  job.delivered = 0
  job.haul = {}
  job.cell = 0
  nav.setHome()
  hollow.restart(job)
  return job
end

local function keepFuel(detail, slot)
  return fuel.isFuel(detail, slot)
end

local function dump(job)
  job.delivered = job.delivered + inv.dropAllExcept(keepFuel, turtle.dropDown)
  hollow.save(job)
  return inv.itemCount(function(detail, slot)
    return not keepFuel(detail, slot)
  end) == 0
end

local function returnHome(job)
  if nav.distanceHome() == 0 then
    return true
  end
  local _, y = nav.position()
  if y < job.travelY then
    local reached, reachError = nav.goTo(0, y, job.distance)
    if not reached then
      return false, reachError
    end
    while select(2, nav.position()) < job.travelY do
      local moved, moveError = nav.up()
      if not moved then
        return false, moveError
      end
    end
  end
  return nav.goHome()
end

local function travelTo(job, tx, ty, tz, guard)
  local x, y, z = nav.position()
  if
    y == ty
    and x >= 0
    and x < job.width
    and z >= job.distance
    and z < job.distance + job.length
  then
    return nav.goTo(tx, ty, tz, guard)
  end

  local reached, reachError, kind = nav.goTo(0, job.travelY, job.distance, guard)
  if not reached then
    return false, reachError, kind
  end
  reached, reachError, kind = nav.goTo(tx, ty, tz, guard)
  return reached, reachError, kind
end

local function cellPosition(job, index)
  local column = math.floor(index / job.length)
  local row = index % job.length
  local z = column % 2 == 0 and row or (job.length - row - 1)
  return column, targetRelativeY(job), job.distance + z
end

function hollow.run(job, ctx)
  local isJunk = ore.junkMatcher({})
  local function guard()
    return safety.check(ctx, hollow.SAFETY_MARGIN, returnDistance(job))
  end

  while job.cell < job.width * job.length do
    local x, y, z = cellPosition(job, job.cell)
    ctx.report(
      "hollowing",
      ("cell %d/%d at Y %d"):format(job.cell + 1, job.width * job.length, job.targetY)
    )
    local reached, reason, kind = travelTo(job, x, y, z, guard)
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
        hollow.save(job)
        return true, reason, kind
      end
      return false, reason
    end

    local clearedUp, upError = nav.digUp()
    local clearedDown, downError = nav.digDown()
    if not clearedUp or not clearedDown then
      local home, homeError = returnHome(job)
      if not home then
        return false, "could not return after blocked cell: " .. tostring(homeError)
      end
      if not dump(job) then
        return false, "depot full - empty the chest below me"
      end
      return false,
        "could not clear three-high cell: " .. tostring(upError or downError or "blocked")
    end
    inv.dropJunk(isJunk)
    job.cell = job.cell + 1
    hollow.save(job)

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

  local home, homeError = returnHome(job)
  if not home then
    return false, "could not return home: " .. tostring(homeError)
  end
  if not dump(job) then
    return false, "depot full - empty the chest below me"
  end
  job.active = false
  hollow.save(job)
  return true, "hollow floor complete", "complete"
end

return hollow
