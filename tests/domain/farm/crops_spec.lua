--- Crop maturity, where being wrong destroys a field quietly.

local expect = require("support.expect")
local it = require("support.spec").it

local crops = require("domain.farm.crops")
local plot = require("domain.farm.plot")

local function block(name, age)
  return { name = name, state = { age = age } }
end

it("every crop ripens at its own age, not at a shared one", function()
  -- Verified against the wiki: wheat, carrots and potatoes run 0-7; beetroot
  -- and nether wart run 0-3. A single hard-coded 7 leaves a beetroot field
  -- walked over forever; a single hard-coded 3 harvests wheat at less than half
  -- growth, which looks like the farm working because it does produce something.
  expect.truthy(crops.mature(block("minecraft:wheat", 7)), "ripe wheat")
  expect.falsy(crops.mature(block("minecraft:wheat", 6)), "and not one stage early")

  expect.truthy(crops.mature(block("minecraft:beetroots", 3)), "ripe beetroot")
  expect.falsy(crops.mature(block("minecraft:beetroots", 2)), "and not one stage early")

  -- The failure a shared constant would cause, stated as a test.
  expect.falsy(crops.mature(block("minecraft:wheat", 3)), "wheat is not ripe at beetroot's age")
end)

it("anything we do not recognise is left growing", function()
  -- The direction of the failure is the point. A crop that does not get farmed
  -- is noticed and fixed; a field of seedlings destroyed at age 0 is noticed
  -- after it has happened.
  expect.falsy(crops.mature(block("modded:strawberries", 7)), "an unknown crop")
  expect.falsy(crops.mature(block("minecraft:wheat", nil)), "a crop with no age")
  expect.falsy(crops.mature({ name = "minecraft:wheat" }), "a crop with no state")
  expect.falsy(crops.mature(nil), "and nothing at all")
end)

it("carrots and potatoes replant themselves, because they have no seed item", function()
  -- A farm that looked for `minecraft:carrot_seeds` would find nothing and
  -- silently stop replanting, leaving bare farmland behind it.
  expect.equal(crops.seedFor("minecraft:carrots"), "minecraft:carrot", "the carrot is the seed")
  expect.equal(crops.seedFor("minecraft:wheat"), "minecraft:wheat_seeds", "wheat has a real one")
  expect.falsy(crops.seedFor("minecraft:stone"), "and stone plants nothing")
end)

it("seeds are kept and produce is delivered", function()
  -- Backwards in either direction breaks the farm silently: deliver the seeds
  -- and it stops replanting, keep the produce and it fills up in one sweep.
  expect.truthy(crops.isSeed("minecraft:wheat_seeds"), "seeds stay")
  expect.truthy(crops.isSeed("minecraft:carrot"), "and so does a carrot, which is both")
  expect.falsy(crops.isSeed("minecraft:wheat"), "but the wheat itself goes")
end)

it("a plot is walked serpentine, so no row is traversed twice", function()
  -- A raster walk costs an extra `width` of movement per row, which on a field
  -- walked every few minutes is most of the fuel a farm uses.
  local x0 = select(1, plot.at(0, 3, 3))
  local x2 = select(1, plot.at(2, 3, 3))
  expect.equal(x0, 0, "row 0 starts at the left")
  expect.equal(x2, 2, "and ends at the right")

  -- Row 1 runs back, so cell 3 is directly above cell 2 rather than across the
  -- field from it.
  local x3, z3 = plot.at(3, 3, 3)
  expect.equal(x3, 2, "row 1 starts where row 0 ended")
  expect.equal(z3, 1, "one row along")
end)

it("a farm has no last cell", function()
  -- The one structural difference from a mine. Wrapping here is what lets the
  -- run loop have one branch where a mine has two.
  expect.equal(plot.next(8, 3, 3), 0, "the end comes back round")
  expect.truthy(plot.wrapped(8, 0), "and a sweep is recognised as finished")
  expect.falsy(plot.wrapped(0, 1), "while an ordinary step is not")
end)

it("a field that was resized while the turtle was away does not walk off it", function()
  -- A stale index past the end would send the turtle outside its own field and
  -- start harvesting somebody's build.
  expect.equal(plot.resume(80, 3, 3), 0, "clamped")
  expect.equal(plot.resume(4, 3, 3), 4, "a valid index survives")
  expect.equal(plot.resume(nil, 3, 3), 0, "and a missing one starts over")
  expect.falsy(plot.at(9, 3, 3), "nine is off a nine-cell plot")
end)
