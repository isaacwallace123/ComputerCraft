--- Finding out where a turtle is, and which way it points, without asking anybody.
---
--- ## What this replaces
---
--- Walking to every turtle in the fleet, pressing F3, reading two numbers off
--- the debug screen and typing them in - once per turtle, again every time one
--- is moved, and again for anybody who mistypes. It was the last piece of setup
--- that scaled with the number of machines.
---
--- ## The move is the whole trick
---
--- `gps.locate` answers a position and withholds the heading, because a
--- stationary turtle looks identical from every direction. So: take a fix, step
--- one block, take another, and the difference is the way it was pointing. Then
--- step back, so a calibration leaves the turtle exactly where it was found.
---
--- One block of fuel and about a second, against a person walking to every
--- turtle in the fleet.
---
--- ## It puts the turtle back, including when it fails
---
--- The step back happens whether the second fix worked or not. A calibration
--- that gave up one block from where it started would leave a turtle whose
--- saved origin - the old one, still trusted - is now a block wrong, and
--- everything downstream of it is dead reckoning from a lie.
---
--- ## It refuses more than it accepts
---
--- No fix, a fix between blocks, a blocked step, a step that moved two axes: all
--- refused with a sentence rather than rounded to something plausible. A heading
--- is the one number nothing checks afterwards - a turtle with the wrong one
--- drives away from home in a straight line, and the first anybody knows is that
--- it stopped answering.

local fix = require("domain.gps.fix")

local calibrate = {}

--- How long to wait for the constellation, in seconds.
---
--- Two. `gps.locate` polls four hosts and gives up on its own; the number here
--- only decides how long a turtle with no constellation in range spends finding
--- that out, and it does it on every attempt.
calibrate.TIMEOUT = 2

--- Ask the constellation for a whole-block fix.
---
--- Returns the block, or nil and a sentence. A fractional answer means the
--- turtle was between two blocks when it asked, and writing that down as an
--- origin would put every relative coordinate in the job half a block out for
--- the life of the machine.
function calibrate.locate(locator, timeout)
  if locator == nil then
    return nil, "this machine has no locator"
  end

  local x, y, z = locator.gps(timeout or calibrate.TIMEOUT)
  if x == nil then
    return nil, "no GPS - four hosts have to be loaded and in range"
  end

  local ok, why = fix.usable({ x = x, y = y, z = z })
  if not ok then
    return nil, why
  end
  return fix.blockOf({ x = x, y = y, z = z })
end

--- Where this turtle is and which way it faces.
---
--- Returns `{ x, y, z, heading }`, or nil and a sentence somebody can act on.
--- `body` is the turtle; `locator` is the constellation.
---
--- ## It tries all four directions
---
--- The first version stepped forward and gave up if the block ahead was solid -
--- which is most parked turtles, because a turtle is usually parked *against*
--- something: a chest it unloads into, the wall of the room it lives in. The
--- fleet duly reported "no position" on every machine with a constellation
--- overhead and nothing to say why.
---
--- So it turns right and tries again, up to four times. The heading it measures
--- is the direction it was facing *after* those turns, so the answer is that
--- minus however many it made.
---
--- ## The turtle ends where it started, facing where it started
---
--- Every path through this function, including every failure. A calibration that
--- left a turtle one block over or a quarter-turn round would leave a machine
--- whose saved origin - the old one, still trusted - is now wrong, and
--- everything downstream of it is dead reckoning from a lie.
function calibrate.run(body, locator, options)
  options = options or {}
  local timeout = options.timeout or calibrate.TIMEOUT

  local before, why = calibrate.locate(locator, timeout)
  if before == nil then
    return nil, why
  end

  if body == nil then
    return nil, "this machine cannot move"
  end

  --- Undo the turns, whatever happened.
  local function faceBack(turns)
    for _ = 1, turns do
      body.turn("left")
    end
  end

  --- Probe the four horizontal directions from wherever the turtle is standing.
  ---
  --- `from` is a fix taken at *this* level. It is a parameter rather than the
  --- outer `before` because the fallback probes a block higher, and comparing a
  --- fix taken up there against one taken on the ground is a height change -
  --- which `fix.headingFrom` correctly refuses, since that is exactly what two
  --- fixes from different moments in a job look like.
  ---
  --- Returns the heading the turtle was facing when it started probing, or nil
  --- and the reason the last attempt gave. It is left facing the way it began in
  --- both cases.
  local function probe(from)
    local blocked = nil

    for turns = 0, 3 do
      local moved, reason = body.move("forward")

      if moved then
        local after, secondWhy = calibrate.locate(locator, timeout)

        -- Back first, and then decide. Reversing only on success would leave a
        -- turtle that failed the second fix standing one block from where its
        -- saved origin says it is.
        local returned = body.move("back")
        faceBack(turns)

        if after == nil then
          return nil, secondWhy
        end
        if not returned then
          return nil, "moved and could not step back - this turtle has shifted"
        end

        local heading, headingWhy = fix.headingFrom(from, after)
        if heading == nil then
          return nil, headingWhy
        end

        -- What it was facing before the turns, which is what everything else in
        -- the system means by this turtle's heading.
        return (heading - turns) % 4
      end

      blocked = reason
      if turns < 3 then
        -- Deliberately not dug through. A turtle that mined a block to find out
        -- where it was would damage whatever it was parked in front of - a
        -- chest, somebody's wall - to answer a question about itself.
        body.turn("right")
      end
    end

    faceBack(3)

    -- CC's own words, not a paraphrase.
    --
    -- The first version said "boxed in on all four sides", which is a diagnosis
    -- rather than an observation - and it was wrong on a turtle standing in the
    -- open, where the real answer was in the reason string being thrown away.
    -- "Out of fuel" and "Movement obstructed" call for completely different
    -- things and this is the only place either of them is visible.
    return nil, "blocked: " .. tostring(blocked or "cannot step")
  end

  local heading, blockedWhy = probe(before)

  -- Boxed in at this level, which a turtle parked in a room usually is: walls on
  -- two sides and a chest on a third. One block up is almost always clear.
  --
  -- The position reported is still the fix taken on the ground - the turtle
  -- comes back down to it - but the *heading* is worked out from a fresh fix up
  -- there, because a turtle that has changed height between two fixes has not
  -- taken one step.
  if heading == nil and body.move("up") then
    local above = calibrate.locate(locator, timeout)

    -- Written as an `if` rather than `above and probe(above) or nil`, because
    -- `and`/`or` collapses two return values into one and the reason would come
    -- back nil every time - which is how a diagnostic quietly stops diagnosing.
    local higher, whyUp = nil, nil
    if above ~= nil then
      higher, whyUp = probe(above)
    else
      whyUp = "lost the fix a block up"
    end

    -- Down before deciding, for the same reason the horizontal probe steps back
    -- before deciding: a turtle left a block above where its origin says it is
    -- is worse than one that never tried.
    body.move("down")

    if higher ~= nil then
      heading = higher
    else
      blockedWhy = whyUp or blockedWhy
    end
  end

  if heading == nil then
    return nil, blockedWhy
  end

  return { x = before.x, y = before.y, z = before.z, heading = heading }
end

--- Does this turtle need calibrating?
---
--- Only when it has no origin at all. A turtle that has one is dead-reckoning
--- from it, and re-deriving a position it already has would spend a move and a
--- second on every boot to learn what it already knew - and would do it while
--- parked in front of a chest, where the step forward fails.
function calibrate.needed(nav)
  return nav ~= nil and not nav.hasOrigin()
end

return calibrate
