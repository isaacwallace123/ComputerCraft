--- One declaration, one validator, one form.
---
--- `settingFields` describes a job's settings completely, and until now three
--- jobs each re-derived it: a `configure` loop that walked the list, a
--- `setup(ui)` that hand-wrote the same fields as prompts, and - in quarry's
--- case - a private range table that listed them a third time.
---
--- Nothing was broken by that yet. Two things were already drifting: quarry
--- validated `workerIndex` and `workerCount`, which no prompt ever asked for, and
--- its private table duplicated ranges that also lived in `settingFields`. Both
--- are the shape of a bug waiting for somebody to add a field to one list.
---
--- These cases pin the shared behaviour, and then pin the three job-specific
--- rules that deliberately did **not** move into it.

local expect = require("support.expect")
local it = require("support.spec").it
local settings = require("domain.turtle.settings")

local FIELDS = {
  { label = "Target Y", key = "targetY", step = 1, min = -63, max = 319 },
  { label = "Width", key = "width", step = 4, min = 1, max = 256 },
}

---------------------------------------------------------------------------
-- Validating
---------------------------------------------------------------------------

it("a value outside its range is refused, naming the field and the range", function()
  local updates, why = settings.apply(FIELDS, { targetY = -900 })
  expect.falsy(updates, "refused")
  expect.contains(why, "targetY", "names the field")
  expect.contains(why, "-63", "and the range")
end)

it("something that is not a number is refused rather than floored to zero", function()
  local updates, why = settings.apply(FIELDS, { width = "wide" })
  expect.falsy(updates, "refused")
  expect.contains(why, "must be a number", "and says so")
end)

it("one refusal, not a list of them", function()
  -- A page reporting four problems at once is a page somebody skims, and the
  -- second is checked again as soon as the first is fixed.
  local _, why = settings.apply(FIELDS, { targetY = -900, width = 9999 })
  expect.falsy(tostring(why):find(" and "), "one sentence: " .. tostring(why))
end)

it("values are floored, because these are blocks and counts", function()
  local updates = settings.apply(FIELDS, { width = 12.7 })
  expect.equal(assert(updates, "accepted").width, 12, "a fractional block is a typo")
end)

