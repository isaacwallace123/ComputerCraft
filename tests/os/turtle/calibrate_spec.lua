--- A turtle finding out where it is, and putting itself back.
---
--- The property worth a spec rather than a read-through: **the turtle ends where
--- it started on every path**. A calibration that gave up one block from where
--- it began would leave a machine whose saved origin - the old one, still
--- trusted - is now a block wrong, and everything downstream of it is dead
--- reckoning from a lie.

local expect = require("support.expect")
local it = require("support.spec").it

local calibrate = require("os.turtle.calibrate")

--- A turtle on a strip of ground, and a constellation that can see it.
---
--- `blocked` makes the step forward fail, `lost` makes the constellation stop
--- answering after the first fix, and `stuck` lets it go forward and not back.
local function world(options)
  options = options or {}
  local self = { x = 0, y = 64, z = 0, facing = 0, moves = {}, fixes = 0 }

  -- 0 north (-Z), 1 east (+X), 2 south (+Z), 3 west (-X), which is the order a
  -- turtle turns through when it turns right.
  local STEP = {
    [0] = { x = 0, z = -1 },
    [1] = { x = 1, z = 0 },
    [2] = { x = 0, z = 1 },
    [3] = { x = -1, z = 0 },
  }

  self.body = {
    turn = function(way)
      self.facing = (self.facing + (way == "right" and 1 or 3)) % 4
      return true
    end,

    move = function(direction)
      self.moves[#self.moves + 1] = direction

      if direction == "forward" then
        if options.blocked then
          return false, "Out of fuel"
        end
        if options.groundBlocked and self.y == 64 then
          return false, "Movement obstructed"
        end
        if options.blockedFacing == self.facing then
          return false, "Movement obstructed"
        end
        self.x = self.x + STEP[self.facing].x
        self.z = self.z + STEP[self.facing].z
        return true
      end

      if direction == "back" then
        if options.stuck then
          return false, "movement obstructed"
        end
        self.x = self.x - STEP[self.facing].x
        self.z = self.z - STEP[self.facing].z
        return true
      end

      if direction == "up" then
        if options.ceiling then
          return false, "movement obstructed"
        end
        self.y = self.y + 1
        return true
      end

      if direction == "down" then
        self.y = self.y - 1
        return true
      end

      return false, "no"
    end,
  }

  self.locator = {
    gps = function()
      self.fixes = self.fixes + 1
      if options.lost and self.fixes > 1 then
        return nil
      end
      if options.none then
        return nil
      end
      if options.fractional then
        return self.x + 0.5, self.y, self.z
      end
      return self.x, self.y, self.z
    end,
    saved = function()
      return nil
    end,
  }

  return self
end

it("a turtle works out both numbers and steps back where it was", function()
  local turtle = world()

  local found, why = calibrate.run(turtle.body, turtle.locator)
  expect.truthy(found ~= nil, tostring(why))
  found = found or {}
  expect.equal(found.x, 0)
  expect.equal(found.y, 64)
  expect.equal(found.z, 0, "the position reported is where it started, not where it stepped")
  expect.equal(found.heading, 0, "it was pointing north")

  -- Where it started. This is the assertion the whole file is for.
  expect.equal(turtle.z, 0)
  expect.equal(#turtle.moves, 2, "one step out, one back")
end)

it("no constellation is a sentence, not a guess", function()
  local turtle = world({ none = true })
  local found, why = calibrate.run(turtle.body, turtle.locator)

  expect.equal(found, nil)
  expect.contains(why, "no GPS")

  -- And it did not move to find that out. Asking first is what makes a turtle
  -- parked in front of a chest safe to run this on.
  expect.equal(#turtle.moves, 0)
end)

it("a turtle blocked in front turns and tries the other three ways", function()
  -- Most parked turtles are parked *against* something: a chest they unload
  -- into, the wall of the room they live in. The first version stepped forward,
  -- gave up, and reported "no position" on every machine in the fleet with a
  -- constellation overhead.
  local turtle = world({ blockedFacing = 0 })

  local found, why = calibrate.run(turtle.body, turtle.locator)
  expect.truthy(found ~= nil, tostring(why))
  found = found or {}

  -- The heading reported is what it was facing *before* it turned, which is what
  -- everything else in the system means by this turtle's heading.
  expect.equal(found.heading, 0, "it was pointing north all along")
  expect.equal(turtle.facing, 0, "and it is facing that way again")
  expect.equal(turtle.x, 0, "back where it started")
  expect.equal(turtle.z, 0)
end)

it("a turtle boxed in at ground level goes up one and tries again", function()
  -- Which a turtle parked in a room usually is: walls on two sides, a chest on
  -- a third. One block up is almost always clear.
  local turtle = world({ groundBlocked = true })

  local found, why = calibrate.run(turtle.body, turtle.locator)
  expect.truthy(found ~= nil, tostring(why))
  found = found or {}

  -- The position reported is the fix taken on the ground, not the one taken a
  -- block higher: the turtle came back down to it.
  expect.equal(found.y, 64)
  expect.equal(turtle.y, 64, "and it is back at ground level")
  expect.equal(turtle.facing, 0, "still pointing the way it was")
end)

it("a turtle that cannot move at all reports what the turtle API said", function()
  -- The first version said "boxed in on all four sides", which is a diagnosis
  -- rather than an observation - and it was wrong on a turtle standing in the
  -- open, where the real answer was in the reason string it was discarding.
  -- "Out of fuel" and "Movement obstructed" call for completely different
  -- things, and this is the only place either of them is visible.
  local turtle = world({ blocked = true, ceiling = true })
  local found, why = calibrate.run(turtle.body, turtle.locator)

  expect.equal(found, nil)
  expect.contains(why, "Out of fuel", "CC's own words, not a paraphrase")
  expect.equal(turtle.z, 0, "still where it was")
  expect.equal(turtle.facing, 0, "and still pointing the way it was")
end)

it("a fix lost between the two steps still puts the turtle back", function()
  -- Reversing only on success would leave a turtle standing one block from where
  -- its saved origin says it is - which is worse than not having calibrated,
  -- because the origin is still trusted.
  local turtle = world({ lost = true })
  local found = calibrate.run(turtle.body, turtle.locator)

  expect.equal(found, nil)
  expect.equal(turtle.z, 0, "back where it started")
  expect.equal(turtle.moves[2], "back", "it reversed before deciding")
end)

it("a turtle that cannot get back says so, because it has moved", function()
  local turtle = world({ stuck = true })
  local found, why = calibrate.run(turtle.body, turtle.locator)

  expect.equal(found, nil)
  expect.contains(why, "shifted", "the one failure that leaves the machine somewhere new")
end)

it("a fix between blocks is refused before anything moves", function()
  local turtle = world({ fractional = true })
  local found, why = calibrate.run(turtle.body, turtle.locator)

  expect.equal(found, nil)
  expect.contains(why, "between blocks")
  expect.equal(#turtle.moves, 0)
end)

it("a machine with no arms is refused rather than erroring", function()
  local turtle = world()
  local found, why = calibrate.run(nil, turtle.locator)
  expect.equal(found, nil)
  expect.contains(why, "cannot move")

  expect.equal(calibrate.locate(nil), nil, "and one with no locator")
end)

it("a turtle that already knows where it is is left alone", function()
  -- Re-deriving a position it has would spend a move and a GPS round trip on
  -- every boot to learn what it already knew - and would do it while parked in
  -- front of a chest, where the step forward fails.
  expect.falsy(calibrate.needed({
    hasOrigin = function()
      return true
    end,
  }))
  expect.truthy(calibrate.needed({
    hasOrigin = function()
      return false
    end,
  }))
  expect.falsy(calibrate.needed(nil))
end)
