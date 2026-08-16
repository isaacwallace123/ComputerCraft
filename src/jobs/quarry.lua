--- Quarry job: dig a rectangular pit, bring everything home.
---
--- SETUP
---   1. Place the turtle at the near-left corner of the area.
---   2. Chest DIRECTLY BEHIND it.
---   3. Coal or charcoal in any slot.
---
--- The pit extends forward and to the right. Each pass clears two layers: the
--- one the turtle walks along, and the one beneath it.
---
--- The job never takes a step it cannot walk back from, and every layer starts
--- from home - so however odd a corner the turtle rebooted in, it walks back to
--- the chest and re-runs the current layer, mostly gliding through air it has
--- already mined. That is much easier to get right than partial-layer
--- bookkeeping, and it is why an interrupted job resumes cleanly.

local config = require("core.config")
local nav = require("turtle.nav")
local inv = require("turtle.inv")
local fuel = require("turtle.fuel")

local quarry = {}

quarry.name = "quarry"
quarry.PATH = ".quarry"

-- Spare fuel on top of the distance home: enough to notice a problem, back out
-- of it, and still make the trip.
local SAFETY_MARGIN = 64

local DEFAULTS = {
  width = 8, -- blocks to the right
  length = 8, -- blocks forward
  depth = 32, -- blocks down
  layer = 0, -- layers finished
  delivered = 0, -- items put in the chest
  active = false,
  startedAt = 0,
}

function quarry.load()
  return config.load(quarry.PATH, DEFAULTS)
end

function quarry.save(job)
  config.save(quarry.PATH, job)
end

function quarry.layers(job)
  return math.ceil(job.depth / 2)
end

function quarry.progress(job)
  local total = quarry.layers(job)
  if total == 0 then
    return 1
  end
  return job.layer / total
end

--- The level the turtle walks along for a given layer.
local function travelLevel(layer)
  return -(1 + 2 * layer)
end

--- Empty the inventory into the chest behind the start block. Assumes we are
--- home and facing the original direction.
local function dumpIntoChest(job)
  nav.face(2)
  job.delivered = job.delivered + inv.dropAll()
  nav.face(0)
  quarry.save(job)
end

--- Mid-layer trip: home, empty out, back to the exact block we left off at.
--- Fuel is topped up first, so coal in the haul becomes range rather than
--- sitting in a chest.
local function unload(job)
  local x, y, z, facing = nav.position()

  fuel.refuelTo(fuel.level() + 1000)

  local ok, err = nav.goHome()
  if not ok then
    return false, err
  end
  dumpIntoChest(job)

  ok, err = nav.goTo(x, y, z)
  if not ok then
    return false, err
  end
  nav.face(facing)
  return true
end

--- Run before every move: enough fuel to get home, and somewhere to put ore.
local function checkpoint(job)
  local needed = nav.distanceHome() + SAFETY_MARGIN
  if fuel.level() < needed and not fuel.refuelTo(needed + 500) then
    return false, "out of fuel"
  end

  if inv.isFull() then
    local ok, err = unload(job)
    if not ok then
      return false, "could not unload: " .. tostring(err)
    end
  end

  return true
end

local function advance(job)
  local ok, err = checkpoint(job)
  if not ok then
    return false, err
  end
  return nav.forward()
end

--- Boustrophedon sweep: up one column, shuffle sideways, back down the next.
local function sweepLayer(job, report)
  local right = true

  for column = 1, job.width do
    report(
      "mining",
      ("layer %d/%d  column %d/%d"):format(job.layer + 1, quarry.layers(job), column, job.width)
    )

    for cell = 1, job.length do
      nav.digDown()
      if cell < job.length then
        local ok, err = advance(job)
        if not ok then
          return false, err
        end
      end
    end

    if column < job.width then
      local turn = right and nav.turnRight or nav.turnLeft
      turn()
      local ok, err = advance(job)
      if not ok then
        return false, err
      end
      nav.digDown()
      turn()
      right = not right
    end
  end

  return true
end

local function descendToLayer(layer)
  local target = travelLevel(layer)
  while select(2, nav.position()) > target do
    local ok, err = nav.down()
    if not ok then
      return false, err
    end
  end
  return true
end

--- Interactive configuration. Returns a fresh job.
function quarry.setup(ui)
  local job = quarry.load()

  ui.clear()
  print("New quarry\n")
  print("Chest goes directly BEHIND the turtle.")
  print("The pit runs forward and to the right.\n")

  job.width = ui.askNumber("Width (right)", job.width)
  job.length = ui.askNumber("Length (forward)", job.length)
  job.depth = ui.askNumber("Depth (down)", job.depth)
  job.layer = 0
  job.delivered = 0
  job.active = true
  job.startedAt = os.epoch("utc")

  nav.setHome()
  quarry.save(job)
  return job
end

--- Run the job to completion. `report(phase, detail)` is called often enough to
--- drive a live dashboard.
function quarry.run(job, report)
  while job.layer < quarry.layers(job) do
    report("returning", "to start of layer " .. (job.layer + 1))
    local ok, err = nav.goHome()
    if not ok then
      return false, err
    end

    report("descending", "to layer " .. (job.layer + 1))
    ok, err = descendToLayer(job.layer)
    if not ok then
      if err == "unbreakable" then
        report("finishing", "hit bedrock")
        break
      end
      return false, err
    end

    ok, err = sweepLayer(job, report)
    if not ok then
      return false, err
    end

    report("returning", "layer " .. (job.layer + 1) .. " done")
    ok, err = nav.goHome()
    if not ok then
      return false, err
    end
    dumpIntoChest(job)

    job.layer = job.layer + 1
    quarry.save(job)
  end

  report("returning", "job complete")
  if nav.goHome() then
    dumpIntoChest(job)
  end

  job.active = false
  quarry.save(job)
  return true
end

return quarry
