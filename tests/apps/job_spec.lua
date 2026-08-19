--- The turtle's own page: what it says, and what its buttons do.
---
--- This is the page `os/turtle/engine.lua` has been waiting for. That file is the
--- turtle's whole remaining dependency on ICOS 1, and what
--- `legacy/miner/context.lua` still does for it is draw a status screen and
--- prompt for setup - so until both existed on the framework, deleting the ICOS 1
--- copy meant writing a second one.
---
--- What is worth testing here is not the drawing. It is the two things a screen
--- can get wrong in ways nobody notices until a turtle is in a hole: **what it
--- claims about a machine that has stopped**, and **what a button does to a
--- machine that is still working**.

local app = require("apps.job.app")
local expect = require("support.expect")
local it = require("support.spec").it

---------------------------------------------------------------------------
-- What it says
---------------------------------------------------------------------------

it("a parked turtle reports why it parked, not what it was doing", function()
  local status = app.status({ phase = "mining", parked = true, parkKind = "fuel" })

  -- The same rule the Devices page follows. "mining" on a machine standing at
  -- its chest is a claim the screen cannot support, and it is the claim that
  -- makes somebody walk away from a turtle that needed them.
  expect.equal(status.phase, "parked: fuel", "the reason, not the last phase")
end)

it("a parked turtle with no recorded reason still says it is parked", function()
  local status = app.status({ phase = "mining", parked = true })
  expect.equal(status.phase, "parked", "never the stale phase")
end)

it("a working turtle reports its phase", function()
  expect.equal(app.status({ phase = "mining" }).phase, "mining", "as reported")
end)

it("a snapshot from a turtle mid-reboot does not break the page", function()
  -- Every field is optional: a turtle that has just started, and one on an older
  -- build, both report less than a working one.
  local status = app.status({})
  expect.equal(status.job, "none", "no job yet")
  expect.equal(status.distanceHome, 0, "no distance yet")
  expect.equal(status.progress, 0, "and no progress")
end)

it("an unlimited-fuel world shows a full meter, not an empty one", function()
  local status = app.status({ fuel = -1 })

  -- `-1` means unlimited. Drawn as a number it would read as empty on the one
  -- screen somebody checks before sending a turtle a long way from home.
  expect.truthy(status.unlimited, "recognised")
  expect.equal(status.fuelFraction, 1, "and shown as full")
end)

it("a parked turtle's fuel is measured against what its job needs", function()
  local status = app.status({ parked = true, fuel = 500, fuelRequired = 1000 })
  expect.near(status.fuelFraction, 0.5, 0.001, "half of what it needs")
  expect.truthy(app.short(status), "and it is short")
end)

it("a working turtle's fuel is measured against the trip home", function()
  -- A different question, and the one that matters while it is out: not "can it
  -- finish" but "can it get back".
  local status = app.status({ parked = false, fuel = 164, distanceHome = 100 })
  expect.near(status.fuelFraction, 1, 0.001, "comfortably home")
  expect.falsy(app.short(status), "and not flagged, because it is past the point of acting")
end)

it("progress is clamped, so a job reporting nonsense cannot overdraw the meter", function()
  expect.equal(app.status({ progress = 4 }).progress, 1, "over")
  expect.equal(app.status({ progress = -2 }).progress, 0, "and under")
end)

---------------------------------------------------------------------------
-- What its buttons do
---------------------------------------------------------------------------

it("deploying raises the same flag an order from the base raises", function()
  local context = { flags = {} }
  app.order(context, "deploy")

  -- The whole point. `os/turtle/control.lua` sets exactly this flag when a
  -- desired-state deploy arrives, so the local button and the remote order take
  -- the identical path through `Runner:wait` - and there is no second way for a
  -- turtle to be started.
  expect.truthy(context.flags.deploy, "the runner will see it")
end)

it("recalling raises the recall flag", function()
  local context = { flags = {} }
  app.order(context, "recall")
  expect.truthy(context.flags.recall, "the job stops when it is safe to")
end)

it("a turtle with no control flags is left alone rather than erroring", function()
  -- A page mounted on a client is looking at somebody else's turtle and has no
  -- flags to write. Returning nil is the honest answer; raising would take the
  -- screen down for asking.
  expect.falsy(app.order({}, "deploy"), "nothing to raise")
end)

---------------------------------------------------------------------------
-- The form is the job's own declaration
---------------------------------------------------------------------------

it("the form renders whatever the job declares, and nothing else", function()
  local settings = require("domain.turtle.settings")
  local hollow = require("os.turtle.jobs.mining.hollow")

  local rows = settings.rows(hollow.settingFields, { distance = 32, targetY = -20 })
  expect.equal(#rows, #hollow.settingFields, "one row per declared field")
  expect.equal(rows[1].value, 32, "showing what the job holds")

  -- A job that gains a field gains a row, and nobody edits the page. That is the
  -- property `setup(ui)` did not have: it hand-wrote the same fields again, so
  -- the two lists could disagree and only one of them was ever checked.
  expect.truthy(rows[1].label ~= nil, "with the label a person reads")
end)

it("a saved change goes through the same validator a remote order does", function()
  local hollow = require("os.turtle.jobs.mining.hollow")

  -- The form's Save calls `module.configure`, which is what the base calls when
  -- it sends settings over the radio. One code path, so a value the screen
  -- accepts is one the fleet would accept and the reverse.
  local job = { distance = 32, targetY = -20, width = 8, length = 8, cell = 5 }
  local ok, why = hollow.configure(job, { width = 9999 })
  expect.falsy(ok, "refused locally too")
  expect.contains(why, "width", "with the same sentence")
end)
