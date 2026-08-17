--- Reading order for labels that end in numbers.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

it("labels sort the way a person reads them", function()
  scenario.new({ groundY = 64 })
  local util = require("core.util")

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
  local util = require("core.util")

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

it("the roster lists turtles in natural order", function()
  scenario.new({ groundY = 64 })
  local roster = require("fleet.roster")

  local devices = {}
  for id = 1, 12 do
    devices[tostring(id)] = {
      snap = { label = "miner-" .. id, role = "miner" },
      lastSeen = os.epoch("utc"),
    }
  end

  local sorted = roster.sorted(devices)
  local labels = {}
  for _, node in ipairs(sorted) do
    labels[#labels + 1] = node.snap.label
  end

  expect.equal(labels[1], "miner-1", "first row")
  expect.equal(labels[2], "miner-2", "miner-10 no longer jumps the queue")
  expect.equal(labels[9], "miner-9", "ninth row")
  expect.equal(labels[10], "miner-10", "tenth row")
  expect.equal(labels[12], "miner-12", "last row")
end)
