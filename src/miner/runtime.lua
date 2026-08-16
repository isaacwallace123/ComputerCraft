--- Local controls and autonomous job lifecycle for miner turtles.

local config = require("core.config")
local log = require("core.log")
local nav = require("turtle.nav")
local sound = require("core.sound")
local ui = require("core.ui")

local runtime = {}

function runtime.localControls(ctx)
  while true do
    local event = { os.pullEvent() }
    if event[1] == "key" and not ctx.interactive then
      local key = event[2]
      if key == keys.q then
        return
      elseif ctx.node.parked and (key == keys.d or key == keys.enter) then
        ctx.control.deploy = true
      elseif ctx.node.parked and key == keys.c then
        ctx.control.configure = true
      elseif ctx.node.parked and key == keys.j then
        ctx.control.changeJob = true
      elseif not ctx.node.parked and key == keys.r then
        ctx.control.recall = true
      end
    elseif event[1] == "mouse_click" and not ctx.interactive then
      local _, height = ui.size()
      local x, y = event[3], event[4]
      if y == height then
        if ctx.node.parked then
          if x >= 2 and x <= 8 then
            ctx.control.deploy = true
          elseif x >= 11 and x <= 17 then
            ctx.control.configure = true
          elseif x >= 20 and x <= 24 then
            ctx.control.changeJob = true
          elseif x >= 27 and x <= 32 then
            return
          end
        elseif x >= 2 and x <= 9 then
          ctx.control.recall = true
        elseif x >= 12 and x <= 17 then
          return
        end
      end
    end
  end
end

local function runUpdate(ctx)
  local request = assert(ctx.control.update)
  ctx.control.update = nil
  ctx.node.parkKind = "updating"
  ctx.node.parkReason = "installing ICOS update"
  ctx:saveNode()
  ctx:report("updating", ctx.node.parkReason)
  ctx:reply(request.sender, "update", true, "downloading update")
  log.info("remote update starting")

  ctx.interactive = true
  local ran = shell.run("update.lua", "--automatic", "--reboot")
  ctx.interactive = false

  local result = config.load(".update-result", { ok = false, message = "update stopped" })
  ctx.node.parkKind = "error"
  ctx.node.parkReason = ran and result.message or "updater crashed"
  ctx:saveNode()
  ctx:report("parked", ctx.node.parkReason)
  ctx:reply(request.sender, "update", false, ctx.node.parkReason)
  log.error("remote update failed: " .. tostring(ctx.node.parkReason))
end

local function applyRemoteJob(ctx)
  local request = assert(ctx.control.setJob)
  ctx.control.setJob = nil
  local ok, err = ctx:selectJob(request.name, false)
  if ok then
    ctx.node.parkKind = "idle"
    ctx.node.parkReason = "job changed to " .. request.name
    ctx:saveNode()
    ctx:report("parked", ctx.node.parkReason)
    ctx:reply(request.sender, "set_job", true, ctx.node.parkReason)
  else
    ctx:reply(request.sender, "set_job", false, err)
  end
end

local function applyRemoteSettings(ctx)
  local request = assert(ctx.control.settings)
  ctx.control.settings = nil
  if type(request.values) ~= "table" or not ctx.jobModule.configure then
    ctx:reply(request.sender, "configure", false, "this job cannot be configured remotely")
    return
  end

  local ok, err = ctx.jobModule.configure(ctx.job, request.values)
  if ok then
    ctx.node.parkKind = "idle"
    ctx.node.parkReason = "settings saved"
    ctx:saveNode()
    ctx:report("parked", ctx.node.parkReason)
    ctx:reply(request.sender, "configure", true, "settings saved")
  else
    ctx:reply(request.sender, "configure", false, err)
  end
end

local function applyAssignment(ctx)
  local request = assert(ctx.control.assignment)
  ctx.control.assignment = nil
  local ok, err = ctx:selectJob(request.name, false)
  if ok and type(request.settings) == "table" and ctx.jobModule.configure then
    ok, err = ctx.jobModule.configure(ctx.job, request.settings)
  end
  if not ok then
    ctx:reply(request.sender, "assign_job", false, err)
    return
  end

  ctx.control.deploy = true
  ctx.control.deployFrom = request.sender
  ctx.node.parkKind = "assigned"
  ctx.node.parkReason = ctx.jobModule.name .. " assignment received"
  ctx:saveNode()
  ctx:report("parked", ctx.node.parkReason)
  ctx:reply(request.sender, "assign_job", true, "assignment saved; deploy queued")
end

