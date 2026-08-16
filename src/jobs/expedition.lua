--- Expedition job: travel out, sink a shaft, branch mine, come home loaded.
---
--- 1. Rise to cruise altitude and fly a random bearing `distance` blocks out.
---    Random per turtle, so a fleet spreads out instead of all queueing down
---    the same hole.
--- 2. Sink a shaft to the target Y, following any vein it cuts through on the
---    way. This is where the coal and copper come from - neither spawns at
---    diamond level, but the shaft passes through every band to get there.
--- 3. Branch mine: a main corridor with ribs every few blocks, vein-following
---    anything worth having.
--- 4. Come home and empty into the chest.
---
--- Junk is dropped where it is mined. A round trip from diamond level a hundred
--- blocks out is ~250 moves each way, so hauling deepslate home would burn the
--- whole fuel budget on commuting.

local config = require("core.config")
local nav = require("turtle.nav")
local inv = require("turtle.inv")
local fuel = require("turtle.fuel")
local ore = require("turtle.ore")

local expedition = {}

expedition.name = "expedition"
expedition.PATH = ".expedition"

-- Bigger than the quarry's margin: out here a detour around a ravine or a lava
-- lake costs a lot more than it does inside a tidy pit.
local SAFETY_MARGIN = 150

local DEFAULTS = {
  distance = 100, -- blocks from base before digging down
  cruise = 12, -- travel altitude, relative to the start block
  surfaceY = 64, -- absolute Y the turtle started at
  targetY = -59, -- best diamond band in 1.20.1
  tunnelLength = 32,
  branchLength = 8,
  branchSpacing = 3,
  veinBudget = 48, -- cap per vein, so one andesite blob cannot eat the trip
  scanEvery = 1, -- scan for ore every N blocks (raise to trade yield for speed)
  extras = { "andesite" },

  -- progress
  phase = "travel",
  bearingX = 0,
  bearingZ = 0,
  tunnelDone = 0,
  haul = {},
  delivered = 0,
  active = false,
  startedAt = 0,
}

function expedition.load()
  return config.load(expedition.PATH, DEFAULTS)
end

function expedition.save(job)
  config.save(expedition.PATH, job)
end

--- Rough fuel cost, used to refuse a trip the turtle cannot finish.
function expedition.estimateFuel(job)
  local descent = job.surfaceY - job.targetY + job.cruise
  local ribs = math.floor(job.tunnelLength / job.branchSpacing) * job.branchLength * 4
  return 2 * (job.distance + descent) + job.tunnelLength + ribs + SAFETY_MARGIN
end

--- Progress across the whole trip, 0..1.
---
--- Interpolated inside each phase rather than stepped between them: the flight
--- out is a hundred blocks, and a bar that reads a flat 0% for all of it tells
--- you nothing about whether the turtle is moving or wedged against a cliff.
function expedition.progress(job)
  local x, y, z = nav.position()

  if job.phase == "travel" then
    local total = math.abs(job.bearingX) + math.abs(job.bearingZ) + job.cruise
    if total <= 0 then
      return 0
    end
    local done = math.abs(x) + math.abs(z) + math.max(0, y)
    return 0.2 * math.min(1, done / total)
  end

  if job.phase == "shaft" then
    local span = job.cruise - (job.targetY - job.surfaceY)
    if span <= 0 then
      return 0.2
    end
    return 0.2 + 0.3 * math.min(1, (job.cruise - y) / span)
  end

  if job.phase == "mining" then
    if job.tunnelLength <= 0 then
      return 0.5
    end
    return 0.5 + 0.45 * math.min(1, job.tunnelDone / job.tunnelLength)
  end

  if job.phase == "home" then
    return 0.95
  end

  return 0
end

--- Can this job actually start? Checked before every launch, including remote
--- deploys where nobody is at the keyboard to read a warning.
---
--- Launching without fuel is not a harmless mistake: the turtle flies out,
--- trips the safety margin, walks back, and parks - burning the little fuel it
--- had to accomplish nothing. Refusing at the gate is far better.
function expedition.ready(job)
  local needed = expedition.estimateFuel(job)
  if fuel.level() >= needed then
    return true
  end

  fuel.refuelTo(needed)
  if fuel.level() >= needed then
    return true
  end

  return false, ("needs %d fuel, has %d - add coal"):format(needed, math.floor(fuel.level()))
