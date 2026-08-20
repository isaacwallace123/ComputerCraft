local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local jobs = require("domain.turtle.jobs")
local turtleOs = require("os.turtle.main")

local fakeClock = fleet.clock
local fakePorts = fleet.ports
local turtle = fleet.turtle

---------------------------------------------------------------------------
-- The job catalogue: what a turtle can be told to do
---------------------------------------------------------------------------

it("the catalogue is data, so a machine with no turtle global can read it", function()
  -- The point of `module` being a string. A base listing jobs must not have to
  -- load jobs/mining/quarry.lua, which would crash on turtle.dig being nil.
  for _, entry in ipairs(jobs.list()) do
    -- Required, not type-checked. Asserting this is a string is satisfied by
    -- any string, including one naming a file that moved two restructures ago -
    -- which is exactly what happened, and it survived because the turtle
    -- resolves the path only at the moment it starts working, on a machine
    -- nobody is watching.
    expect.equal(type(entry.module), "string", entry.id .. " names its module")
    local loaded, failure = pcall(require, entry.module)
    expect.truthy(loaded, entry.id .. " module resolves: " .. tostring(failure))
    expect.equal(type(entry.label), "string", entry.id .. " has a label")
    expect.truthy(#entry.needs > 0, entry.id .. " declares what it needs")
  end
  expect.truthy(jobs.default(), "and exactly one is the fallback")
end)

it("a job name from an older build resolves rather than refusing to start", function()
  -- A turtle that will not start is one somebody has to walk to.
  local entry, corrected = jobs.resolve("expedition")
  expect.equal(entry.id, "rare", "the rename is followed")
  expect.truthy(corrected, "and reported, so the node is fixed once")

  entry, corrected = jobs.resolve("archaeology")
  expect.equal(entry.id, jobs.default().id, "an unknown job falls back")
  expect.truthy(corrected, "and that is a correction too")

  entry, corrected = jobs.resolve("quarry")
  expect.equal(entry.id, "quarry", "a current one is left alone")
  expect.falsy(corrected, "with nothing to write")
end)

it("a fuel hunt does not need the base, because it is what you do without one", function()
  -- Requiring a modem here would mean a fleet that cannot refuel itself once
  -- the base is unreachable.
  local offline = { dig = true, fuel = true, modem = false }
  expect.truthy(jobs.runnable(jobs.get("fuel"), offline), "fuel hunting works alone")
  expect.falsy(jobs.runnable(jobs.get("quarry"), offline), "a coordinated quarry does not")
end)

it("a missing capability is explained as the thing to do about it", function()
  local ok, why = jobs.runnable(jobs.get("quarry"), { dig = true, modem = true })
  expect.falsy(ok, "refused")
  expect.contains(why, "fuel", "and it names what to fix")

  -- One reason, not four. A list of deficiencies is a list somebody skims.
  ok, why = jobs.runnable(jobs.get("quarry"), {})
  expect.falsy(ok, "still refused")
  expect.falsy(tostring(why):find(" and "), "with one actionable sentence: " .. tostring(why))
end)

it("a setup menu offers only what this machine can run", function()
  local unfuelled = { dig = true, place = true, modem = true, fuel = false }
  expect.equal(#jobs.available(unfuelled), 0, "an empty turtle is offered nothing")

  local everything = { dig = true, place = true, modem = true, fuel = true, chunky = true }
  expect.equal(#jobs.available(everything), #jobs.list(), "a fully equipped one gets the lot")

  -- A mining turtle without a chunk loader is not a candidate general, and the
  -- menu says so by not offering it. This is the capability that can actually be
  -- observed - the upgrade is a peripheral, so unlike `dig` it is a fact rather
  -- than a declaration - which is why it is the one that filters a menu instead
  -- of producing a park twenty minutes later.
  local miner = { dig = true, place = true, modem = true, fuel = true }
  local offered = jobs.available(miner)
  expect.equal(#offered, #jobs.list() - 1, "everything except the one it cannot hold")
  for _, entry in ipairs(offered) do
    expect.truthy(entry.id ~= "general", "and the general is the one missing")
  end
end)

it("a turtle keeps its unrunnable job rather than being quietly swapped", function()
  -- A turtle that silently started fuel-hunting because its pickaxe fell out is
  -- a turtle nobody can diagnose from the base.
  local entry, corrected, runnable, why = turtleOs.selectJob(
    { job = "quarry" },
    { dig = true, fuel = false, modem = true }
  )

  expect.equal(entry.id, "quarry", "still the job it was given")
  expect.falsy(corrected, "nothing to rewrite")
  expect.falsy(runnable, "but it cannot run")
  expect.contains(why, "fuel", "and the base will be told why")
end)

it("a renamed job is written back once rather than re-derived every boot", function()
  local clock = fakeClock(0)
  local machine = turtleOs.boot(fakePorts(clock), {
    node = { job = "expedition", parked = true },
    capabilities = { dig = true, fuel = true, modem = true },
  })

  expect.equal(machine.context.job.id, "rare", "resolved before anything started")
  expect.equal(machine.context.node.job, "rare", "and the node was corrected")
  expect.truthy(machine.context.nodeChanged, "with the write flagged for the caller")
end)
