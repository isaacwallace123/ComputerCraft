--- Walk a field, harvest what is ripe, replant it, and come back.
---
--- The first job that is not mining, and the reason the role stopped being
--- called `miner` (D036). It shares everything a mining job uses - the same
--- navigation, the same fuel reserve, the same depot rules, the same recall -
--- and differs only in what it does when it arrives at a cell.
---
--- ## A farm is never finished
---
--- Which is the one structural difference from every job before it. A quarry
--- clears its area and stops; a farm walks its plot, waits for things to grow,
--- and walks it again. `domain/farm/plot.lua` wraps the cell index rather than
--- ending, so the run loop has one branch where a mine has two.
---
--- ## It does not stand on the crops
---
--- The turtle travels one block above the field and inspects downward. Walking
--- *on* farmland turns it back into dirt under a full-grown crop, which destroys
--- the crop and the soil in one step - and the farm keeps running, quietly
--- producing less every pass, which is the worst shape a bug can have.
---
--- ## Seeds stay, produce goes
---
--- `domain/farm/crops.lua` decides which is which. Getting it backwards in
--- either direction breaks the farm silently: deliver the seeds and it stops
--- replanting, keep the produce and it fills up in one sweep and spends the rest
--- of the day walking a field it cannot harvest.
---
--- ## Nothing here knows a crop's name
---
--- Maturity, replanting and soil are all asked of `domain/farm/crops.lua`. That
--- is what lets a new crop be one table entry rather than an edit to a run loop,
--- and it is the same split that makes `domain/turtle/jobs.lua` a catalogue
--- rather than a `require`.

local config = require("adapters.cc.config")
local cropData = require("domain.farm.crops")
local fuel = require("os.turtle.device.fuel")
local inv = require("os.turtle.device.inv")
local nav = require("os.turtle.device.nav")
local plot = require("domain.farm.plot")
local safety = require("os.turtle.jobs.common.safety")
local settings = require("domain.turtle.settings")

local farm = {
  name = "crops",
  label = "Tend a crop field",
  PATH = ".farm",
  SAFETY_MARGIN = 64,

  --- How long a resting turtle sleeps before checking its orders again.
  ---
  --- Five seconds, not five minutes. A turtle that slept the whole rest in one
  --- call would ignore a recall for exactly as long as its rest interval - which
  --- is the setting somebody would then turn down, for the wrong reason.
  REST_STEP = 5,
  settingFields = {
    { label = "Distance", key = "distance", step = 4, min = 1, max = 256 },
    { label = "Width", key = "width", step = 1, min = 1, max = 64 },
    { label = "Length", key = "length", step = 1, min = 1, max = 64 },
    { label = "Rest minutes", key = "restMinutes", step = 1, min = 0, max = 60 },
  },
}

local DEFAULTS = {
  -- How far in front of home the near-left corner of the field is.
  distance = 4,
  width = 9,
  length = 9,

  -- How long to wait after a sweep that harvested nothing.
  --
  -- Wheat takes minutes to grow, so a turtle that swept continuously would
  -- spend almost all of its fuel walking over immature crops. Waiting only
  -- after an *empty* sweep means a field that is ready is worked at full speed
  -- and one that is not costs nothing.
  restMinutes = 5,

  cell = 0,
  harvested = 0,
  delivered = 0,
  sweeps = 0,
  active = false,
  startedAt = 0,
}

function farm.load()
  return config.load(farm.PATH, DEFAULTS)
end

function farm.save(job)
  config.save(farm.PATH, job)
end

--- Fuel kept aboard rather than delivered.
local function keepFuel(detail)
  return detail ~= nil and fuel.isFuel(detail.name)
end

--- Seeds are kept; everything else is the harvest.
local function keepAboard(detail)
  if detail == nil then
    return false
  end
  return keepFuel(detail) or cropData.isSeed(detail.name)
end

--- The far corner of the field, which is the furthest the turtle ever goes.
local function reach(job)
  return job.distance + job.length + job.width
end

function farm.minimumFuel(job)
  -- There and back, plus the sweep itself, plus the reserve. A farm's round trip
  -- is short and frequent rather than long and rare, so the margin matters more
  -- than the distance: running dry mid-field strands the turtle on top of the
  -- crops it was tending.
  return 2 * reach(job) + farm.SAFETY_MARGIN + 16
end

function farm.estimateFuel(job)
  return farm.minimumFuel(job) + plot.cells(job.width, job.length)
end

function farm.ready(job)
  local needed = farm.minimumFuel(job)
  local available = fuel.available()
  if available >= needed then
    return true
  end
  return false,
    ("needs %d total fuel, has %d including inventory"):format(needed, math.floor(available))
end

function farm.restart(job)
  job.cell = plot.resume(job.cell, job.width, job.length)
  job.active = true
  job.startedAt = os.epoch("utc")
  farm.save(job)
  return job
end

function farm.status(job)
  local total = math.max(1, plot.cells(job.width, job.length))
  return {
    progress = job.cell / total,
    harvested = job.harvested,
    delivered = job.delivered,
    sweeps = job.sweeps,
    settings = {
      distance = job.distance,
      width = job.width,
      length = job.length,
      restMinutes = job.restMinutes,
    },
  }
end

function farm.configure(job, values)
  local updates, why = settings.apply(farm.settingFields, values)
  if updates == nil then
    return false, why
  end

  -- A field that moved or resized is a different field, so the walk starts
  -- again. `plot.resume` would catch an index past the end anyway; resetting
  -- here means the turtle does not spend the rest of a sweep working the wrong
  -- half of a field somebody just made smaller.
  if settings.merge(job, updates) then
    job.cell = 0
  end

  farm.save(job)
  return true
