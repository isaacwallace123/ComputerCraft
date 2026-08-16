--- Autonomous focused-mining movement and return lifecycle.

local fuel = require("turtle.fuel")
local inv = require("turtle.inv")
local nav = require("turtle.nav")
local ore = require("turtle.ore")
local safety = require("jobs.common.safety")
local geo = require("turtle.geo")

local runner = {}

function runner.run(jobType, job, ctx)
  local isWanted = jobType.matcher(job)
  local isJunk = jobType.junkMatcher(job)
  local targetRelY = job.targetY - job.surfaceY
  local sinceScan = 0

  local function record(name)
    job.haul[name] = (job.haul[name] or 0) + 1
  end

  local function returnDistance()
    local x, y, z = nav.position()
    local travelY = job.travelY or job.cruise
    if y >= travelY then
      return nav.distanceHome()
    end
    return math.abs(x - job.bearingX)
      + math.abs(z - job.bearingZ)
      + math.abs(travelY - y)
      + math.abs(job.bearingX)
      + math.abs(travelY)
      + math.abs(job.bearingZ)
  end

  --- Checked before every move. Returns false to end the trip early, with the
  --- reason - the caller always walks home afterwards regardless.
  local function guard()
    local safe, reason, kind = safety.check(ctx, jobType.SAFETY_MARGIN, returnDistance())
    if not safe then
      return false, reason, kind
    end

    if inv.freeSlots() <= 1 then
      inv.dropJunk(isJunk)
      if inv.freeSlots() == 0 then
        return false, "inventory full", "cycle"
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
      return true
    end
    sinceScan = 0
    local _, reason, kind = ore.follow(nav, isWanted, job.veinBudget, record, nil, guard)
    inv.dropJunk(isJunk)
    if reason then
      return false, reason, kind
    end
    return true
  end

  local function step()
    local ok, reason, kind = guard()
    if not ok then
      return false, reason, kind
    end
    local moved, err = nav.forward()
    if not moved then
      return false, err
    end
    local scanned, scanReason, scanKind = scan()
    if not scanned then
      return false, scanReason, scanKind
    end
    return true
  end

  local function travel()
    ctx.report("travel", ("out %d,%d"):format(job.bearingX, job.bearingZ))
    local ok, err, kind = nav.goTo(job.bearingX, (job.travelY or job.cruise), job.bearingZ, guard)
    if not ok then
      return false, err, kind
    end
    job.phase = "shaft"
    jobType.save(job)
    return true
  end

  local function sinkShaft()
    while select(2, nav.position()) > targetRelY do
      local ok, reason, kind = guard()
      if not ok then
        return false, reason, kind
      end

      local moved, err = nav.down()
      if not moved then
        -- Lava or bedrock below. Whatever depth we reached is where we mine.
        ctx.report("shaft", "stopped early: " .. tostring(err))
        break
      end

      local _, y = nav.position()
      ctx.report("shaft", ("Y %d, heading for %d"):format(job.surfaceY + y, job.targetY))
      local scanned, scanReason, scanKind = scan()
      if not scanned then
        return false, scanReason, scanKind
      end
    end

    job.phase = "mining"
    jobType.save(job)
    return true
  end

  local function digBranch(toLeft)
    local turnOut = toLeft and nav.turnLeft or nav.turnRight
    local turnBack = toLeft and nav.turnLeft or nav.turnRight

    turnOut()
    local dug = 0
    local stoppedReason = nil
    local stoppedKind = nil
    for _ = 1, job.branchLength do
      local ok, reason, kind = step()
      if not ok then
        stoppedReason, stoppedKind = reason, kind
        break
      end
      dug = dug + 1
    end

    -- About-face and walk back through the rib we just cleared.
    nav.turnRight()
    nav.turnRight()
    for _ = 1, dug do
      local moved, err = nav.forward()
      if not moved then
        return false, "could not leave branch: " .. tostring(err)
      end
    end
    turnBack()
    return stoppedReason == nil, stoppedReason, stoppedKind
  end

  local function mineTunnel()
    if job.tunnelDone == 0 and geo.available() then
      ctx.report("scanning", "geo scanner targeting nearby " .. jobType.name .. " blocks")
      local targets = geo.targets(isWanted, 8, 12)
      if targets and #targets > 0 then
        local anchorX, anchorY, anchorZ, anchorFacing = nav.position()
        for _, target in ipairs(targets) do
          local allowed, scanReason, scanKind = guard()
          if not allowed then
            nav.goTo(anchorX, anchorY, anchorZ)
            nav.face(anchorFacing)
            return false, scanReason, scanKind
          end
          local reached, reachError, reachKind = nav.goTo(target.x, target.y, target.z, guard)
          if not reached then
            local returned, returnError = nav.goTo(anchorX, anchorY, anchorZ)
            nav.face(anchorFacing)
            if not returned then
              return false, "could not leave scanner route: " .. tostring(returnError)
            end
            if reachKind == "fuel" or reachKind == "recalled" then
              return false, reachError, reachKind
            end
            -- A scan can see ore behind lava, protected blocks, or a claim.
            -- Abandon that shortcut and continue with the complete branch grid.
            ctx.report("scanning", "target skipped: " .. tostring(reachError))
            break
          end
          record(target.name)
        end
        local returned, returnError = nav.goTo(anchorX, anchorY, anchorZ)
        nav.face(anchorFacing)
        if not returned then
          return false, "could not return from scanned ore: " .. tostring(returnError)
        end
        inv.dropJunk(isJunk)
      end
    end

    -- Continue roughly away from base. Combined with independent random launch
    -- bearings this makes a fleet fan out instead of mining parallel overlaps.
    nav.face(job.tunnelFacing or 0)
    while job.tunnelDone < job.tunnelLength do
      local ok, reason, kind = step()
      if not ok then
        return false, reason, kind
      end

      job.tunnelDone = job.tunnelDone + 1
      jobType.save(job)
      ctx.report("mining", ("tunnel %d/%d"):format(job.tunnelDone, job.tunnelLength))

      if job.tunnelDone % job.branchSpacing == 0 then
        ctx.report("mining", "rib at " .. job.tunnelDone)
        local left, leftReason, leftKind = digBranch(true)
        if not left then
          return false, leftReason, leftKind
        end
        local right, rightReason, rightKind = digBranch(false)
        if not right then
          return false, rightReason, rightKind
        end
      end
    end
    return true
  end

  --- The trip proper. Whatever this returns, the caller walks home.
  local function journey()
    if job.phase == "travel" then
      local ok, err, kind = travel()
      if not ok then
        return false, err, kind
      end
    end

    if job.phase == "shaft" then
      local ok, err, kind = sinkShaft()
      if not ok then
        return false, err, kind
      end
    end

    if job.phase == "mining" then
      local ok, err, kind = mineTunnel()
      if not ok then
        return false, err, kind
      end
    end

    return true
  end

  local ok, reason, stopKind = journey()

  -- Coming home is unconditional. Every failure path above still ends here.
  job.phase = "home"
  jobType.save(job)
  ctx.report("returning", reason and tostring(reason) or "loaded, heading back")

  inv.dropJunk(isJunk)

  local _, y = nav.position()
  -- Below cruise altitude, first unwind to the known shaft and climb it. If a
  -- reboot happened during the flight home (or after unloading), never turn
  -- around and revisit the shaft: goHome can finish directly from here.
  if nav.distanceHome() > 0 and y < (job.travelY or job.cruise) then
    local returned, returnError = nav.goTo(job.bearingX, y, job.bearingZ)
    if not returned then
      job.active = true
      jobType.save(job)
      return false, "could not reach shaft: " .. tostring(returnError)
    end
    while select(2, nav.position()) < (job.travelY or job.cruise) do
      local surfaced, surfaceError = nav.up()
      if not surfaced then
        job.active = true
        jobType.save(job)
        return false, "could not surface: " .. tostring(surfaceError)
      end
    end
  end

  -- Empty downwards, into the chest under the home block. Unlike "behind me",
  -- that works no matter which way the turtle ended up facing - which matters
  -- when a swarm deployer placed it rather than a player, and it lets several
  -- turtles share one double chest as a depot.
  local home, homeError = nav.goHome()
  local depotFull = false
  if home then
    job.delivered = job.delivered
      + inv.dropAllExcept(function(detail, slot)
        return fuel.isFuel(detail, slot)
      end, turtle.dropDown)

    -- With a shared depot this is the failure that actually happens: the chest
    -- backs up, the drop silently does nothing, and the turtle would otherwise
    -- park looking healthy while carrying a full load it can never put down.
    if
      inv.itemCount(function(detail, slot)
        return not fuel.isFuel(detail, slot)
      end) > 0
    then
      depotFull = true
    end
  end

  job.active = not home -- only stay active if we never made it back
  jobType.save(job)

  if not home then
    return false, "could not return home: " .. tostring(homeError)
  end

  if depotFull then
    -- Surfaced as a failure so the row goes red on the dashboard. A turtle
    -- holding a full load it cannot deposit is stuck, not finished.
    return false, "depot full - empty the chest below me"
  end
  if not ok then
    if stopKind == "fuel" or stopKind == "cycle" or stopKind == "recalled" then
      if stopKind == "cycle" then
        -- If power drops between the unload and runtime choosing the next route,
        -- rebooting resumes this harmless home phase instead of opening setup.
        job.active = true
        jobType.save(job)
      end
      return true, reason, stopKind
    end
    return false, reason
  end
  job.active = true
  jobType.save(job)
  return true, jobType.label .. " cycle complete", "cycle"
end

return runner
