--- Mining turtle agent.
---
--- Runs a job and reports to the fleet base. Reporting is deliberately
--- fire-and-forget: if the base is unreachable - which it will be, often, once
--- the turtle is deep underground - the turtle keeps mining and the dashboard
--- simply shows it as stale. Nothing about the job depends on the network.

package.path = "/?.lua;/?/init.lua;" .. package.path

if not turtle then
  printError("This is a turtle program.")
  return
end

local ui = require("core.ui")
local net = require("core.net")
local log = require("core.log")
local util = require("core.util")
local nav = require("turtle.nav")
local fuel = require("turtle.fuel")
local quarry = require("jobs.quarry")

local HEARTBEAT_SECONDS = 2
local GPS_REFRESH_SECONDS = 30

local job = quarry.load()
local baseId = nil
local worldPos = nil
local lastGps = 0

local status = { phase = "idle", detail = "" }

--- Everything the dashboard needs, in one flat table.
local function snapshot()
  local x, y, z, facing = nav.position()
  local stats = nav.stats()
  local level = fuel.level()

  return {
    label = os.getComputerLabel() or ("turtle-" .. os.getComputerID()),
    role = "miner",
    job = quarry.name,
    phase = status.phase,
    detail = status.detail,
    x = x,
    y = y,
    z = z,
    facing = facing,
    world = worldPos,
    -- math.huge does not survive a round trip cleanly; -1 means "fuel off".
    fuel = level == math.huge and -1 or level,
    fuelFraction = fuel.fraction(),
    distanceHome = nav.distanceHome(),
    moves = stats.moves,
    digs = stats.digs,
    delivered = job.delivered,
    layer = job.layer,
    layers = quarry.layers(job),
    progress = quarry.progress(job),
    startedAt = job.startedAt,
  }
end

local function drawLocal()
  local snap = snapshot()
  ui.clear()
  ui.header(snap.label, net.isOpen() and (baseId and "linked" or "no base") or "no modem")

  ui.text(2, 3, ("%-10s %s"):format("phase", snap.phase), ui.theme.accent)
  ui.text(2, 4, ("%-10s %s"):format("", util.fit(snap.detail, 36)), ui.theme.dim)
  ui.text(2, 6, ("%-10s %d, %d, %d"):format("at", snap.x, snap.y, snap.z))
  ui.text(2, 7, ("%-10s %d blocks"):format("home", snap.distanceHome))
  ui.text(2, 9, ("%-10s %s"):format("fuel", snap.fuel < 0 and "unlimited" or util.count(snap.fuel)))
  ui.bar(13, 10, 20, snap.fuelFraction)
  ui.text(2, 12, ("%-10s %d / %d"):format("layer", snap.layer, snap.layers))
  ui.bar(13, 13, 20, snap.progress, ui.theme.accent)
  ui.text(
    2,
    15,
    ("%-10s %s mined, %s delivered"):format(
      "totals",
      util.count(snap.digs),
      util.count(snap.delivered)
    )
  )

  ui.footer("Ctrl+T to stop - progress is saved")
end

--- Called by the job. Cheap, so it can fire often.
local function report(phase, detail)
  status.phase = phase
  status.detail = detail or ""
  drawLocal()
end

local function heartbeat()
  while true do
    -- GPS costs a two second timeout, so refresh it rarely.
    if os.clock() - lastGps > GPS_REFRESH_SECONDS then
      lastGps = os.clock()
      worldPos = nav.worldPosition() or worldPos
    end

    if not baseId then
      baseId = net.findBase()
      if baseId then
        log.info("found base station " .. baseId)
        net.send(baseId, "hello", snapshot())
      end
    end

    if baseId and not net.send(baseId, "status", snapshot()) then
      baseId = nil -- lost it; look again next tick
    end

    drawLocal()
    sleep(HEARTBEAT_SECONDS)
  end
end

local function main()
  net.open()
  baseId = net.findBase()

  if not job.active then
    job = quarry.setup(ui)
  else
    ui.clear()
    print("Unfinished quarry: layer " .. job.layer .. " of " .. quarry.layers(job) .. ".\n")
    print("Resuming in 5s. Press any key to set up a new one.")

    local timer = os.startTimer(5)
    while true do
      local event, id = os.pullEvent()
      if event == "timer" and id == timer then
        break
      elseif event == "key" then
        print("\nReturning home first...")
        nav.goHome()
        job = quarry.setup(ui)
        break
      end
    end
  end

  log.info("starting " .. quarry.name)

  local ok, err
  parallel.waitForAny(function()
    ok, err = quarry.run(job, report)
  end, heartbeat)

  return ok, err
end

-- pcall returns (succeeded, ...main's returns), so unpack both layers.
local completed, first, second = pcall(main)
local ok, err

if completed then
  ok, err = first, second
else
  ok, err = false, first
end

if tostring(err):find("Terminated") then
  report("stopped", "terminated by player")
  log.warn("terminated by player")
else
  report(ok and "done" or "stuck", tostring(err or "complete"))
  if ok then
    log.info("job complete")
  else
    log.error("job stopped: " .. tostring(err))
  end
end

if baseId then
  net.send(baseId, "status", snapshot())
end

ui.clear()
if ok then
  print("Quarry complete. Everything is in the chest.")
else
  printError("Stopped: " .. tostring(err))
  print("Progress is saved - run again to resume.")
end
