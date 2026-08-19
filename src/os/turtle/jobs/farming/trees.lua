--- Fell a row of trees, replant them, and come back when they have grown.
---
--- The second job that is not mining, and the one that proves the first was not
--- a special case: adding it was one module and one catalogue entry again, and
--- nothing outside this file and `domain/farm/trees.lua` changed.
---
--- ## It works from an aisle
---
--- Trees stand in a line `distance` blocks ahead of home; the turtle works from
--- one block short of that line and only ever steps into a trunk column while
--- felling it. A turtle that lived *in* the line would be standing inside the
--- next tree as it grew, and would have to dig its way out of a tree that grew
--- around it - which is a turtle that looks stuck for no visible reason.
---
--- ## Leaves are left alone
---
--- They decay by themselves. A turtle that cleared them would spend most of a
--- fell on blocks that were about to vanish, and would come home with an
--- inventory of leaf blocks instead of wood - so the climb stops at the first
--- thing that is not a log, and the canopy sorts itself out.
---
--- ## The height is a budget, not a measurement
---
--- A turtle at the bottom of a trunk cannot see the top. So `maxHeight` caps the
--- climb and the fuel reserve is sized for it: a farm that budgeted for oak
--- would strand itself the first time somebody planted a jungle sapling, thirty
--- blocks up a trunk with no fuel to come down.

local config = require("adapters.cc.config")
local fuel = require("os.turtle.device.fuel")
local inv = require("os.turtle.device.inv")
local nav = require("os.turtle.device.nav")
local safety = require("os.turtle.jobs.common.safety")
local settings = require("domain.turtle.settings")
local treeData = require("domain.farm.trees")

local lumber = {
  name = "trees",
  label = "Fell and replant a tree row",
  PATH = ".trees",
  SAFETY_MARGIN = 64,

  --- How long a waiting turtle sleeps before checking its orders again.
  ---
  --- The same five seconds the crop farm rests in, and for the same reason: a
  --- turtle that slept a whole interval in one call ignores a recall for exactly
  --- that long.
  REST_STEP = 5,

  settingFields = {
    { label = "Distance", key = "distance", step = 1, min = 2, max = 256 },
    { label = "Trees", key = "count", step = 1, min = 1, max = 32 },
    { label = "Spacing", key = "spacing", step = 1, min = 2, max = 8 },
    { label = "Max height", key = "maxHeight", step = 4, min = 8, max = 40 },
    { label = "Rest minutes", key = "restMinutes", step = 1, min = 0, max = 60 },
  },
}

local DEFAULTS = {
  distance = 3,
  count = 4,

  -- Two blocks apart. One would put trunks touching, which for most species
  -- means the canopies merge and a felled tree leaves its neighbour's leaves
  -- floating over an empty square.
  spacing = 2,

  -- Tall enough for a jungle tree. The cost of over-budgeting is a slightly
  -- larger fuel reserve; the cost of under-budgeting is a turtle stranded up a
  -- trunk it cannot climb down.
  maxHeight = 32,

  restMinutes = 5,

  tree = 0,
  felled = 0,
  delivered = 0,
  sweeps = 0,
  active = false,
  startedAt = 0,
}

function lumber.load()
  return config.load(lumber.PATH, DEFAULTS)
end

function lumber.save(job)
  config.save(lumber.PATH, job)
end

local function keepFuel(detail)
  return detail ~= nil and fuel.isFuel(detail.name)
end

--- Saplings stay aboard; wood goes in the chest.
---
--- Backwards in either direction breaks the farm silently, exactly as it does
--- for crops: deliver the saplings and the row stops being replanted, keep the
--- wood and the turtle fills up on the first tree.
local function keepAboard(detail)
  if detail == nil then
    return false
  end
  return keepFuel(detail) or treeData.isSapling(detail.name)
end

local function reach(job)
  return job.distance + job.count * job.spacing
end

function lumber.minimumFuel(job)
  return 2 * reach(job) + treeData.fellCost(job.maxHeight) + lumber.SAFETY_MARGIN
end

function lumber.estimateFuel(job)
  return lumber.minimumFuel(job) + job.count * treeData.fellCost(job.maxHeight)
end

function lumber.ready(job)
  local needed = lumber.minimumFuel(job)
  local available = fuel.available()
  if available >= needed then
    return true
  end
  return false,
    ("needs %d total fuel, has %d including inventory"):format(needed, math.floor(available))
end

function lumber.restart(job)
  job.tree = treeData.resume(job.tree, job.count)
  job.active = true
  job.startedAt = os.epoch("utc")
  lumber.save(job)
  return job
end

function lumber.status(job)
  return {
    progress = job.tree / math.max(1, job.count),
    felled = job.felled,
    delivered = job.delivered,
    sweeps = job.sweeps,
    settings = {
      distance = job.distance,
      count = job.count,
      spacing = job.spacing,
      maxHeight = job.maxHeight,
      restMinutes = job.restMinutes,
    },
  }
end

