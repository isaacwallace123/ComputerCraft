--- Mining turtle agent.
---
--- A long-lived state machine rather than a one-shot program:
---
---   working  --job ends or recalled-->  parked  --deploy command-->  working
---
--- Parking instead of exiting is what makes the fleet controllable. A parked
--- turtle is still on the dashboard and still listening, so "everyone come
--- home" and "everyone go back out" are each one keypress on the base.
---
--- Reporting is fire-and-forget. Out of modem range - which happens - the
--- turtle keeps working and simply shows as stale. Nothing about a job depends
--- on the network being up.

package.path = "/?.lua;/?/init.lua;" .. package.path

if not turtle then
  printError("This is a turtle program.")
  return
end

local ui = require("core.ui")
local net = require("core.net")
local log = require("core.log")
local util = require("core.util")
local config = require("core.config")
local nav = require("turtle.nav")
local fuel = require("turtle.fuel")

local JOBS = {
  quarry = require("jobs.quarry"),
  expedition = require("jobs.expedition"),
}

local HEARTBEAT_SECONDS = 2
local GPS_REFRESH_SECONDS = 30
local BASE_RECHECK_SECONDS = 60

local NODE_PATH = ".node"

local node = config.load(NODE_PATH, { role = "miner", label = nil, job = nil, parked = false })

local baseId = nil
local worldPos = nil
local lastGps = 0
local lastLookup = 0

local control = { recall = false, deploy = false }
local status = { phase = "idle", detail = "" }

-- Set while a setup prompt is on screen. The heartbeat thread runs alongside
-- the agent, so without this it would clear the terminal underneath the
-- questions the player is halfway through answering.
local interactive = false

--- Ask which job this turtle runs. Only on first boot.
local function chooseJob()
  local names, labels = {}, {}
  for name in pairs(JOBS) do
    names[#names + 1] = name
  end
  table.sort(names)
  for i, name in ipairs(names) do
    labels[i] = name
  end

  local choice = ui.menu("Which job?", labels)
  return choice and names[choice] or names[1]
end

if not node.job or not JOBS[node.job] then
  node.job = chooseJob()
  config.save(NODE_PATH, node)
end

local jobModule = JOBS[node.job]
local job = jobModule.load()

--- Everything the dashboard needs, in one flat table.
local function snapshot()
  local x, y, z, facing = nav.position()
  local stats = nav.stats()
  local level = fuel.level()
  local jobStatus = jobModule.status(job)

  return {
    label = os.getComputerLabel() or ("turtle-" .. os.getComputerID()),
    role = "miner",
    job = jobModule.name,
    phase = status.phase,
    detail = status.detail,
    parked = node.parked,
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
    delivered = jobStatus.delivered,
    haul = jobStatus.haul,
    progress = jobStatus.progress,
    startedAt = job.startedAt,
  }
end

local function drawLocal()
  if interactive then
    return
  end
  local snap = snapshot()
  ui.clear()
  ui.header(snap.label, net.isOpen() and (baseId and "linked" or "no base") or "no modem")

  ui.text(2, 3, ("%-9s %s"):format("job", snap.job), ui.theme.dim)
  ui.text(2, 4, ("%-9s %s"):format("phase", snap.phase), ui.theme.accent)
  ui.text(2, 5, ("%-9s %s"):format("", util.fit(snap.detail, 38)), ui.theme.dim)
  ui.text(2, 7, ("%-9s %d, %d, %d"):format("at", snap.x, snap.y, snap.z))
  ui.text(2, 8, ("%-9s %d blocks"):format("home", snap.distanceHome))
  ui.text(2, 10, ("%-9s %s"):format("fuel", snap.fuel < 0 and "unlimited" or util.count(snap.fuel)))
  -- Fuel against the walk home, not against the tank - see apps/fleet.lua.
  ui.bar(12, 11, 20, snap.fuel / math.max(1, snap.distanceHome * 3))
  ui.text(2, 13, ("%-9s %d%%"):format("progress", math.floor((snap.progress or 0) * 100)))
  ui.bar(12, 14, 20, snap.progress or 0, ui.theme.accent)
  ui.text(
    2,
    16,
    ("%-9s %s dug, %s delivered"):format(
      "totals",
      util.count(snap.digs),
      util.count(snap.delivered)
    )
  )

  ui.footer("Ctrl+T to stop - progress is saved")
end

local function report(phase, detail)
  status.phase = phase
  status.detail = detail or ""
  drawLocal()
end

local function heartbeat()
  while true do
    if os.clock() - lastGps > GPS_REFRESH_SECONDS then
      lastGps = os.clock()
      worldPos = nav.worldPosition() or worldPos
    end

    -- rednet.send reports success as soon as the packet leaves the modem, so it
    -- never tells us the base has gone. Re-resolve the hostname periodically
    -- instead, which also picks up a base rebuilt with a different ID.
    if not baseId or os.clock() - lastLookup > BASE_RECHECK_SECONDS then
      lastLookup = os.clock()
      local found = net.findBase()
      if found and found ~= baseId then
        log.info("base station is " .. found)
        net.send(found, "hello", snapshot())
      end
      baseId = found or baseId
    end

    if baseId then
      net.send(baseId, "status", snapshot())
    end

    drawLocal()
    sleep(HEARTBEAT_SECONDS)
  end
end

local function commands()
  while true do
    local _, kind, body = net.receive(1)
    if kind == "command" and type(body) == "table" then
      if body.action == "recall" then
        log.warn("recalled by base")
        control.recall = true
      elseif body.action == "deploy" then
        log.info("deploy order from base")
        control.deploy = true
      end
    end
  end
end

--- Sit still, stay visible, wait for a deploy order.
local function park(reason)
  node.parked = true
  config.save(NODE_PATH, node)
  report("parked", reason or "waiting for orders")
  log.info("parked: " .. tostring(reason))

  while not control.deploy do
    sleep(1)
  end

  control.deploy = false
  control.recall = false

  -- "Here" becomes home. If you physically moved the turtle while it was
  -- parked, this is what makes the new spot the reference point - which is the
  -- whole reason recall exists.
  nav.setHome()
  job = jobModule.restart(job)
  node.parked = false
  config.save(NODE_PATH, node)
  log.info("redeployed")
end

local function agent()
  -- A turtle that rebooted mid-job carries on; one that was parked stays parked.
  if node.parked then
    park("parked before reboot")
  elseif not job.active then
    interactive = true
    job = jobModule.setup(ui)
    interactive = false
    if not job.active then
      park("setup incomplete")
    end
  end

  while true do
    local ctx = {
      report = report,
      aborted = function()
        return control.recall and "recalled by base" or nil
      end,
    }

    local ok, stopped = jobModule.run(job, ctx)

    if control.recall or stopped then
      control.recall = false
      park("recalled - move me, then press deploy")
    elseif not ok then
      log.error("job stopped: " .. tostring(stopped))
      park("stopped: " .. tostring(stopped))
    else
      park("job complete")
    end
  end
end

net.open()
log.info("miner agent starting (" .. node.job .. ")")

local completed, err = pcall(function()
  parallel.waitForAny(agent, heartbeat, commands)
end)

if not completed and not tostring(err):find("Terminated") then
  log.error(tostring(err))
  ui.clear()
  printError(tostring(err))
  print("\nProgress is saved - reboot to resume.")
else
  ui.clear()
  print("Miner agent stopped.")
end
