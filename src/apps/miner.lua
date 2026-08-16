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
local sound = require("core.sound")
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

local node = config.load(NODE_PATH, {
  role = "miner",
  label = nil,
  job = nil,
  parked = false,
  parkKind = nil,
  parkReason = nil,
})

local baseId = nil
local worldPos = nil
local lastGps = 0
local lastLookup = 0

local control = {
  recall = false,
  deploy = false,
  configure = false,
  changeJob = false,
  setJob = nil,
  settings = nil,
}
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

-- Older ICOS builds persisted only `parked`, so a completed expedition came
-- back after an update as an anonymous 95% park. Recover that state once.
if
  node.parked
  and not node.parkKind
  and (jobModule.status(job).progress or 0) >= 0.95
  and not job.active
then
  node.parkKind = "complete"
  node.parkReason = "job complete"
  config.save(NODE_PATH, node)
end

--- Everything the dashboard needs, in one flat table.
local function snapshot()
  local x, y, z, facing = nav.position()
  local stats = nav.stats()
  local level = fuel.level()
  local jobStatus = jobModule.status(job)
  local fuelRequired = jobModule.estimateFuel and jobModule.estimateFuel(job) or nil

  local progress = jobStatus.progress
  if node.parked and node.parkKind == "complete" then
    progress = 1
  end

  return {
    label = os.getComputerLabel() or ("turtle-" .. os.getComputerID()),
    role = "miner",
    job = jobModule.name,
    phase = status.phase,
    detail = status.detail,
    parked = node.parked,
    parkKind = node.parkKind,
    x = x,
    y = y,
    z = z,
    facing = facing,
    world = worldPos,
    -- math.huge does not survive a round trip cleanly; -1 means "fuel off".
    fuel = level == math.huge and -1 or level,
    fuelFraction = fuel.fraction(),
    fuelRequired = fuelRequired,
    distanceHome = nav.distanceHome(),
    moves = stats.moves,
    digs = stats.digs,
    delivered = jobStatus.delivered,
    haul = jobStatus.haul,
    progress = progress,
    settings = jobStatus.settings,
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

  local width, height = ui.size()
  ui.text(2, 3, ("%-9s %s"):format("job", snap.job), ui.theme.dim)
  ui.text(2, 4, ("%-9s %s"):format("phase", snap.phase), ui.theme.accent)
  ui.text(2, 5, ui.pad(util.fit(snap.detail, width - 3), width - 3), ui.theme.dim)
  ui.text(2, 7, ("%-9s %d, %d, %d"):format("at", snap.x, snap.y, snap.z))
  ui.text(2, 8, ("%-9s %d blocks"):format("home", snap.distanceHome))
  local fuelText = snap.fuel < 0 and "unlimited" or util.count(snap.fuel)
  if node.parked and snap.fuelRequired and snap.fuel >= 0 then
    fuelText = fuelText .. " / " .. util.count(snap.fuelRequired) .. " needed"
  end
  ui.text(2, 9, ("%-9s %s"):format("fuel", fuelText))

  -- Working: fuel against the walk home. Parked: fuel against the next job.
  local barWidth = math.max(8, math.min(20, width - 13))
  local fuelGoal = node.parked and snap.fuelRequired or (snap.distanceHome * 3)
  local fuelTone = node.parked
      and fuelGoal
      and snap.fuel >= 0
      and snap.fuel < fuelGoal
      and ui.theme.bad
    or nil
  ui.bar(12, 10, barWidth, snap.fuel / math.max(1, fuelGoal or 1), fuelTone)
  ui.text(2, 11, ("%-9s %d%%"):format("progress", math.floor((snap.progress or 0) * 100)))
  ui.bar(12, 12, barWidth, snap.progress or 0, ui.theme.accent)

  if height >= 16 then
    ui.text(
      2,
      14,
      ("%-9s %s dug, %s delivered"):format(
        "totals",
        util.count(snap.digs),
        util.count(snap.delivered)
      )
    )
  end

  if node.parked then
    ui.footer("D start  C setup  J job  Q exit")
  else
    ui.footer("R recall  Q exit - progress is saved")
  end
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
        net.broadcast("hello", snapshot())
      end
      baseId = found or baseId
    end

    -- Broadcast rather than address the base directly. It costs nothing extra
    -- on a local network, works before the base has ever been found, and means
    -- any number of listeners - a second monitor, a pocket computer - can watch
    -- the fleet without the turtles knowing they exist.
    net.broadcast("status", snapshot())

    drawLocal()
    sleep(HEARTBEAT_SECONDS)
  end
end

local function reply(id, action, ok, message)
  if id then
    net.send(id, "command_result", {
      action = action,
      ok = ok,
      message = message,
      snapshot = snapshot(),
    })
  end
end

local function commands()
  while true do
    local sender, kind, body = net.receive(1)
    if kind == "command" and type(body) == "table" then
      if body.action == "recall" then
        if node.parked then
          reply(sender, body.action, true, "already parked")
        else
          log.warn("recalled by base")
          control.recall = true
          reply(sender, body.action, true, "recall accepted")
        end
      elseif body.action == "deploy" then
        if node.parked then
          log.info("deploy order from base")
          control.deploy = true
          control.deployFrom = sender
        else
          reply(sender, body.action, false, "already running")
        end
      elseif body.action == "set_job" then
        if node.parked then
          control.setJob = { name = body.job, sender = sender }
        else
          reply(sender, body.action, false, "recall this turtle first")
        end
      elseif body.action == "configure" then
        if node.parked then
          control.settings = { values = body.settings, sender = sender }
        else
          reply(sender, body.action, false, "recall this turtle first")
        end
      elseif body.action == "status_request" then
        net.send(sender, "status", snapshot())
      elseif body.action == "rename" and type(body.label) == "string" then
        local label = body.label:sub(1, 32)
        os.setComputerLabel(label)
        node.label = label
        config.save(NODE_PATH, node)
        reply(sender, body.action, true, "renamed to " .. label)
      end
    end
  end
end

local function localControls()
  while true do
    local event = { os.pullEvent() }
    if event[1] == "key" and not interactive then
      local key = event[2]
      if key == keys.q then
        return
      elseif node.parked and (key == keys.d or key == keys.enter) then
        control.deploy = true
      elseif node.parked and key == keys.c then
        control.configure = true
      elseif node.parked and key == keys.j then
        control.changeJob = true
      elseif not node.parked and key == keys.r then
        control.recall = true
      end
    elseif event[1] == "mouse_click" and not interactive then
      local _, height = ui.size()
      local x, y = event[3], event[4]
      if y == height then
        if node.parked then
          if x >= 2 and x <= 8 then
            control.deploy = true
          elseif x >= 11 and x <= 17 then
            control.configure = true
          elseif x >= 20 and x <= 24 then
            control.changeJob = true
          elseif x >= 27 and x <= 32 then
            return
          end
        elseif x >= 2 and x <= 9 then
          control.recall = true
        elseif x >= 12 and x <= 17 then
          return
        end
      end
    end
  end
end

local function selectJob(name, requireExisting)
  local nextModule = JOBS[name]
  if not nextModule then
    return false, "unknown job " .. tostring(name)
  end
  if requireExisting and not fs.exists(nextModule.PATH) then
    return false, "configure " .. name .. " locally once before remote use"
  end

  local nextJob = nextModule.load()

  if not fs.exists(nextModule.PATH) then
    if name == "expedition" then
      local here = nav.worldPosition()
      if not here then
        return false, "set this turtle's position before selecting expedition"
      end
      nextJob.surfaceY = here.y
    end
    nextModule.save(nextJob)
  end

  node.job = name
  jobModule = nextModule
  job = nextJob
  config.save(NODE_PATH, node)
  return true
end

--- Sit still, stay visible, and accept local or remote controls.
local function park(reason, kind)
  node.parked = true
  node.parkKind = kind or node.parkKind or "idle"
  node.parkReason = reason or node.parkReason or "waiting for orders"
  config.save(NODE_PATH, node)
  report("parked", node.parkReason)
  log.info("parked: " .. tostring(node.parkReason))

  local launchRequester = nil
  while true do
    if control.setJob then
      local request = assert(control.setJob)
      control.setJob = nil
      if not node.parked then
        reply(request.sender, "set_job", false, "recall this turtle first")
      else
        local ok, err = selectJob(request.name, false)
        if ok then
          node.parkKind = "idle"
          node.parkReason = "job changed to " .. request.name
          config.save(NODE_PATH, node)
          report("parked", node.parkReason)
          reply(request.sender, "set_job", true, node.parkReason)
        else
          reply(request.sender, "set_job", false, err)
        end
      end
    elseif control.settings then
      local request = assert(control.settings)
      control.settings = nil
      if type(request.values) ~= "table" or not jobModule.configure then
        reply(request.sender, "configure", false, "this job cannot be configured remotely")
      else
        local ok, err = jobModule.configure(job, request.values)
        if ok then
          node.parkKind = "idle"
          node.parkReason = "settings saved"
          config.save(NODE_PATH, node)
          report("parked", node.parkReason)
          reply(request.sender, "configure", true, "settings saved")
        else
          reply(request.sender, "configure", false, err)
        end
      end
    elseif control.configure then
      control.configure = false
      interactive = true
      job = jobModule.setup(ui)
      interactive = false
      if job.active then
        node.parked = false
        node.parkKind = nil
        node.parkReason = nil
        config.save(NODE_PATH, node)
        log.info("configured and launched locally")
        return
      end
      node.parkKind = "idle"
      node.parkReason = "setup incomplete"
      config.save(NODE_PATH, node)
      report("parked", node.parkReason)
    elseif control.changeJob then
      control.changeJob = false
      interactive = true
      local name = chooseJob()
      selectJob(name, false)
      job = jobModule.setup(ui)
      interactive = false
      if job.active then
        node.parked = false
        node.parkKind = nil
        node.parkReason = nil
        config.save(NODE_PATH, node)
        log.info("changed job and launched locally")
        return
      end
      node.parkKind = "idle"
      node.parkReason = "setup incomplete"
      config.save(NODE_PATH, node)
      report("parked", node.parkReason)
    elseif control.deploy then
      control.deploy = false
      local requester = control.deployFrom
      control.deployFrom = nil

      -- Refuse to launch a job that cannot finish. Otherwise an empty turtle
      -- leaves home, trips its safety margin, and wastes fuel returning.
      local canStart, why = true, nil
      if jobModule.ready then
        canStart, why = jobModule.ready(job)
      end

      if canStart then
        launchRequester = requester
        break
      end

      log.warn("deploy refused: " .. tostring(why))
      sound.play("error")
      node.parkKind = "error"
      node.parkReason = why or "not ready"
      config.save(NODE_PATH, node)
      report("parked", node.parkReason)
      reply(requester, "deploy", false, node.parkReason)
    end
    sleep(0.2)
  end

  control.recall = false

  -- "Here" becomes home. If you physically moved the turtle while it was
  -- parked, this is what makes the new spot the reference point - which is the
  -- whole reason recall exists.
  nav.setHome()
  job = jobModule.restart(job)
  node.parked = false
  node.parkKind = nil
  node.parkReason = nil
  config.save(NODE_PATH, node)
  log.info("redeployed")
  reply(launchRequester, "deploy", true, jobModule.name .. " started")
end

local function agent()
  -- A turtle that rebooted mid-job carries on; one that was parked stays parked.
  if node.parked then
    park(node.parkReason or "parked before reboot", node.parkKind)
  elseif not job.active then
    interactive = true
    job = jobModule.setup(ui)
    interactive = false
    if not job.active then
      park("setup incomplete", "idle")
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

    -- Only control.recall means "recalled". Jobs also return a reason string on
    -- ordinary failure, so testing that here reported every out-of-fuel and
    -- depot-full abort as a recall and hid the real cause.
    if control.recall then
      control.recall = false
      park("recalled - move me, then press deploy", "recalled")
    elseif not ok then
      log.error("job stopped: " .. tostring(stopped))
      sound.play("error")
      park("stopped: " .. tostring(stopped), "error")
    else
      sound.play("ready")
      park("job complete", "complete")
    end
  end
end

net.open()
log.info("miner agent starting (" .. node.job .. ")")

local completed, err = pcall(function()
  parallel.waitForAny(agent, heartbeat, commands, localControls)
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
