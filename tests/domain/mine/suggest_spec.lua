--- Working out a mine from where the base is.
---
--- What this replaces: six steppers, every one of which had to be right before a
--- single turtle could deploy, defaulting to a centre of 0, 0 - which is a real
--- place in the world and almost certainly not the operator's.

local expect = require("support.expect")
local it = require("support.spec").it

local plan = require("domain.mine.plan")
local suggest = require("domain.mine.suggest")

it("a worksite is centred on the base, not on the origin", function()
  local proposed = assert(suggest.from({ x = 53, y = 71, z = 426 }))

  expect.equal(proposed.centreX, 53)
  expect.equal(proposed.centreZ, 426)
  expect.equal(proposed.surfaceY, 71, "the surface the base is standing on")
  expect.truthy(proposed.configured, "and it is ready to deploy against")
end)

it("the hundred blocks is a keep-out, so every shaft hauls a similar distance", function()
  -- Moving the centre a hundred blocks would need a direction nobody gave, and
  -- would leave half the shafts closer to the base than the number promised.
  -- The plan already has the mechanism: ring r sits at least r * cellSize blocks
  -- out, so a keep-out radius is a minimum ring.
  local proposed = assert(suggest.from({ x = 0, y = 64, z = 0 }))

  local nearest = suggest.reach(proposed)
  expect.truthy(nearest >= suggest.KEEP_OUT, "nothing is dug inside the radius asked for")
  expect.equal(proposed.centreX, 0, "and the centre stayed where the base is")
end)

it("the keep-out rounds up, because it is protecting what is already built", function()
  expect.equal(suggest.ringFor(100, 48), 3, "48 and 96 are both inside a hundred")
  expect.equal(suggest.ringFor(96, 48), 2, "exactly on the line is far enough")
  expect.equal(suggest.ringFor(1, 48), 1)
  expect.equal(suggest.ringFor(0, 48), 1, "there is always at least one ring")
end)

it("a different keep-out is honoured, and wins when it cannot all fit", function()
  local far = assert(suggest.from({ x = 0, y = 64, z = 0 }, { keepOut = 200 }))
  expect.truthy(suggest.reach(far) >= 200, "further out when asked")

  local wide = assert(suggest.from({ x = 0, y = 64, z = 0 }, { keepOut = 50, rings = 4 }))
  expect.equal(wide.maxRing - wide.minRing, 4, "more rings when there is room for them")

  -- The plan allows eight rings and no more. A far keep-out eats most of them,
  -- and what gets given up is the outer ring rather than the radius: the span
  -- is how much ground is available, and the keep-out is protecting something
  -- that already exists.
  local squeezed = assert(suggest.from({ x = 0, y = 64, z = 0 }, { keepOut = 300, rings = 4 }))
  expect.truthy(suggest.reach(squeezed) >= 300, "the radius is still honoured")
  expect.truthy(squeezed.maxRing <= 8, "inside what the plan permits")
  expect.truthy(squeezed.maxRing > squeezed.minRing, "and there is still ground to mine")
end)

it("a base that does not know where it is gets a sentence, not a mine at 0 0", function()
  -- The alternative is a worksite centred on the origin: exactly the default
  -- this exists to remove, arrived at by another route and now wearing the
  -- authority of having been calculated.
  local proposed, why = suggest.from(nil)
  expect.equal(proposed, nil)
  expect.contains(why, "does not know where it is")

  expect.equal(suggest.from({ y = 64 }), nil, "and a position missing its X")
end)

it("everything it proposes survives the plan's own rules", function()
  -- A suggestion the plan would clamp is one that says a different thing on the
  -- setup page from what it says once saved.
  local proposed = assert(suggest.from({ x = -1183, y = 12, z = 447 }, { keepOut = 300 }))
  local settled = plan.normalise(proposed)

  for key, value in pairs(proposed) do
    expect.equal(settled[key], value, key .. " was changed by normalise")
  end
end)