it("a field nobody declared is ignored, not refused", function()
  -- Settings arrive over a radio from a base that may be running a newer build
  -- (§13's rolling update). Refusing an unknown key would make a newer base
  -- unable to configure an older turtle at all.
  local updates = assert(settings.apply(FIELDS, { targetY = 12, somethingNew = 4 }), "accepted")
  expect.equal(updates.targetY, 12, "the known field applied")
  expect.falsy(updates.somethingNew, "and the unknown one was dropped")
end)

it("only the fields that were sent are touched", function()
  local updates = assert(settings.apply(FIELDS, { width = 8 }))
  expect.falsy(updates.targetY, "an absent field is not defaulted over the top of a job")
end)

---------------------------------------------------------------------------
-- Merging, and what "changed" has to mean
---------------------------------------------------------------------------

it("re-sending the settings a job already has is not a change", function()
  local job = { targetY = -59, width = 16 }
  local changed = settings.merge(job, { targetY = -59, width = 16 })

  -- This is the property every caller depends on. `reconcile` re-sends a goal
  -- until a device converges, so a merge that reported a change on identical
  -- values would have a quarry discarding its part-finished layer every six
  -- seconds forever.
  expect.falsy(changed, "nothing moved")
end)

it("a real change is reported, and applied", function()
  local job = { targetY = -59, width = 16 }
  expect.truthy(settings.merge(job, { width = 32 }), "something moved")
  expect.equal(job.width, 32, "and it is on the job")
  expect.equal(job.targetY, -59, "the rest is untouched")
end)

it("one named field can be asked about on its own", function()
  local job = { targetY = -59, width = 16 }

  -- Prospecting forgets a pending vein when the *depth* moves and must not
  -- forget it when the vein budget moves: that vein is a real hole with real ore
  -- that the turtle has promised to come back to.
  expect.falsy(settings.moved(job, { width = 32 }, "targetY"), "a different field moving is not it")
  expect.truthy(settings.moved(job, { targetY = -10 }, "targetY"), "this one is")
  expect.falsy(settings.moved(job, { targetY = -59 }, "targetY"), "and the same value is not")
end)

---------------------------------------------------------------------------
-- The form
---------------------------------------------------------------------------

it("rows carry what a form needs and nothing it has to re-derive", function()
  local rows = settings.rows(FIELDS, { targetY = -59, width = 16 })
  expect.equal(#rows, 2, "one row per field")
  expect.equal(rows[1].label, "Target Y", "the label a person reads")
  expect.equal(rows[1].value, -59, "the value the job holds")
  expect.equal(rows[2].step, 4, "and the increment that field moves in")
end)

it("a row for a field the job has never set falls back to the minimum", function()
  local rows = settings.rows(FIELDS, {})
  expect.equal(rows[1].value, -63, "the bottom of its range, not nil")
end)

it("a nudge cannot produce a value the validator would refuse", function()
  local field = FIELDS[1]
  expect.equal(settings.nudge(field, -63, -1), -63, "it stops at the bottom")
  expect.equal(settings.nudge(field, 319, 1), 319, "and at the top")
  expect.equal(settings.nudge(FIELDS[2], 16, 1), 20, "and moves by the field's own step")

  -- The button simply stops rather than producing something that is then
  -- rejected, which is the difference between a control that feels solid and one
  -- that argues back.
  local updates = settings.apply(FIELDS, { targetY = settings.nudge(field, -63, -1) })
  expect.truthy(updates, "whatever a nudge produces is always acceptable")
end)

---------------------------------------------------------------------------
-- What deliberately stayed in the jobs
---------------------------------------------------------------------------

it("quarry still refuses a box that would have no cells in it", function()
  local quarry = require("os.turtle.jobs.mining.quarry")
  local job = {
    minX = 0,
    maxX = 15,
    minZ = 0,
    maxZ = 15,
    topY = 64,
    bottomY = -59,
    workerIndex = 1,
    workerCount = 1,
    layer = 0,
    cell = 0,
  }

  -- Cross-field, and checked against what the job *would* become. Raising minX
  -- past an unchanged maxX is fine field by field and impossible as a box.
  local ok, why = quarry.configure(job, { minX = 40 })
  expect.falsy(ok, "refused")
  expect.contains(why, "maximum corners", "and says which way round they go")
end)

it("quarry validates the worker slice it is assigned but never shows it", function()
  local quarry = require("os.turtle.jobs.mining.quarry")

  -- Nobody hand-picks their own index out of a fleet-wide split, so these are
  -- not in `settingFields` - but the base sends them and they are checked
  -- exactly like everything else. They used to be listed in a private table
  -- that duplicated the visible ranges alongside them.
  expect.falsy(settings.field(quarry.settingFields, "workerIndex"), "not shown to a person")
  expect.truthy(settings.field(quarry.fields(), "workerIndex"), "but still validated")

  local job = {
    minX = 0,
    maxX = 15,
    minZ = 0,
    maxZ = 15,
    topY = 64,
    bottomY = -59,
    workerIndex = 1,
    workerCount = 1,
    layer = 0,
    cell = 0,
  }
  local ok, why = quarry.configure(job, { workerIndex = 4, workerCount = 2 })
  expect.falsy(ok, "refused")
  expect.contains(why, "worker index", "a slice outside its own split")
end)

it("a quarry that is re-sent identical settings keeps its progress", function()
  local quarry = require("os.turtle.jobs.mining.quarry")
  local job = {
    minX = 0,
    maxX = 15,
    minZ = 0,
    maxZ = 15,
    topY = 64,
    bottomY = -59,
    workerIndex = 1,
    workerCount = 3,
    layer = 7,
    cell = 40,
  }

  expect.truthy(quarry.configure(job, { workerCount = 3 }), "accepted")
  expect.equal(job.layer, 7, "the layer it had reached")
  expect.equal(job.cell, 40, "and the cell it was on")

  -- A change, though, is different ground and starts again.
  expect.truthy(quarry.configure(job, { maxX = 31 }), "accepted")
  expect.equal(job.layer, 0, "a different area restarts the layer")
  expect.equal(job.cell, 0, "and the cell walk")
end)
