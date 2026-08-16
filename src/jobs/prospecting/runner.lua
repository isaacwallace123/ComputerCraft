--- Autonomous focused-mining movement and return lifecycle.
---
--- The route has five parts and every one of them is reused between cycles:
---
---   travel   fly at this sector's lane altitude to above its shaft
---   descend  move through the sector shaft to the profile's target Y
---   transit  walk the trunk tunnel out to the frontier this sector reached
---   mining   extend the trunk, cut ribs, follow veins, advance the frontier
---   home     back along the trunk, up the shaft, home at lane altitude
---
--- The reuse is the whole point. A cycle that ends early - full inventory, fuel
--- reserve, recall - no longer throws the route away. The frontier is saved, so
--- the next cycle comes back down the same hole to the same tunnel and picks up
--- where this one stopped, instead of rolling a fresh random bearing and leaving
--- a half-mined vein and a new crater behind it.

local fuel = require("turtle.fuel")
local geo = require("turtle.geo")
local inv = require("turtle.inv")
local nav = require("turtle.nav")
local ore = require("turtle.ore")
local safety = require("jobs.common.safety")
local site = require("mine.site")

local runner = {}

function runner.run(jobType, job, ctx)
  -- No sector means no shaft coordinates, and the unset ones are 0,0 - which is
  -- a real place in the world and emphatically not where this turtle should fly.
  -- This happens exactly once per turtle, on the first run after upgrading from
  -- a build that picked random bearings. Come home, then ask for a proper route.
  if (job.sector or 0) < 1 then
    ctx.report("returning", "no mine sector yet - heading home to claim one")
    -- A random-bearing job upgraded while underground still knows its old
    -- shaft. Unwind that legacy route once instead of letting `goHome` cut a
    -- direct tunnel at depth before the first shared-sector claim.
    local legacyX = tonumber(job.bearingX)
    local legacyZ = tonumber(job.bearingZ)
    local legacyY = tonumber(job.travelY or job.cruise)
    local home, homeError
    local _, currentY = nav.position()
    if legacyX and legacyZ and legacyY and currentY < legacyY then
      local reached, reachError = nav.goTo(legacyX, currentY, legacyZ)
      if not reached then
        return false, "could not reach legacy shaft: " .. tostring(reachError)
      end
      while select(2, nav.position()) < legacyY do
        local surfaced, surfaceError = nav.up()
        if not surfaced then
          return false, "could not leave legacy shaft: " .. tostring(surfaceError)
        end
      end
    end
    home, homeError = nav.goHome()
    if not home then
      return false, "could not return home: " .. tostring(homeError)
    end
    job.phase = "travel"
    job.active = true
    jobType.save(job)
    return true, "waiting for a mine sector", "cycle"
  end

  local isWanted = jobType.matcher(job)
  local isJunk = jobType.junkMatcher(job)
  local sinceScan = 0
  local minedThisTrip = 0
  local veinTruncated = false
  local workKey = jobType.workKey(job)

  local function record(name)
    job.haul[name] = (job.haul[name] or 0) + 1
    minedThisTrip = minedThisTrip + 1
  end

  --- Relative coordinate for a world block, or nil if the origin is unknown.
  local function relative(worldX, worldY, worldZ)
    return nav.worldToRelative(worldX, worldY, worldZ)
  end

  local origin = nav.origin()
  local laneRelY = origin and (job.laneY - origin.y) or job.laneY
  local targetRelY = origin and (job.targetY - origin.y) or (job.targetY - job.surfaceY)

  local function routeUsesShaft()
    if job.phase == "home" then
      return job.returnViaShaft == true
    end
    return job.phase ~= "travel"
  end

  --- Exact cost of the route home from here, which is what the fuel reserve is
  --- checked against. Straight-line distance would under-count badly: the way
  --- back runs along the trunk, up the shaft, and only then across the sky.
  local function returnDistance()
    local x, y, z = nav.position()
    if nav.distanceHome() == 0 then
      return 0
    end
    if not routeUsesShaft() then
      return nav.distanceHome()
    end

    local shaft = relative(job.shaftX, job.targetY, job.shaftZ)
    if not shaft then
      return nav.distanceHome()
    end
    return math.abs(x - shaft.x)
      + math.abs(z - shaft.z)
      + math.abs(laneRelY - y)
      + math.abs(shaft.x)
      + math.abs(shaft.z)
      + math.abs(laneRelY)
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

  --- Look for ore around the turtle and follow anything found. Costs four turns,
  --- which is the bulk of the time this job spends, so it is throttled by
  --- scanEvery.
  local function scan(force)
    sinceScan = sinceScan + 1
    if not force and sinceScan < job.scanEvery then
      return true
    end
    sinceScan = 0

    local _, reason, kind, truncated, resume = ore.follow(nav, isWanted, record, {
      budget = job.veinBudget,
      radius = job.veinRadius,
      gapBudget = job.veinGapBudget,
      beforeMove = guard,
    })
    inv.dropJunk(isJunk)

    if resume and (truncated or reason) then
      resume.sector = job.sector
      resume.shaftX = job.shaftX
      resume.shaftZ = job.shaftZ
      resume.targetY = job.targetY
      job.pendingVein = resume
      jobType.save(job)
    end

    if truncated then
      -- The vein outlasted the budget. Remember where, so the report says so and
      -- the frontier does not advance past ore we know is still in the ground.
      veinTruncated = true
      ctx.report("mining", "vein larger than budget - will resume here")
    end

    if reason then
      return false, reason, kind
    end
    if truncated then
      return false, "vein budget reached - frontier held", "cycle"
    end
    return true
  end

  local function step()
    local ok, reason, kind = guard()
    if not ok then
      return false, reason, kind
    end
    local moved, err, moveKind = nav.forward()
    if not moved then
      return false, err, moveKind
    end
    local scanned, scanReason, scanKind = scan()
    if not scanned then
      return false, scanReason, scanKind, true
    end
    return true, nil, nil, true
  end

  ---------------------------------------------------------------------------
  -- Phases
  ---------------------------------------------------------------------------

  --- Fly to the airspace directly above this sector's shaft.
  local function travel()
    local head = relative(job.shaftX, job.laneY, job.shaftZ)
    if not head then
      return false, "no world origin - run where on this turtle"
    end

    ctx.report("travel", ("sector %d, lane Y %d"):format(job.sector, job.laneY))
    local ok, err, kind = nav.goTo(head.x, head.y, head.z, guard)
    if not ok then
      return false, err, kind
    end

    job.phase = "descend"
    jobType.save(job)
    return true
  end

  --- Move vertically through the sector shaft. Most profiles descend, while a
  --- high-altitude fuel profile may climb; both must use the same shaft route.
  local function descend()
    while select(2, nav.position()) ~= targetRelY do
      local ok, reason, kind = guard()
      if not ok then
        return false, reason, kind
      end

      local _, y = nav.position()
      local moved, err, moveKind
      if y > targetRelY then
        moved, err, moveKind = nav.down()
      else
        moved, err, moveKind = nav.up()
      end
      if not moved then
        return false, "shaft blocked: " .. tostring(err), moveKind
      end

      _, y = nav.position()
      ctx.report(
        "descend",
        ("Y %d, heading for %d"):format((origin and origin.y or 0) + y, job.targetY)
      )
      local scanned, scanReason, scanKind = scan()
      if not scanned then
        return false, scanReason, scanKind
      end
    end

    job.phase = "transit"
    jobType.save(job)
    return true
  end

  --- The trunk in job-relative terms: where it starts, which way it runs, and
  --- which facing walks along it.
  ---
  --- This conversion is not decoration. The trunk is defined along world X, but
  --- `nav` works in coordinates rotated by whichever way the turtle happened to
  --- face when its origin was set - so world +X is relative +x for one heading
  --- and relative -z for another. Deriving the axis from the two endpoints gets
  --- it right for all four headings; assuming world X is relative x would send
  --- three turtles out of four off at ninety degrees to their own tunnel.
  local function trunkAxis()
    local from = relative(job.trunkFromX, job.targetY, job.trunkZ)
    local to = relative(job.trunkToX, job.targetY, job.trunkZ)
    if not from or not to then
      return nil
    end

    local dx, dz = to.x - from.x, to.z - from.z
    local stepX = dx == 0 and 0 or (dx > 0 and 1 or -1)
    local stepZ = dz == 0 and 0 or (dz > 0 and 1 or -1)
    local facing
    if stepX ~= 0 then
      facing = stepX > 0 and 1 or 3
    else
      facing = stepZ > 0 and 0 or 2
    end
    return { from = from, stepX = stepX, stepZ = stepZ, facing = facing }
  end

  --- Walk out along the trunk to wherever this sector got to last time.
  ---
  --- The first cycle in a sector digs this; later cycles walk an open tunnel, so
  --- the cost of a deep frontier is paid once rather than every trip.
  local function transit()
    local axis = trunkAxis()
    if not axis then
      return false, "no world origin - run where on this turtle"
    end

    -- `frontier` counts fully processed trunk cells. When incomplete, its value
    -- is therefore also the zero-based offset of the next cell to work.
    local along = math.min(job.frontier, job.trunkLength - 1)
    local targetX = axis.from.x + axis.stepX * along
    local targetZ = axis.from.z + axis.stepZ * along

    ctx.report("transit", ("trunk %d/%d"):format(job.frontier, job.trunkLength))
    local ok, err, kind = nav.goTo(targetX, targetRelY, targetZ, guard)
    if not ok then
      return false, err, kind
    end

    job.phase = "mining"
    jobType.save(job)
    return true
  end

  --- Cut one rib perpendicular to the trunk and walk back out of it.
  local function digRib(toLeft)
    local turnOut = toLeft and nav.turnLeft or nav.turnRight
    local turnBack = toLeft and nav.turnLeft or nav.turnRight

    turnOut()
    local dug = 0
    local stoppedReason, stoppedKind = nil, nil
    -- Facing along world +X means left is world -Z and right is world +Z,
    -- regardless of the turtle's saved home heading.
    local low = job.ribReachLow or job.ribReach or 0
    local high = job.ribReachHigh or math.max(0, low - 1)
    local reach = toLeft and low or high
    for _ = 1, reach do
      local ok, reason, kind, advanced = step()
      if advanced then
        dug = dug + 1
      end
      if not ok then
        stoppedReason, stoppedKind = reason, kind
        break
      end
    end

    -- About-face and walk back through the rib we just cleared.
    nav.turnRight()
    nav.turnRight()
    for _ = 1, dug do
      local moved, err = nav.forward()
      if not moved then
        return false, "could not leave rib: " .. tostring(err)
      end
    end
    turnBack()
    return stoppedReason == nil, stoppedReason, stoppedKind
  end

  --- If a Geo Scanner is fitted, take the ore it can see before falling back to
  --- the branch grid. Any failure here is a cue to mine normally, never a stop:
  --- a scan can see ore behind lava, protected blocks, or another turtle's claim.
  local function scannerSweep()
    if not geo.available() then
      return true
    end

    ctx.report("scanning", "geo scanner targeting nearby " .. jobType.name .. " blocks")
    local targets = geo.targets(isWanted, 8, 12)
    if not targets or #targets == 0 then
      return true
    end

    local anchorX, anchorY, anchorZ, anchorFacing = nav.position()
    local function backToAnchor()
      local returned, returnError = nav.goTo(anchorX, anchorY, anchorZ)
      nav.face(anchorFacing)
      return returned, returnError
    end

    for _, target in ipairs(targets) do
      local allowed, scanReason, scanKind = guard()
      if not allowed then
        backToAnchor()
        return false, scanReason, scanKind
      end

      local reached, reachError, reachKind = nav.goTo(target.x, target.y, target.z, guard)
      if not reached then
        local returned, returnError = backToAnchor()
        if not returned then
          return false, "could not leave scanner route: " .. tostring(returnError)
        end
        if reachKind == "fuel" or reachKind == "recalled" then
          return false, reachError, reachKind
        end
        ctx.report("scanning", "target skipped: " .. tostring(reachError))
        break
      end
      record(target.name)
    end

    local returned, returnError = backToAnchor()
    if not returned then
      return false, "could not return from scanned ore: " .. tostring(returnError)
    end
    inv.dropJunk(isJunk)
    return true
  end

  --- Extend the trunk and cut ribs, advancing the sector frontier as it goes.
  local function mine()
    local axis = trunkAxis()
    if not axis then
      return false, "no world origin - run where on this turtle"
    end

    -- A reboot may happen inside a rib or recursive vein walk. The recursion
    -- stack is not persistent, so always recover to the durable frontier cell
    -- before doing more work. In the normal path this is already our position
    -- and costs nothing.
    local along = math.min(job.frontier, job.trunkLength - 1)
    local resumed, resumeError, resumeKind = nav.goTo(
      axis.from.x + axis.stepX * along,
      targetRelY,
      axis.from.z + axis.stepZ * along,
      guard
    )
    if not resumed then
      return false, "could not recover frontier: " .. tostring(resumeError), resumeKind
    end

    -- A budget/recall/fuel stop can happen deep inside a vein. `ore.follow`
    -- unwinds to the trunk so the turtle can get home, but the remaining ore is
    -- then separated from the trunk by already-mined air. Revisit the persisted
    -- reachable cell before advancing the durable frontier.
    if type(job.pendingVein) == "table" then
      local pending = job.pendingVein
      local target = pending.world and relative(pending.x, pending.y, pending.z) or pending
      local anchorX, anchorY, anchorZ = nav.position()
      ctx.report("mining", "resuming unfinished vein")
      local reached, reachError, reachKind = nav.goTo(target.x, target.y, target.z, guard)
      if not reached then
        return false, "could not reach unfinished vein: " .. tostring(reachError), reachKind
      end

      local scanned, scanReason, scanKind = scan(true)
      local returned, returnError = nav.goTo(anchorX, anchorY, anchorZ)
      if not returned then
        return false, "could not leave unfinished vein: " .. tostring(returnError)
      end
      if not scanned then
        return false, scanReason, scanKind
      end

      job.pendingVein = nil
      jobType.save(job)
    end

    if job.frontier == 0 then
      local swept, sweepReason, sweepKind = scannerSweep()
      if not swept then
        return false, sweepReason, sweepKind
      end
    end

    -- Face along the trunk, which always runs from its low world X towards its
    -- high world X, so a saved frontier means the same thing on every visit and
    -- to every turtle regardless of which way each one was facing at setup.
    nav.face(axis.facing)

    while job.frontier < job.trunkLength do
      ctx.report(
        "mining",
        ("sector %d trunk %d/%d"):format(job.sector, job.frontier, job.trunkLength)
      )

      -- Process the cell we are standing in before advancing its durable
      -- checkpoint. This keeps the final move inside the sector and means a
      -- recall, peer, or truncated vein repeats this cell rather than skipping
      -- it after a reboot.
      local allowed, guardReason, guardKind = guard()
      if not allowed then
        return false, guardReason, guardKind
      end
      local scanned, scanReason, scanKind = scan()
      if not scanned then
        return false, scanReason, scanKind
      end

      local cellNumber = job.frontier + 1
      if cellNumber % job.branchSpacing == 0 then
        local left, leftReason, leftKind = digRib(true)
        if not left then
          return false, leftReason, leftKind
        end
        local right, rightReason, rightKind = digRib(false)
        if not right then
          return false, rightReason, rightKind
        end
      end

      job.frontier = job.frontier + 1
      jobType.save(job)

      if job.frontier < job.trunkLength then
        local canAdvance, reason, kind = guard()
        if not canAdvance then
          return false, reason, kind
        end
        local moved, moveError, moveKind = nav.forward()
        if not moved then
          return false, moveError, moveKind
        end
      end
    end

    return true, nil, nil, true -- sector exhausted
  end

  --- The trip proper. Whatever this returns, the caller walks home.
  local function journey()
    if job.phase == "travel" then
      local ok, err, kind = travel()
      if not ok then
        return false, err, kind
      end
    end

    if job.phase == "descend" then
      local ok, err, kind = descend()
      if not ok then
        return false, err, kind
      end
    end

    if job.phase == "transit" then
      local ok, err, kind = transit()
      if not ok then
        return false, err, kind
      end
    end

    if job.phase == "mining" then
      return mine()
    end

    return true
  end

  local ok, reason, stopKind, exhausted = journey()

  ---------------------------------------------------------------------------
  -- Coming home is unconditional. Every failure path above still ends here.
  ---------------------------------------------------------------------------

  if job.phase ~= "home" then
    job.returnViaShaft = job.phase ~= "travel" and nav.distanceHome() > 0
  end
  job.phase = "home"
  jobType.save(job)
  ctx.report("returning", reason and tostring(reason) or "loaded, heading back")

  inv.dropJunk(isJunk)

  -- Once mining has started, unwind through the shaft at any depth. This is
  -- deliberately stage-persisted: Fuel can mine above the cruise lane, and a
  -- reboot while returning must not cut a direct tunnel from there to home.
  local _, y = nav.position()
  if nav.distanceHome() > 0 and job.returnViaShaft then
    local worldY = (origin and origin.y or job.surfaceY) + y
    local shaft = relative(job.shaftX, worldY, job.shaftZ)
    if shaft then
      local returned, returnError = nav.goTo(shaft.x, y, shaft.z)
      if not returned then
        job.active = true
        jobType.save(job)
        return false, "could not reach shaft: " .. tostring(returnError)
      end
    end
    while select(2, nav.position()) ~= laneRelY do
      local _, currentY = nav.position()
      local surfaced, surfaceError
      if currentY < laneRelY then
        surfaced, surfaceError = nav.up()
      else
        surfaced, surfaceError = nav.down()
      end
      if not surfaced then
        job.active = true
        jobType.save(job)
        return false, "could not surface: " .. tostring(surfaceError)
      end
    end
    job.returnViaShaft = false
    jobType.save(job)
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

  -- Tell the base how far this sector got. Doing it here, after the route is
  -- unwound, means the frontier reported is one the next turtle can actually
  -- walk to. A truncated vein holds the frontier back deliberately.
  if veinTruncated then
    ctx.report("returning", "sector frontier held for an unfinished vein")
  end
  site.report(workKey, job.sector, job.frontier, minedThisTrip, exhausted == true)

  -- The configured route remains active at home. Persisting `false` here made a
  -- tiny power-loss window before the cycle handoff reopen interactive setup on
  -- reboot, even though the sector had been reported correctly.
  job.active = true
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
    if
      stopKind == "fuel"
      or stopKind == "cycle"
      or stopKind == "recalled"
      or stopKind == "peer"
    then
      if stopKind == "peer" then
        stopKind = "cycle"
        reason = "fleet traffic held this cell - will retry"
      end
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
  if exhausted then
    return true, ("sector %d worked out"):format(job.sector), "cycle"
  end
  return true, jobType.label .. " cycle complete", "cycle"
end

return runner
