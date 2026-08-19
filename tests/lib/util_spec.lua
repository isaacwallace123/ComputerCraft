--- Reading order for labels that end in numbers.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

it("labels sort the way a person reads them", function()
  scenario.new({ groundY = 64 })
  local util = require("lib.util")

  local names = {
    "miner-1",
    "miner-10",
    "miner-2",
    "miner-3",
    "miner-4",
    "miner-5",
    "miner-6",
    "miner-7",
    "miner-8",
    "miner-9",
    "miner-11",
    "miner-20",
    "miner-100",
  }
  table.sort(names, util.naturalLess)

  expect.equal(
    table.concat(names, " "),
    "miner-1 miner-2 miner-3 miner-4 miner-5 miner-6 miner-7 miner-8 miner-9 "
      .. "miner-10 miner-11 miner-20 miner-100",
    "ten follows nine"
  )
end)

it("natural order handles the awkward cases", function()
  scenario.new({ groundY = 64 })
  local util = require("lib.util")

  expect.truthy(util.naturalLess("a", "b"), "plain text still sorts")
  expect.falsy(util.naturalLess("b", "a"), "and the other way")
  expect.falsy(util.naturalLess("miner-2", "miner-2"), "equal is not less")

  expect.truthy(util.naturalLess("2", "10"), "bare numbers")
  expect.truthy(util.naturalLess("miner", "miner-1"), "a prefix comes first")
  expect.truthy(util.naturalLess("quarry-9", "miner-10") == false, "text still decides first")

  -- Mixed groups keep their numbers in order within each group.
  local mixed = { "monitor_10", "monitor_2", "computer_10", "computer_2" }
  table.sort(mixed, util.naturalLess)
  expect.equal(
    table.concat(mixed, " "),
    "computer_2 computer_10 monitor_2 monitor_10",
    "grouped and numbered"
  )

  -- Leading zeros must not make the comparator claim two labels are equal, or
  -- an unstable sort can reorder rows between refreshes.
  expect.truthy(
    util.naturalLess("miner-07", "miner-7") ~= util.naturalLess("miner-7", "miner-07"),
    "a deterministic tie-break exists"
  )
end)

it("a fleet sorts into natural order, so miner-2 comes before miner-10", function()
  -- This used to check `legacy/fleet/roster.lua`, which sorted with
  -- `util.naturalLess` and is now deleted. The rule outlived the file: a roster
  -- ordered by string comparison puts miner-10 second and buries miner-2 at the
  -- bottom, which is the ordering somebody reads a fleet in.
  scenario.new({ groundY = 64 })
  local util = require("lib.util")

  local labels = {}
  for id = 1, 12 do
    labels[#labels + 1] = "miner-" .. id
  end

  table.sort(labels, util.naturalLess)

  expect.equal(labels[1], "miner-1", "one first")
  expect.equal(labels[2], "miner-2", "then two, not ten")
  expect.equal(labels[12], "miner-12", "and twelve last")
end)
