--- Autonomous focused-mining movement and return lifecycle.
---
--- The route has five parts and every one of them is reused between cycles:
---
---   travel   fly at this sector's lane altitude to above its shaft
---   descend  break the ground, seal it overhead, drop to the profile's target Y
---   transit  walk the trunk tunnel out to the frontier this sector reached
---   mining   extend the trunk, cut ribs, follow veins, advance the frontier
---   home     back along the trunk, out through the shaft head, reseal, fly home
---
--- The reuse is the whole point. A cycle that ends early - full inventory, fuel
--- reserve, recall - no longer throws the route away. The frontier is saved, so
--- the next cycle comes back down the same hole to the same tunnel and picks up
--- where this one stopped, instead of rolling a fresh random bearing and leaving
--- a half-mined vein and a new crater behind it.
---
--- Reuse bounded how many holes exist; it did not make them safe. The shaft is
--- therefore only ever open while the turtle is inside it - see `turtle/access`
--- for the cap itself and this file for when it is moved. The geometry is
--- unchanged: capping costs digs and placements, not moves, so the exact return
--- fuel reserve still describes the route the turtle actually flies.

local access = require("os.turtle.device.access")
local depot = require("os.turtle.device.depot")
local fuel = require("os.turtle.device.fuel")
local geo = require("os.turtle.device.geo")
local inv = require("os.turtle.device.inv")
local nav = require("os.turtle.device.nav")
local ore = require("os.turtle.device.ore")
local safety = require("os.turtle.jobs.common.safety")
local site = require("os.turtle.site")
local surface = require("os.turtle.jobs.prospecting.surface")

local runner = {}

