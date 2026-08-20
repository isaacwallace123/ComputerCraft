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
--- The turtle ends where it started in every path through this function, which
--- is the property worth reading the code for rather than taking on trust.
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

  -- Forward, not up. Up is usually free and would give the height twice and the
  -- heading never; forward is the one direction whose displacement names the way
  -- the turtle is pointing.
  local moved, reason = body.move("forward")
  if not moved then
    -- Deliberately not dug through. A turtle that mined a block to find out
    -- where it was would be a turtle that damages whatever it was parked in
    -- front of - a chest, somebody's wall - to answer a question about itself.
    return nil, "blocked: " .. tostring(reason or "cannot step forward")
  end

  local after, secondWhy = calibrate.locate(locator, timeout)

  -- Back first, and then decide. Reversing only on success would leave a turtle
  -- that failed the second fix standing one block from where its saved origin
  -- says it is, which is worse than not having calibrated at all.
  local returned = body.move("back")

  if after == nil then
    return nil, secondWhy
  end
  if not returned then
    return nil, "moved forward and could not step back - this turtle has shifted"
  end

  local heading, headingWhy = fix.headingFrom(before, after)
  if heading == nil then
    return nil, headingWhy
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
