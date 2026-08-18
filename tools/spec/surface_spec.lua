--- The property that matters: a sector shaft is never left open.
---
--- These drive the real Rare job through the real runner over a simulated
--- world, so what is asserted is the state of the ground afterwards rather than
--- the state of a variable.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

local GROUND = 64

local function newMiner(options)
  options = options or {}
  local w = scenario.new({
    groundY = options.groundY or GROUND,
    x = 0,
    y = (options.groundY or GROUND) + 1,
    z = 0,
    facing = 0,
  })
  local sector = scenario.prospecting(w, {
    cellSize = 16,
    surfaceY = options.surfaceY or options.groundY or GROUND,
    targetY = options.targetY or ((options.groundY or GROUND) - 8),
    phase = options.phase,
    access = options.access,
  })
  return w, sector
end

--- Is the shaft column shut where a player would walk into it?
local function headSealed(w, sector, groundY)
  for y = groundY, groundY + 6 do
    if w:solid(sector.shaftX, y, sector.shaftZ) then
      return true, y
    end
  end
  return false
end

it("a completed cycle leaves the shaft head capped", function()
  local w, sector = newMiner()

  local ok, outcome = scenario.cycle(w)
  expect.truthy(ok, "cycle ran: " .. tostring(outcome))
  expect.truthy(outcome.ok, "cycle succeeded: " .. tostring(outcome.reason))

  expect.truthy(headSealed(w, sector, GROUND), "shaft head is capped")
  expect.falsy(w:solid(sector.shaftX, GROUND - 4, sector.shaftZ), "shaft below is open")
  expect.equal(w.x .. "," .. w.z, "0,0", "turtle came home")
end)

it("the cap is reused rather than a second hole opened", function()
  local w, sector = newMiner()
  expect.truthy(scenario.cycle(w), "first cycle")

  local rare = require("jobs.mining.rare")
  local job = rare.load()
  rare.restart(job)
  require("device.nav").setHome()

  expect.truthy(scenario.cycle(w), "second cycle")
  expect.truthy(headSealed(w, sector, GROUND), "still capped after a second trip")

  -- One shaft, not two: nothing else at the surface may have been opened.
  local openColumns = 0
  for x = sector.shaftX - 2, sector.shaftX + 2 do
    for z = sector.shaftZ - 2, sector.shaftZ + 2 do
      if not w:solid(x, GROUND, z) then
        openColumns = openColumns + 1
      end
    end
  end
  expect.equal(openColumns, 0, "no open column at the surface")
end)

it("a recall while underground still reseals the shaft", function()
  local w, sector = newMiner()
  local ctx = scenario.context({ recallAfter = 40 })

  local ok = scenario.cycle(w, { ctx = ctx })
  expect.truthy(ok, "recalled cycle completed")
  expect.truthy(headSealed(w, sector, GROUND), "shaft capped after a recall")
end)

it("an already-open shaft from an older build is capped on the next visit", function()
  local w, sector = newMiner()
  -- Exactly what ICOS v1.2.6 left behind: an open column to mining depth.
  w:openShaft(sector.shaftX, GROUND - 8, GROUND, sector.shaftZ)
  expect.falsy(w:solid(sector.shaftX, GROUND, sector.shaftZ), "starts open")

  expect.truthy(scenario.cycle(w), "cycle over an open shaft")
  expect.truthy(headSealed(w, sector, GROUND), "the old hole was sealed")
end)

it("terrain higher than the plan's surface is capped at the real ground", function()
  local groundY = GROUND
  local w = scenario.new({ groundY = groundY, x = 0, y = groundY + 1, z = 0, facing = 0 })
  local sector = scenario.prospecting(w, {
    cellSize = 16,
    surfaceY = groundY,
    targetY = groundY - 8,
  })

  -- A hill at the sector, six blocks proud of the base's surface.
  for y = groundY + 1, groundY + 6 do
    w:fill(
      sector.shaftX - 3,
      y,
      sector.shaftZ - 3,
      sector.shaftX + 3,
      y,
      sector.shaftZ + 3,
      "minecraft:stone"
    )
  end

  expect.truthy(scenario.cycle(w), "cycle into a hill")
  local sealed, atY = headSealed(w, sector, groundY)
  expect.truthy(sealed, "hill shaft is capped")
  expect.equal(atY, groundY + 6, "capped at the hilltop, not the plan surface")
end)

it("a head under water is relocated along the trunk instead of parking", function()
  local w, sector = newMiner()
  -- A pond sitting exactly over the sector's nominated shaft.
  w:fill(
    sector.shaftX - 1,
    GROUND,
    sector.shaftZ - 1,
    sector.shaftX + 1,
    GROUND,
    sector.shaftZ + 1,
    "minecraft:water"
  )

  local ok, outcome = scenario.cycle(w)
  expect.truthy(ok, "cycle ran: " .. tostring(outcome))
  expect.truthy(outcome.ok, "cycle succeeded: " .. tostring(outcome.reason))

  local rare = require("jobs.mining.rare")
  local job = rare.load()
  expect.truthy(math.abs(job.shaftOffset) >= 2, "head moved clear of the pond")

  local headX = sector.shaftX + job.shaftOffset
  expect.truthy(w:solid(headX, GROUND, sector.shaftZ), "relocated head is capped")
  expect.truthy(headX >= sector.trunkFromX, "head stayed on the trunk")
  expect.truthy(headX <= sector.trunkToX, "head stayed inside the sector")

  -- And the water is undisturbed: the turtle went around, not through.
  expect.equal(w:get(sector.shaftX, GROUND, sector.shaftZ), "minecraft:water", "pond intact")
end)

it("a sector with no sealable head anywhere reports which sector and why", function()
  local w, sector = newMiner()
  w:fill(
    sector.trunkFromX,
    GROUND,
    sector.shaftZ,
    sector.trunkToX,
    GROUND,
    sector.shaftZ,
    "minecraft:water"
  )

  local ok, outcome = scenario.cycle(w)
  expect.truthy(ok, "cycle ran: " .. tostring(outcome))
  expect.contains(outcome.reason, "sector " .. sector.index, "names the sector")
  expect.contains(outcome.reason, "water", "names what is in the way")
  expect.equal(w.x .. "," .. w.z, "0,0", "still came home")
  expect.truthy(w:solid(sector.shaftX, GROUND - 2, sector.shaftZ), "nothing dug under the pond")
end)

--- The one that cannot be argued, only run.
---
--- Power is cut after every single world interaction of a complete cycle, one
--- run per interaction, and each run is then rebooted until it finishes. The
--- surface has to be shut at the end of all of them.
it("losing power at any point still leaves the surface shut", function()
  local reference = select(1, newMiner())
  expect.truthy(scenario.cycle(reference), "reference cycle")
  local total = reference.ops

  local checked = 0
  for crashAt = 1, total do
    local w, sector = newMiner()
    w.crashAfter = crashAt

    local ok, outcome, reboots = scenario.cycle(w, { maxReboots = 8 })
    expect.truthy(ok, ("crash at op %d: %s"):format(crashAt, tostring(outcome)))
    expect.truthy(
      headSealed(w, sector, GROUND),
      ("crash at op %d left the shaft head open"):format(crashAt)
    )

    -- A cycle can finish in slightly fewer operations than the reference run,
    -- so the last few budgets may never fire. Only count the ones that did.
    if w.crashAfter == nil then
      expect.truthy(reboots >= 1, ("crash at op %d should have rebooted"):format(crashAt))
      checked = checked + 1
    end
  end

  expect.truthy(checked > 50, "the reference cycle should be long enough to be worth testing")
end)
