--- Local controls and autonomous job lifecycle for miner turtles.

local config = require("adapters.cc.config")
local lifecycle = require("domain.turtle.lifecycle")
local log = require("adapters.cc.logfile")
local nav = require("os.turtle.device.nav")
local runnerModule = require("os.turtle.runner")
local sound = require("adapters.cc.sound")
local ui = require("legacy.shell.ui")

local runtime = {}

--- The keys the local controls listen for, by name.
---
--- Only these. A table rather than a reverse lookup over `keys`, because that
--- table holds every key on the board and this turtle answers five of them.
local NAMED_KEYS = {
  [keys.q] = "q",
  [keys.d] = "d",
  [keys.enter] = "enter",
  [keys.c] = "c",
  [keys.j] = "j",
  [keys.r] = "r",
}

local function readyJob(ctx)
  if ctx.jobModule.ready then
    return ctx.jobModule.ready(ctx.job)
  end
  return true
end

function runtime.localControls(ctx)
  while true do
    local event = { os.pullEvent() }
    if event[1] == "key" and not ctx.interactive then
      -- Keycode to name here, meaning in `domain/turtle/lifecycle.lua`. What a
      -- key does - and which keys a parked or running turtle has at all - is a
      -- rule worth testing; which integer CC gives it is not.
      local action = lifecycle.keypress(NAMED_KEYS[event[2]], ctx.node.parked)
      if action == "quit" then
        return
      elseif action then
        ctx.control[action] = true
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
    local ready, why, kind = readyJob(ctx)
    if not ready then
      ctx.job.active = false
      ctx.jobModule.save(ctx.job)
      ctx.node.parkKind = kind or "setup"
      ctx.node.parkReason = why or "setup incomplete"
      ctx:saveNode()
      ctx:report("parked", ctx.node.parkReason)
      return false
    end
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
--- The handlers the runner cannot perform itself.
---
--- Each one needs a screen or a shell: an OTA update replaces the running code,
--- and the job pickers prompt. `os/turtle/runner.lua` knows an order was
--- serviced and whether the turtle is now working; it does not know how to ask
--- somebody a question.
---
--- Each returns true when it has already put the turtle to work, which is the
--- contract `Runner:wait` reads.
function runtime.handlers(ctx)
  return {
    update = function()
      runUpdate(ctx)
      return false
    end,
    assignment = function()
      applyAssignment(ctx)
      return false
    end,
    setJob = function()
      applyRemoteJob(ctx)
      return false
    end,
    settings = function()
      applyRemoteSettings(ctx)
      return false
    end,
    configure = function()
      ctx.control.configure = false
      return localSetup(ctx, false)
    end,
    changeJob = function()
      ctx.control.changeJob = false
      return localSetup(ctx, true)
    end,
  }
end

--- The effects the runner performs through, bound to this context.
function runtime.effects(ctx)
  return {
    saveNode = function()
      ctx:saveNode()
    end,
    report = function(phase, detail)
      ctx:report(phase, detail)
    end,
    log = function(message)
      log.info(message)
    end,
    tone = function(name)
      sound.play(name)
    end,
    setHome = function()
      nav.setHome()
    end,
    -- The pause that makes a parked turtle cheap. Without it the wait loop spins
    -- at full speed and starves every other coroutine on the machine, which on a
    -- turtle means the heartbeat stops and the base decides it has gone.
    idle = function()
      sleep(0.2)
    end,
  }
end

--- Build the runner this turtle drives its job with.
---
--- The loop, the parking and the deploy checks are `os/turtle/runner.lua` and
--- are shared with ICOS 2. What stays here is what needs a screen.
function runtime.runner(ctx)
  local built = runnerModule.new({
    node = ctx.node,
    flags = ctx.control,
    job = ctx.job,
    module = ctx.jobModule,
    effects = runtime.effects(ctx),
    handlers = runtime.handlers(ctx),
  })

  -- The job table is replaced by `restart`, and ICOS 1 keeps its copy on the
  -- context because everything else here reads `ctx.job`. Keeping the two in
  -- step is a one-line effect rather than a second source of truth.
  local start = built.start
  built.start = function(selfRef, reason)
    local working = start(selfRef, reason)
    ctx.job = selfRef.job
    return working
  end

  return built
end

--- The job service body.
---
--- A turtle that rebooted while parked parks again with the reason it had, and a
--- turtle whose job was never set up asks for setup. Everything after that is
--- the shared runner.
function runtime.agent(ctx)
  local built = runtime.runner(ctx)

  if ctx.node.parked then
    built:park(ctx.node.parkReason or "parked before reboot", ctx.node.parkKind)
  elseif not ctx.job.active then
    ctx.interactive = true
    ctx.job = ctx.jobModule.setup(ui)
    ctx.interactive = false
    built.job = ctx.job
    if ctx.job.active then
      local ready, why, kind = readyJob(ctx)
      if not ready then
        ctx.job.active = false
        ctx.jobModule.save(ctx.job)
        built:park(why or "setup incomplete", kind or "setup")
      end
    end
    if not ctx.job.active then
      built:park("setup incomplete", "idle")
    end
  end

  built:run()
end

return runtime