end

--- Reset progress and pick a fresh bearing, keeping the configured settings.
--- Used when the base sends a deploy order - there is nobody at the keyboard to
--- answer setup questions. A new bearing each time means a redeployed fleet
--- fans out over new ground instead of re-digging the last shaft.
function expedition.restart(job)
  math.randomseed(os.epoch("utc") + os.getComputerID() * 7919)
  local angle = math.random() * 2 * math.pi
  job.bearingX = math.floor(math.cos(angle) * job.distance + 0.5)
  job.bearingZ = math.floor(math.sin(angle) * job.distance + 0.5)

  job.phase = "travel"
  job.tunnelDone = 0
  job.haul = {}
  job.delivered = 0
  job.active = true
  job.startedAt = os.epoch("utc")
  expedition.save(job)
  return job
end

function expedition.status(job)
  return {
    progress = expedition.progress(job),
    haul = job.haul,
    delivered = job.delivered,
    target = job.targetY,
  }
end

--- Interactive configuration.
function expedition.setup(ui)
  local job = expedition.load()

  ui.clear()
  print("New expedition\n")
  print("Chest goes directly BELOW the turtle.")
  print("It will fly out, dig down, mine, and return.\n")

  -- A known origin (from `where`) or a GPS fix both give the exact surface Y,
  -- which saves asking and cannot be mistyped.
  local here = nav.worldPosition()
  if here then
    job.surfaceY = here.y
    print(("Standing at Y=%d%s\n"):format(here.y, nav.hasOrigin() and "" or " (GPS)"))
  else
    print("Press F3 and read your Y coordinate.")
    print("Tip: run `where` once to set this permanently.\n")
    job.surfaceY = ui.askNumber("Current Y", job.surfaceY)
  end

  job.distance = ui.askNumber("Distance from base", job.distance)
  job.targetY = ui.askNumber("Mine at Y", job.targetY)
  job.tunnelLength = ui.askNumber("Tunnel length", job.tunnelLength)

  -- A random bearing per turtle, so a fleet fans out instead of stacking up.
  math.randomseed(os.epoch("utc") + os.getComputerID() * 7919)
  local angle = math.random() * 2 * math.pi
  job.bearingX = math.floor(math.cos(angle) * job.distance + 0.5)
  job.bearingZ = math.floor(math.sin(angle) * job.distance + 0.5)

  job.phase = "travel"
  job.tunnelDone = 0
  job.haul = {}
  job.delivered = 0
  job.active = true
  job.startedAt = os.epoch("utc")

  print("")
  print(("Bearing: %d east, %d south"):format(job.bearingX, job.bearingZ))

  local needed = expedition.estimateFuel(job)
  print(("Fuel needed: ~%d, have %d"):format(needed, fuel.level()))

  if fuel.level() < needed then
    fuel.refuelTo(needed)
  end
  if fuel.level() < needed then
    print("")
    printError("Not enough fuel. Add coal and run again.")
    job.active = false
  end

  nav.setHome()
  expedition.save(job)
  return job
end