function lumber.configure(job, values)
  local updates, why = settings.apply(lumber.settingFields, values)
  if updates == nil then
    return false, why
  end
  if settings.merge(job, updates) then
    job.tree = 0
  end
  lumber.save(job)
  return true
end

---------------------------------------------------------------------------
-- Felling
---------------------------------------------------------------------------

--- Climb a trunk, taking it down as it goes. Returns how many logs were cut.
---
--- Stops at the first block that is not a log, which is the canopy, and at
--- `maxHeight`, which is the fuel budget. Both are ordinary endings rather than
--- failures - a tree is finished when it stops being a tree.
---
--- The descent is exactly the climb, counted rather than measured. A turtle that
--- descended "until the ground" would keep going through the hole it dug on the
--- way in, and one that used `goHome` from up a trunk would path through the
--- neighbouring trees.
function lumber.climb(job)
  local cut = 0
  local climbed = 0

  while climbed < job.maxHeight do
    local ok, block = turtle.inspectUp()
    if not ok or not treeData.isLog(block) then
      break
    end
    if not turtle.digUp() then
      break
    end
    cut = cut + 1
    if not nav.up() then
      break
    end
    climbed = climbed + 1
  end

  while climbed > 0 do
    if not nav.down() then
      break
    end
    climbed = climbed - 1
  end

  return cut, climbed == 0
end

--- Take down the tree in front, if there is one, and put a sapling back.
---
--- Returns the number of logs cut, which is zero for an empty station or one
--- holding a sapling that has not grown yet. Both are ordinary: a tree farm
--- walks past far more stations than it fells.
function lumber.fell(job)
  local ok, block = turtle.inspect()
  if not ok or not treeData.isLog(block) then
    -- Nothing to fell. If the station is bare and we are carrying saplings,
    -- plant one - which is how a row recovers after somebody harvests it by
    -- hand, without anybody having to tell the turtle.
    if not ok and lumber.selectSapling() then
      turtle.place()
    end
    return 0
  end

  if not turtle.dig() then
    return 0
  end
  if not nav.forward() then
    return 1
  end

  local cut, descended = lumber.climb(job)
  cut = cut + 1

  -- Back into the aisle before replanting, so the sapling goes where the trunk
  -- was rather than where the turtle is.
  if descended and nav.back() and lumber.selectSapling() then
    turtle.place()
  end

  job.felled = job.felled + cut
  return cut
end

--- Put a sapling in the turtle's hand, if it has one.
---
--- False rather than an error when there are none. A row that has run out of
--- saplings should keep being felled - the trees are still there - and let
--- somebody notice it has stopped replanting. Stopping would turn one empty slot
--- into a stopped turtle.
function lumber.selectSapling()
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail and treeData.isSapling(detail.name) then
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
  lumber.save(job)
  return inv.itemCount(function(detail)
    return not keepAboard(detail)
  end) == 0
end

function lumber.run(job, ctx)
  if job.count < 1 then
    return false, "no trees configured - set a count"
  end

  local function guard()
    return safety.check(
      ctx,
      lumber.SAFETY_MARGIN + treeData.fellCost(job.maxHeight),
      nav.distanceHome() + reach(job)
    )
  end

  local cutThisSweep = 0

  while true do
    local station = treeData.station(job.tree, job.spacing, job.distance)
    ctx.report("felling", ("tree %d/%d, %d cut"):format(job.tree + 1, job.count, cutThisSweep))

    local reached, reason, kind = nav.goTo(station.x, station.y, station.z, guard)
    if not reached then
      if not nav.goHome() then
        return false, "could not return home"
      end
      if not dump(job) then
        return false, "depot full - empty the chest below me"
      end
      if kind == "fuel" or kind == "recalled" then
        job.active = false
        lumber.save(job)
        return true, reason, kind
      end
      return false, reason
    end

    nav.face(station.facing)
    cutThisSweep = cutThisSweep + lumber.fell(job)

    if inv.isFull() then
      if not nav.goHome() then
        return false, "could not return to unload"
      end
      if not dump(job) then
        return false, "depot full - empty the chest below me"
      end
    end

    local previous = job.tree
    job.tree = treeData.next(job.tree, job.count)
    lumber.save(job)

    if job.tree == 0 and previous ~= 0 then
      job.sweeps = job.sweeps + 1
      if not nav.goHome() then
        return false, "could not return after a sweep"
      end
      if not dump(job) then
        return false, "depot full - empty the chest below me"
      end

      if cutThisSweep == 0 and (job.restMinutes or 0) > 0 then
        ctx.report("resting", ("nothing grown; waiting %d min"):format(job.restMinutes))
        local rested, restReason, restKind = lumber.rest(job, guard)
        if not rested then
          job.active = false
          lumber.save(job)
          return true, restReason, restKind
        end
      end

      cutThisSweep = 0
    end
  end
end

function lumber.rest(job, guard)
  local slept = 0
  local total = (job.restMinutes or 0) * 60
  while slept < total do
    local ok, reason, kind = guard()
    if not ok then
      return false, reason, kind
    end
    sleep(lumber.REST_STEP)
    slept = slept + lumber.REST_STEP
  end
  return true
end

return lumber