end

---------------------------------------------------------------------------
-- Working one cell
---------------------------------------------------------------------------

--- Where cell `index` is, in turtle-relative coordinates.
---
--- One block above the field, because standing on farmland turns it back into
--- dirt. The `+ 1` is the whole reason this farm does not slowly destroy itself.
local function cellPosition(job, index)
  local x, z = plot.at(index, job.width, job.length)
  if x == nil then
    return nil
  end
  return x, 1, job.distance + z
end

--- Harvest and replant the block below, if it is ready.
---
--- Returns true when something was harvested. Everything else - bare soil, a
--- crop still growing, a block nobody recognises - is a quiet no, because a farm
--- walks over far more cells than it harvests and a turtle that reported every
--- one would produce a log nobody reads.
---
--- Reaches `turtle` directly, as every other job in this tree does. The port
--- split is real debt and is recorded in `src/README.md`; introducing half of it
--- in one job would leave two ways of touching hardware and no rule saying when
--- to use which.
function farm.workCell(job)
  local ok, block = turtle.inspectDown()
  if not ok or not cropData.mature(block) then
    return false
  end

  local seed = cropData.seedFor(block.name)
  if not turtle.digDown() then
    return false
  end

  job.harvested = job.harvested + 1

  -- Replant from whatever came back up. A harvest yields its own seed, so the
  -- turtle plants what it just picked rather than needing a stocked slot - which
  -- is what makes a farm self-sustaining rather than something somebody refills.
  if seed and farm.select(seed) then
    turtle.placeDown()
  end

  return true
end

--- Put a seed in the turtle's hand, if it has one.
---
--- Returns false rather than raising when there is none: a farm that has run out
--- of seeds should keep harvesting - the field is still full of crops - and let
--- somebody notice that it has stopped replanting. Stopping instead would turn
--- one missing stack into a stopped turtle, which is a worse outcome than a
--- field that needs reseeding.
function farm.select(seed)
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail and detail.name == seed then
      return turtle.select(slot)
    end
  end
  return false
end

---------------------------------------------------------------------------
-- The sweep
---------------------------------------------------------------------------

local function dump(job)
  job.delivered = job.delivered + inv.dropAllExcept(keepAboard, turtle.dropDown)
  farm.save(job)
  return inv.itemCount(function(detail)
    return not keepAboard(detail)
  end) == 0
end

function farm.run(job, ctx)
  local total = plot.cells(job.width, job.length)
  if total == 0 then
    return false, "the field has no cells - set a width and a length"
  end

  local function guard()
    return safety.check(ctx, farm.SAFETY_MARGIN, nav.distanceHome() + reach(job))
  end

  local harvestedThisSweep = 0

  while true do
    local x, y, z = cellPosition(job, job.cell)
    if x == nil then
      job.cell = 0
      farm.save(job)
    else
      ctx.report(
        "tending",
        ("cell %d/%d, %d harvested"):format(job.cell + 1, total, harvestedThisSweep)
      )

      local reached, reason, kind = nav.goTo(x, y, z, guard)
      if not reached then
        -- Home, unload, and stop cleanly. A recall or a fuel reserve is not a
        -- failure - it is the turtle doing what it was told - so the job saves
        -- its place and reports the reason rather than an error.
        if not nav.goHome() then
          return false, "could not return home"
        end
        if not dump(job) then
          return false, "depot full - empty the chest below me"
        end
        if kind == "fuel" or kind == "recalled" then
          job.active = false
          farm.save(job)
          return true, reason, kind
        end
        return false, reason
      end

      if farm.workCell(job) then
        harvestedThisSweep = harvestedThisSweep + 1
      end

      if inv.isFull() then
        if not nav.goHome() then
          return false, "could not return to unload"
        end
        if not dump(job) then
          return false, "depot full - empty the chest below me"
        end
      end

      local previous = job.cell
      job.cell = plot.next(job.cell, job.width, job.length)
      farm.save(job)

      if plot.wrapped(previous, job.cell) then
        -- A sweep has finished. Deliver what is aboard, then decide whether to
        -- go straight round again or wait for things to grow.
        job.sweeps = job.sweeps + 1
        if not nav.goHome() then
          return false, "could not return after a sweep"
        end
        if not dump(job) then
          return false, "depot full - empty the chest below me"
        end

        if harvestedThisSweep == 0 and (job.restMinutes or 0) > 0 then
          ctx.report("resting", ("nothing ripe; waiting %d min"):format(job.restMinutes))
          local rested, restReason, restKind = farm.rest(job, guard)
          if not rested then
            job.active = false
            farm.save(job)
            return true, restReason, restKind
          end
        end

        harvestedThisSweep = 0
      end
    end
  end
end

--- Wait between sweeps, without going deaf.
---
--- Slept in short pieces rather than one long one, so a recall arriving during
--- the rest is noticed within a few seconds instead of five minutes. A turtle
--- that ignored orders while resting would be a turtle that looks unresponsive
--- for exactly as long as its rest interval, which is the setting somebody would
--- then turn down for the wrong reason.
function farm.rest(job, guard)
  local slept = 0
  local total = (job.restMinutes or 0) * 60
  while slept < total do
    local ok, reason, kind = guard()
    if not ok then
      return false, reason, kind
    end
    sleep(farm.REST_STEP)
    slept = slept + farm.REST_STEP
  end
  return true
end

return farm