--- Consecutive fruitless cycles before the sector is handed back, and before the
--- turtle stops asking. Two is generous for an ordinary obstruction and short
--- enough that a fleet does not spend a night commuting to ground it cannot dig.
local STALL_SECTOR = 2
local STALL_PARK = 4

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
  local startFrontier = job.frontier or 0

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

  ---------------------------------------------------------------------------
  -- Surface access
  ---------------------------------------------------------------------------

  local guard -- forward declaration: the surface controller calls it too

  local control = surface.new({
    job = job,
    originY = origin and origin.y or job.surfaceY,
    laneRelY = laneRelY,
    targetRelY = targetRelY,
    relative = relative,
    isWanted = isWanted,
    isJunk = isJunk,
    report = ctx.report,
    save = function()
      jobType.save(job)
    end,
    guard = function()
      return guard()
    end,
  })

  local function routeUsesShaft()
    if job.phase == "home" then
      return job.returnViaShaft == true
    end
    return job.phase ~= "travel"
  end

  --- Exact cost of the route home from here, which is what the fuel reserve is
  --- checked against. Straight-line distance would under-count badly: the way
  --- back runs along the trunk, up the shaft, and only then across the sky.
  ---
  --- Moving the cap costs digs and placements rather than moves, so it adds
  --- nothing to this sum. `surface.RESERVE` covers the bounded detours: probing
  --- along the trunk for a sealable head, and walking back under an opening a
  --- crash interrupted.
  local function returnDistance()
    local x, y, z = nav.position()
    if nav.distanceHome() == 0 then
      return 0
    end
    if not routeUsesShaft() then
      return nav.distanceHome()
    end

    local shaft = relative(control:headX(), job.targetY, control:headZ())
    if not shaft then
      return nav.distanceHome()
    end
    return math.abs(x - shaft.x)
      + math.abs(z - shaft.z)
      + math.abs(laneRelY - y)
      + math.abs(shaft.x)
      + math.abs(shaft.z)
      + math.abs(laneRelY)
      + surface.RESERVE
  end

  --- Checked before every move. Returns false to end the trip early, with the
  --- reason - the caller always walks home afterwards regardless.
  function guard()
    local safe, reason, kind = safety.check(ctx, jobType.SAFETY_MARGIN, returnDistance())
    if not safe then
      return false, reason, kind
    end

    if inv.freeSlots() <= 1 then
      inv.dropJunk(isJunk, access.SLOT)
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
    inv.dropJunk(isJunk, access.SLOT)

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
    local head = relative(control:headX(), job.laneY, control:headZ())
    if not head then
      return false, "no world origin - run where on this turtle"
    end

    ctx.report("travel", ("sector %d, lane Y %d"):format(job.sector, job.laneY))
    -- Fly over the ground rather than through it. The cruise lane is set from
    -- the base's surface, so a sector on a hillside sits above it, and the old
    -- straight crossing bored a tunnel through the hill on the first visit.
    local ok, err, kind = nav.goTo(head.x, head.y, head.z, guard, { climb = nav.CLIMB_LIMIT })
    if not ok then
      return false, err, kind
    end

    job.phase = "descend"
    jobType.save(job)
    return true
  end

  --- Move vertically through the sector shaft. Most profiles descend, while a
  --- high-altitude fuel profile may climb; both must use the same shaft route.
  --- Only a descent breaks the surface, so only a descent has a cap to manage.
  local function descend()
    local _, startY = nav.position()

    if targetRelY < startY and not control:sealedIn() then
      local opened, openError, openKind = control:open()
      if not opened then
        return false, openError, openKind
      end
    end

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

  --- Get past a trunk cell that must not be broken, by going over or under it.
  ---
  --- The trunk is one block tall, so a lava pocket sitting in it stops the whole
  --- tunnel. Climbing a block, crossing, and dropping back rejoins the same
  --- tunnel further on, which keeps the saved frontier meaning what it has
  --- always meant.
  ---
  --- Returns how many extra cells were skipped, because that has to be added to
  --- the frontier: the obstructed cell is never going to be worked, and a
  --- frontier that disagrees with where the turtle is standing would send the
  --- next cycle's recovery straight back into the lava.
  ---
  --- Every attempt unwinds cleanly, so a failed detour costs a few moves rather
  --- than the turtle's position on its own tunnel.
  local function stepAround(originalError)
    for _, route in ipairs({ { nav.up, nav.down }, { nav.down, nav.up } }) do
      local lift, drop = route[1], route[2]
      if lift() then
        local crossed = 0
        while crossed < 2 do
          if not nav.forward() then
            break
          end
          crossed = crossed + 1
          if drop() then
            return true, crossed - 1
          end
        end
        for _ = 1, crossed do
          nav.back()
        end
        drop()
      end
    end
    return false, 0, ("trunk blocked: %s"):format(tostring(originalError)), "blocked"
  end

  --- Cut one rib perpendicular to the trunk and walk back out of it.
  ---
  --- A rib that runs into lava, a protected block, or bedrock is simply shorter
  --- than the sector allows. That is a fact about the ground, not a failure of
  --- the trip, and ending the cycle over it means one lava pocket at diamond
  --- level costs a whole commute.
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

    if stoppedReason and nav.ROUTE_AROUND[stoppedKind or ""] then
      ctx.report("mining", ("rib stopped short: %s"):format(tostring(stoppedReason)))
      return true
    end
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
    inv.dropJunk(isJunk, access.SLOT)
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
        if not moved and nav.ROUTE_AROUND[moveKind or ""] then
          -- Something in the trunk that must not be broken. Going over or under
          -- it keeps the tunnel and the saved frontier meaningful; the cell
          -- itself is simply skipped.
          local detoured, skipped, detourError, detourKind = stepAround(moveError)
          if detoured then
            if skipped > 0 then
              ctx.report("mining", ("stepped over %d blocked trunk cell(s)"):format(skipped))
              job.frontier = math.min(job.trunkLength, job.frontier + skipped)
              jobType.save(job)
            end
            moved = true
          else
            moveError, moveKind = detourError, detourKind
          end
        end
        if not moved then
          return false, moveError, moveKind
        end
      end
    end

    return true, nil, nil, true -- sector exhausted
  end

  --- The trip proper. Whatever this returns, the caller walks home.
  local function journey()
    control:adoptLegacy()

    local restored, restoreError = control:restore()
    if not restored then
      return false, restoreError
    end

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

  inv.dropJunk(isJunk, access.SLOT)

  -- Once mining has started, unwind through the shaft at any depth. This is
  -- deliberately stage-persisted: Fuel can mine above the cruise lane, and a
  -- reboot while returning must not cut a direct tunnel from there to home.
  local sealFailure = nil
  local _, y = nav.position()
  if nav.distanceHome() > 0 and job.returnViaShaft then
    local shaft = relative(control:headX(), control:worldY(), control:headZ())
    if shaft then
      local returned, returnError = nav.goTo(shaft.x, y, shaft.z)
      if not returned then
        job.active = true
        jobType.save(job)
        return false, "could not reach shaft: " .. tostring(returnError)
      end
    end

    -- Out through the cap and shut it again before climbing to the lane. A
    -- failure here is recorded rather than thrown: the turtle still has to get
    -- home, and an exposed shaft is reported once it is standing on its chest.
    local resealed, resealReason = control:leave()
    if not resealed then
      sealFailure = tostring(resealReason)
      ctx.report("sealing", sealFailure)
    end

    local lowestY = control:lowestSafeY(laneRelY)
    while select(2, nav.position()) ~= lowestY do
      local _, currentY = nav.position()
      local surfaced, surfaceError
      if currentY < lowestY then
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
    -- Fuel stays aboard, and so does the reserved cap slot: next cycle's first
    -- act is to seal a shaft behind itself, and the cheapest way to guarantee it
    -- can is to keep the stack of cobblestone it already carries.
    local keep = function(detail, slot)
      return fuel.isFuel(detail, slot)
        or (slot == access.SLOT and access.isFiller(detail, slot, isWanted))
    end

    -- With a shared depot this is the failure that actually happens: the chest
    -- backs up, the drop silently does nothing, and the turtle would otherwise
    -- park looking healthy while carrying a full load it can never put down.
    -- Every adjacent container is tried before saying so.
    local delivered, remaining, used = depot.unload(keep)
    job.delivered = job.delivered + delivered
    depotFull = remaining > 0
    if #used > 1 then
      ctx.report("returning", "home chest full - overflowed " .. table.concat(used, ", "))
    end
  end

  -- A cycle that mined nothing and moved the frontier nowhere achieved nothing,
  -- whatever it reported. One of those is ordinary - lava in the way, a peer in
  -- the corridor. A run of them means the ground cannot be worked, and the
  -- honest responses are to try different ground and then to stop.
  local barren = minedThisTrip == 0 and job.frontier <= startFrontier and not veinTruncated
  job.stalls = barren and (math.floor(tonumber(job.stalls) or 0) + 1) or 0
  local giveUpSector = job.stalls >= STALL_SECTOR
  local giveUp = job.stalls >= STALL_PARK

  -- Tell the base how far this sector got. Doing it here, after the route is
  -- unwound, means the frontier reported is one the next turtle can actually
  -- walk to. A truncated vein holds the frontier back deliberately.
  if veinTruncated then
    ctx.report("returning", "sector frontier held for an unfinished vein")
  end
  if giveUpSector and not exhausted then
    ctx.report("returning", ("sector %d cannot be worked - handing it back"):format(job.sector))
  end
  site.report(workKey, job.sector, job.frontier, minedThisTrip, exhausted == true or giveUpSector)

  -- Physical state, separate from progress. Held at the base it outlives this
  -- turtle: a replacement skips re-surveying the head, an exposed one is visible
  -- from the dashboard, and the next turtle to ask for work is sent to seal it.
  site.surface(job.sector, control:snapshot(sealFailure))

  -- The configured route remains active at home. Persisting `false` here made a
  -- tiny power-loss window before the cycle handoff reopen interactive setup on
  -- reboot, even though the sector had been reported correctly.
  job.active = true
  jobType.save(job)

  if not home then
    return false, "could not return home: " .. tostring(homeError)
  end

  -- An open shaft outranks every other way a cycle can end badly, including a
  -- full chest: one is inconvenient and the other is a hole somebody falls into.
  -- Reported as a failure so the turtle parks and the dashboard row goes red
  -- rather than quietly starting another cycle over an exposed sector.
  if sealFailure then
    return false, sealFailure
  end

  if depotFull then
    -- Surfaced as a failure so the row goes red on the dashboard. A turtle
    -- holding a full load it cannot deposit is stuck, not finished.
    return false, "depot full - empty the chest below me"
  end

  -- Nothing has worked for several cycles running. Retrying costs a full commute
  -- each time and produces nothing, so stop and say so rather than burning fuel
  -- overnight against ground that cannot be dug.
  if giveUp then
    job.stalls = 0
    jobType.save(job)
    return false,
      ("no progress in %d cycles - last stop: %s"):format(
        STALL_PARK,
        tostring(reason or "nothing mined")
      )
  end

  if not ok then
    if
      stopKind == "fuel"
      or stopKind == "cycle"
      or stopKind == "recalled"
      or stopKind == "peer"
      or nav.ROUTE_AROUND[stopKind or ""]
    then
      if stopKind == "peer" then
        stopKind = "cycle"
        reason = "fleet traffic held this cell - will retry"
      elseif nav.ROUTE_AROUND[stopKind or ""] then
        -- Lava, a protected block, or bedrock somewhere on the route. The next
        -- cycle re-plans around it; the stall counter above is what stops this
        -- becoming an endless commute.
        stopKind = "cycle"
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
