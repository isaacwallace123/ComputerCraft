--- Mod detection is a colon, and this is the file that keeps it one.
---
--- Pure string work over a list shaped like the peripherals port's, so there is
--- no simulated world here and no need for one: the whole claim under test is
--- that `advancedperipherals:chunk_controller` names its own mod, and that a
--- vanilla `drive` names none.

local expect = require("support.expect")
local it = require("support.spec").it

local kinds = require("domain.hardware.kinds")

--- One entry as `ports.peripherals.list` returns it.
local function entry(name, ...)
  local types = {}
  local reported = { ... }
  for _, kind in ipairs(reported) do
    types[kind] = true
  end
  return { name = name, types = types, primary = reported[1] }
end

it("a namespaced type names its mod, and a vanilla one names nothing", function()
  expect.equal(kinds.modOf("advancedperipherals:chunk_controller"), "advancedperipherals")
  expect.equal(kinds.modOf("create:mechanical_arm"), "create")

  -- Nil rather than "computercraft", because the question is "is this something
  -- extra" - a vanilla drive answered with a guessed namespace would group with
  -- the mods it is not part of.
  expect.equal(kinds.modOf("drive"), nil, "vanilla CC types have no namespace")
  expect.equal(kinds.modOf(nil), nil, "a missing type is not a crash")
end)

it("the bare type survives the namespace being stripped", function()
  expect.equal(kinds.bare("advancedperipherals:chunk_controller"), "chunk_controller")
  expect.equal(kinds.bare("drive"), "drive", "nothing to strip is not nothing to return")
end)

it("a modded block is classified by what it does, not by who made it", function()
  -- The point of matching on the bare type: nothing in KNOWN names this mod, and
  -- the block still classifies as storage.
  expect.equal(
    kinds.classify({ ["sophisticatedstorage:barrel"] = true, inventory = true }),
    "storage"
  )
end)

it("storage loses to anything more specific", function()
  -- Almost everything with an inventory also *is* something. A chunk controller
  -- that happens to hold items is a chunk controller, and reporting "storage"
  -- would be reading past the answer - whichever order pairs() walked the set.
  local both = kinds.classify({
    ["advancedperipherals:chunk_controller"] = true,
    inventory = true,
  })
  expect.equal(both, "chunk")
end)

it("an unrecognised block is unknown rather than guessed at", function()
  expect.equal(kinds.classify({ ["create:mechanical_arm"] = true }), "unknown")
  expect.equal(kinds.classify(nil), "unknown", "no types at all is still an answer")
end)

it("grouping puts vanilla first and the mods in order after it", function()
  local groups = kinds.byMod({
    entry("mechanical_arm_0", "create:mechanical_arm"),
    entry("chunkLoader_1", "advancedperipherals:chunk_controller"),
    entry("drive_3", "drive"),
  })

  expect.equal(#groups, 3)

  -- Vanilla first because it is the group somebody is looking for when something
  -- expected is missing: a monitor that is not listed is a wiring problem.
  expect.truthy(groups[1].vanilla, "vanilla leads")
  expect.equal(groups[2].mod, "advancedperipherals")
  expect.equal(groups[3].mod, "create")
end)

it("two blocks from one mod are one group", function()
  local groups = kinds.byMod({
    entry("chunkLoader_1", "advancedperipherals:chunk_controller"),
    entry("geoScanner_2", "advancedperipherals:geo_scanner"),
  })

  expect.equal(#groups, 1, "one mod, one group")
  expect.equal(#groups[1].items, 2)

  -- Sorted by name, so the page does not reshuffle between two draws of the same
  -- unchanged hardware.
  expect.equal(groups[1].items[1].name, "chunkLoader_1")
end)

it("the mod list is what this machine can reach, and vanilla is not a mod", function()
  local mods = kinds.mods({
    entry("drive_0", "drive"),
    entry("monitor_1", "monitor"),
    entry("chunkLoader_1", "advancedperipherals:chunk_controller"),
    entry("geoScanner_2", "advancedperipherals:geo_scanner"),
  })

  -- The whole point of the file: no registry queried, no version negotiated,
  -- nothing installed - and the base knows Advanced Peripherals is within reach.
  expect.equal(#mods, 1, "one mod, named once")
  expect.equal(mods[1], "advancedperipherals")
end)

it("nothing attached is an empty list, not an error", function()
  expect.equal(#kinds.byMod({}), 0)
  expect.equal(#kinds.mods(nil), 0)
end)