local function localSetup(ctx, changeJob)
  -- The heartbeat runs in parallel and redraws the status screen every two
  -- seconds. Suppress it before opening the job picker as well as during that
  -- job's setup prompts, otherwise both screens continually paint over each
  -- other while the user is choosing.
  ctx.interactive = true
  if changeJob then
    local selected = ctx:chooseJob()
    local changed, changeError = ctx:selectJob(selected, false, true)
    if not changed then
      ctx.interactive = false
      ctx.node.parkKind = "error"
      ctx.node.parkReason = "could not select job: " .. tostring(changeError)
      ctx:saveNode()
      ctx:report("parked", ctx.node.parkReason)
      return false
    end
  end

  ctx.job = ctx.jobModule.setup(ui)
  ctx.interactive = false
  if ctx.job.active then
    ctx.node.parked = false
    ctx.node.parkKind = nil
    ctx.node.parkReason = nil
    ctx:saveNode()
    log.info(changeJob and "changed job and launched locally" or "configured and launched locally")
    return true
  end

  ctx.node.parkKind = "idle"
  ctx.node.parkReason = "setup incomplete"
  ctx:saveNode()
  ctx:report("parked", ctx.node.parkReason)
  return false
end

--- Sit still, stay visible, and accept local or remote controls.
function runtime.park(ctx, reason, kind)
  ctx.node.parked = true
  ctx.node.parkKind = kind or ctx.node.parkKind or "idle"
  ctx.node.parkReason = reason or ctx.node.parkReason or "waiting for orders"
  ctx:saveNode()
  ctx:report("parked", ctx.node.parkReason)
  log.info("parked: " .. tostring(ctx.node.parkReason))

  local launchRequester = nil
  while true do
    if ctx.control.update then
      runUpdate(ctx)
    elseif ctx.control.assignment then
      applyAssignment(ctx)
    elseif ctx.control.setJob then
      applyRemoteJob(ctx)
    elseif ctx.control.settings then
      applyRemoteSettings(ctx)
    elseif ctx.control.configure then
      ctx.control.configure = false
      if localSetup(ctx, false) then
        return
      end
    elseif ctx.control.changeJob then
      ctx.control.changeJob = false
      if localSetup(ctx, true) then
        return
      end
    elseif ctx.control.deploy then
      ctx.control.deploy = false
      local requester = ctx.control.deployFrom
      ctx.control.deployFrom = nil
      local canStart, why = true, nil
      if ctx.jobModule.ready then
        canStart, why = ctx.jobModule.ready(ctx.job)
      end

      if canStart then
        launchRequester = requester
        break
      end

      log.warn("deploy refused: " .. tostring(why))
      sound.play("error")
      ctx.node.parkKind = "fuel"
      ctx.node.parkReason = why or "not ready"
      ctx:saveNode()
      ctx:report("parked", ctx.node.parkReason)
      ctx:reply(requester, "deploy", false, ctx.node.parkReason)
    end
    sleep(0.2)
  end

  ctx.control.recall = false
  nav.setHome()
  ctx.job = ctx.jobModule.restart(ctx.job)
  ctx.node.parked = false
  ctx.node.parkKind = nil
  ctx.node.parkReason = nil
  ctx:saveNode()
  log.info("redeployed")
  ctx:reply(launchRequester, "deploy", true, ctx.jobModule.name .. " started")
end

local function nextMiningCycle(ctx)
  local canStart, why = true, nil
  if ctx.jobModule.ready then
    canStart, why = ctx.jobModule.ready(ctx.job)
  end
  if not canStart then
    runtime.park(ctx, why or "not enough fuel for another run", "fuel")
    return
  end

  ctx:report("cycling", "unloaded - choosing a fresh route")
  log.info("automatic mining cycle starting")
  nav.setHome()
  ctx.job = ctx.jobModule.restart(ctx.job)
end

function runtime.agent(ctx)
  if ctx.node.parked then
    runtime.park(ctx, ctx.node.parkReason or "parked before reboot", ctx.node.parkKind)
  elseif not ctx.job.active then
    ctx.interactive = true
    ctx.job = ctx.jobModule.setup(ui)
    ctx.interactive = false
    if not ctx.job.active then
      runtime.park(ctx, "setup incomplete", "idle")
    end
  end

  while true do
    local jobContext = {
      report = function(phase, detail)
        ctx:report(phase, detail)
      end,
      aborted = function()
        return ctx.control.recall and "recalled by base" or nil
      end,
    }

    local ok, stopped, stopKind = ctx.jobModule.run(ctx.job, jobContext)
    if ctx.control.recall or stopKind == "recalled" then
      ctx.control.recall = false
      runtime.park(ctx, "recalled - move me, then press deploy", "recalled")
    elseif not ok then
      log.error("job stopped: " .. tostring(stopped))
      sound.play("error")
      runtime.park(ctx, "stopped: " .. tostring(stopped), "error")
    elseif stopKind == "fuel" then
      sound.play("ready")
      runtime.park(ctx, stopped or "fuel reserve reached", "fuel")
    elseif ctx.jobModule.continuous and stopKind == "cycle" then
      nextMiningCycle(ctx)
    else
      sound.play("ready")
      runtime.park(ctx, stopped or "job complete", "complete")
    end
  end
end

return runtime