function expedition.run(job, ctx)
  local isWanted = ore.matcher(job.extras)
  local isJunk = ore.junkMatcher(job.extras)
  local targetRelY = job.targetY - job.surfaceY
  local sinceScan = 0

  local function record(name)
    job.haul[name] = (job.haul[name] or 0) + 1
  end

  --- Checked before every move. Returns false to end the trip early, with the
  --- reason - the caller always walks home afterwards regardless.
  local function guard()
    local abort = ctx.aborted()
    if abort then
      return false, abort
    end

    local needed = nav.distanceHome() + SAFETY_MARGIN
    if fuel.level() < needed and not fuel.refuelTo(needed + 500) then
      return false, "out of fuel"
    end

    if inv.freeSlots() <= 1 then
      inv.dropJunk(isJunk)
      if inv.freeSlots() == 0 then
        return false, "inventory full"
      end
    end

    return true
  end

  --- Look for ore around the turtle and follow anything found. Costs four
  --- turns, which is the bulk of the time this job spends, so it is throttled
  --- by scanEvery.
  local function scan()
    sinceScan = sinceScan + 1
    if sinceScan < job.scanEvery then
      return
    end
    sinceScan = 0
    ore.follow(nav, isWanted, job.veinBudget, record)
    inv.dropJunk(isJunk)
  end

  local function step()
    local ok, reason = guard()
    if not ok then
      return false, reason
    end
    local moved, err = nav.forward()
    if not moved then
      return false, err
    end
    scan()
    return true
  end

  local function travel()
    ctx.report("travel", ("out %d,%d"):format(job.bearingX, job.bearingZ))
    local ok, err = nav.goTo(job.bearingX, job.cruise, job.bearingZ)
    if not ok then
      return false, err
    end
    job.phase = "shaft"
    expedition.save(job)
    return true
  end

  local function sinkShaft()
    while select(2, nav.position()) > targetRelY do
      local ok, reason = guard()
      if not ok then
        return false, reason
      end

      local moved, err = nav.down()
      if not moved then
        -- Lava or bedrock below. Whatever depth we reached is where we mine.
        ctx.report("shaft", "stopped early: " .. tostring(err))
        break
      end

      local _, y = nav.position()
      ctx.report("shaft", ("Y %d, heading for %d"):format(job.surfaceY + y, job.targetY))
      scan()
    end

    job.phase = "mining"
    expedition.save(job)
    return true
  end

  local function digBranch(toLeft)
    local turnOut = toLeft and nav.turnLeft or nav.turnRight
    local turnBack = toLeft and nav.turnLeft or nav.turnRight

    turnOut()
    local dug = 0
    for _ = 1, job.branchLength do
      local ok = step()
      if not ok then
        break
      end
      dug = dug + 1
    end

    -- About-face and walk back through the rib we just cleared.
    nav.turnRight()
    nav.turnRight()
    for _ = 1, dug do
      if not nav.forward() then
        break
      end
    end
    turnBack()
  end

  local function mineTunnel()
    nav.face(0)
    while job.tunnelDone < job.tunnelLength do
      local ok, reason = step()
      if not ok then
        return false, reason
      end

      job.tunnelDone = job.tunnelDone + 1
      expedition.save(job)
      ctx.report("mining", ("tunnel %d/%d"):format(job.tunnelDone, job.tunnelLength))

      if job.tunnelDone % job.branchSpacing == 0 then
        ctx.report("mining", "rib at " .. job.tunnelDone)
        digBranch(true)
        digBranch(false)
      end
    end
    return true
  end

  --- The trip proper. Whatever this returns, the caller walks home.
  local function journey()
    if job.phase == "travel" then
      local ok, err = travel()
      if not ok then
        return false, err
      end
    end

    if job.phase == "shaft" then
      local ok, err = sinkShaft()
      if not ok then
        return false, err
      end
    end

    if job.phase == "mining" then
      local ok, err = mineTunnel()
      if not ok then
        return false, err
      end
    end

    return true
  end

  local ok, reason = journey()

  -- Coming home is unconditional. Every failure path above still ends here.
  job.phase = "home"
  expedition.save(job)
  ctx.report("returning", reason and tostring(reason) or "loaded, heading back")

  inv.dropJunk(isJunk)

  local _, y = nav.position()
  nav.goTo(job.bearingX, y, job.bearingZ) -- back to the shaft column
  while select(2, nav.position()) < job.cruise do
    if not nav.up() then
      break
    end
  end

  -- Empty downwards, into the chest under the home block. Unlike "behind me",
  -- that works no matter which way the turtle ended up facing - which matters
  -- when a swarm deployer placed it rather than a player, and it lets several
  -- turtles share one double chest as a depot.
  local home = nav.goHome()
  local depotFull = false
  if home then
    job.delivered = job.delivered + inv.dropAll(turtle.dropDown)

    -- With a shared depot this is the failure that actually happens: the chest
    -- backs up, the drop silently does nothing, and the turtle would otherwise
    -- park looking healthy while carrying a full load it can never put down.
    if inv.itemCount() > 0 then
      depotFull = true
    end
  end

  job.active = not ok and not home -- only stay "active" if we never made it back
  expedition.save(job)

  if not ok then
    return false, reason
  end
  if depotFull then
    -- Surfaced as a failure so the row goes red on the dashboard. A turtle
    -- holding a full load it cannot deposit is stuck, not finished.
    return false, "depot full - empty the chest below me"
  end
  return true
end

return expedition
