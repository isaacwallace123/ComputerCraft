--- Recovering a heading from two GPS fixes.
---
--- The heading is the one number in this system that nothing checks afterwards.
--- A position that is wrong is noticed the first time a turtle walks somewhere
--- unexpected; a heading that is a quarter-turn out sends it away from home in a
--- straight line, and the first anybody knows is that it stopped answering.
---
--- So every branch below refuses rather than rounds, and each of them is a thing
--- that has happened to somebody's turtle.

local expect = require("support.expect")
local it = require("support.spec").it

local fix = require("domain.gps.fix")

local function at(x, y, z)
  return { x = x, y = y, z = z }
end

it("a step names the direction it was pointing", function()
  -- The compass is `os/turtle/device/nav.lua`'s, and it is stated in both files
  -- because two of them disagreeing is a fleet that mines in the wrong
  -- direction: 0 north (-Z), 1 east (+X), 2 south (+Z), 3 west (-X).
  expect.equal(fix.headingFrom(at(0, 64, 0), at(0, 64, -1)), 0, "north is -Z")
  expect.equal(fix.headingFrom(at(0, 64, 0), at(1, 64, 0)), 1, "east is +X")
  expect.equal(fix.headingFrom(at(0, 64, 0), at(0, 64, 1)), 2, "south is +Z")
  expect.equal(fix.headingFrom(at(0, 64, 0), at(-1, 64, 0)), 3, "west is -X")
end)

it("it works away from the origin, including across zero", function()
  -- Negative coordinates are where sign bugs live, and the last one of those in
  -- this repository swallowed a minus sign off a Y and could never be corrected
  -- because the intended value was unknowable.
  expect.equal(fix.headingFrom(at(-138, -59, -1176), at(-138, -59, -1177)), 0)
  expect.equal(fix.headingFrom(at(-1, 5, -1), at(0, 5, -1)), 1, "crossing zero eastward")
end)

it("a turtle that did not move is refused, not guessed at", function()
  -- The usual cause is a solid block ahead and a `move` whose failure the caller
  -- believed anyway. Picking a direction here would write a heading nothing can
  -- check, on the evidence that nothing happened.
  local heading, why = fix.headingFrom(at(0, 64, 0), at(0, 64, 0))
  expect.equal(heading, nil)
  expect.contains(why, "did not move")
end)

it("two fixes that are not one step apart are refused", function()
  local diagonal, diagWhy = fix.headingFrom(at(0, 64, 0), at(1, 64, 1))
  expect.equal(diagonal, nil)
  expect.contains(diagWhy, "two axes")

  local far, farWhy = fix.headingFrom(at(0, 64, 0), at(4, 64, 0))
  expect.equal(far, nil)
  expect.contains(farWhy, "more than one block")

  -- `forward` cannot change height, so a height change means the two fixes came
  -- from different moments in a job rather than from one step.
  local up, upWhy = fix.headingFrom(at(0, 64, 0), at(0, 65, 0))
  expect.equal(up, nil)
  expect.contains(upWhy, "height")
end)

it("nothing at all is refused rather than throwing", function()
  expect.equal(fix.headingFrom(nil, at(0, 0, 0)), nil)
  expect.equal(fix.headingFrom(at(0, 0, 0), nil), nil)
end)

it("a fix between blocks is not a fix", function()
  -- CC answers fractional coordinates for a turtle mid-move. Writing 12.5 down
  -- as an origin would put every relative coordinate in the job half a block out
  -- for the life of the machine.
  expect.falsy(fix.usable({ x = 12.5, y = 64, z = 0 }))
  expect.falsy(fix.usable({ x = 12, y = 64 }), "and a missing axis is not one either")
  expect.falsy(fix.usable(nil))
  expect.truthy(fix.usable(at(12, 64, -3)))
end)

it("rounding a fix is right in all four quadrants", function()
  -- `math.floor` alone is right for positives and wrong for negatives, which is
  -- the kind of bug that works everywhere somebody happens to test.
  expect.equal(fix.blockOf({ x = 12.4, y = 64.0, z = -3.4 }).x, 12)
  expect.equal(fix.blockOf({ x = 12.4, y = 64.0, z = -3.4 }).z, -3)
  expect.equal(fix.blockOf({ x = -0.5, y = 64, z = 0 }).x, 0)
  expect.equal(fix.blockOf(nil), nil)
end)

it("a heading has a name a person can read", function()
  expect.equal(fix.compass(0), "north")
  expect.equal(fix.compass(3), "west")
  expect.equal(fix.compass(4), "north", "and it wraps")
  expect.equal(fix.compass(nil), "unknown")
end)
