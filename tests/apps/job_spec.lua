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
-- What it does not do
---------------------------------------------------------------------------

it("the turtle's own page has no controls at all", function()
  -- It had four: deploy, recall, a settings editor and a job picker, all
  -- writing the control flags an order from the base writes. They worked, and
  -- they were the wrong idea.
  --
  -- A fleet has one place decisions are made and it is the server. A turtle
  -- that could be given a different target depth by somebody standing in front
  -- of it is a turtle whose settings no longer match the fleet's - and the base
  -- cannot know, because a local edit is not a message. Two sources of truth
  -- for one number, and the one that loses is the one nobody is looking at.
  --
  -- It also did not fit: a stepper under four status rows and two meters on a
  -- 39x13 screen came out half off the bottom edge with buttons nothing could
  -- reach. That was the symptom; this is the cause.
  expect.falsy(app.order, "no order function")
  expect.falsy(app.save, "no settings writer")
  expect.falsy(app.fields, "and no form to write them from")
end)

it("it is still the page a turtle shows, and only that", function()
  -- Removing the controls must not remove the page. Somebody walks to a turtle
  -- to find out what it is doing, and that question still has an answer.
  expect.equal(app.manifest.id, "job", "registered")
  expect.falsy(app.manifest.requiresInput, "and needs no keyboard")

  local surfaces = {}
  for _, name in ipairs(app.manifest.surfaces) do
    surfaces[name] = true
  end
  expect.truthy(surfaces.launcher, "on a turtle's own screen")
end)
