--- The job lifecycle: run, park, wait for orders, go again.
---
--- `domain/turtle/lifecycle.lua` holds the decisions; this performs them. It is
--- the effects half of `legacy/miner/runtime.lua`, and it is the piece §14 puts
--- first in the retirement order because it is the one most likely to need a
--- second attempt.
---
--- ## Every effect is injected, and that is the whole design
---
--- Saving the node, drawing the status, playing a tone, declaring home - all of
--- them are functions passed in. Not for purity's sake: this file has to run the
--- existing mining jobs, and those read `turtle` directly through
--- `os/turtle/device/`. Rewriting them is a separate project. What injection
--- buys is that **the loop is testable without any of it**, which is the half
--- that was never testable before.
---
--- So a spec drives a whole park-deploy-mine-recall cycle with a table of
--- counters and no world, and the real turtle passes the real functions.
---
--- ## Parking is a state, not a loop
---
--- ICOS 1's `park` blocked inside a `while true` until somebody deployed, which
--- is why its four coroutines needed `parallel` and why an error in one stopped
--- the others. Here parking sets a flag and returns; `step` looks at that flag
--- and does one unit of work either way. The loop belongs to the service, the
--- service belongs to the supervisor, and a turtle that is parked is a turtle
--- whose steps happen to be short.
---
--- That is what lets the supervisor restart the job service without the turtle
--- forgetting it was parked, and what lets a spec advance the machine one step
--- at a time.
---
--- ## What it does not do
---
--- Interactive setup and OTA updates are `handlers`, supplied by whoever built
--- the runner. They need a screen and a shell, and both belong to the layer that
--- has one - today `legacy/miner/runtime.lua`, tomorrow the ICOS 2 shell. The
--- runner knows only that an order was serviced and whether the turtle should
--- now be working.

local lifecycle = require("domain.turtle.lifecycle")

local runner = {}

local Runner = {}
Runner.__index = Runner

--- Build a runner.
---
---     runner.new({
---       node = ctx.node, flags = ctx.control,
---       job = ctx.job, module = ctx.jobModule,
---       effects = { saveNode, report, log, tone, setHome, idle },
---       handlers = { update = fn, assignment = fn, ... },
---     })
---
--- `node` and `flags` are shared by reference with whoever else writes them -
--- `os/turtle/control.lua` raises the flags a recall arrives as, and it must be
--- writing to the same table this reads or the order goes nowhere.
function runner.new(options)
  options = options or {}
  local self = setmetatable({}, Runner)
  self.node = options.node or {}
  self.flags = options.flags or {}
  self.job = options.job
  self.module = options.module or {}
  self.effects = options.effects or {}
  self.handlers = options.handlers or {}
  return self
end

--- Ask the job a question it may not implement.
---
--- `prepare` and `ready` are both optional, and a job that does not have one is
--- saying yes rather than saying nothing. Returns the `{ ok, why, kind }` shape
--- `lifecycle.admit` reads.
local function ask(self, name)
  local check = self.module[name]
  if type(check) ~= "function" then
    return { ok = true }
  end
  local ok, why, kind = check(self.job)
  return { ok = ok and true or false, why = why, kind = kind }
end

local function effect(self, name, ...)
  local fn = self.effects[name]
  if type(fn) == "function" then
    return fn(...)
  end
  return nil
end

--- Stop, and say why.
---
--- Always with a reason and a kind, because `lifecycle.after` guarantees both
--- and a turtle sitting still with a blank explanation is the state this fleet
--- has spent the most time diagnosing.
function Runner:park(reason, kind)
  self.node.parked = true
  self.node.parkKind = kind or self.node.parkKind or "idle"
  self.node.parkReason = reason or self.node.parkReason or "waiting for orders"
  effect(self, "saveNode", self.node)
  effect(self, "report", "parked", self.node.parkReason)
  effect(self, "log", "parked: " .. tostring(self.node.parkReason))
  return false
end

--- Leave home and start working.
---
--- Both checks, in `lifecycle.admit`'s order, and a refusal parks rather than
--- throwing: a turtle that cannot start is a turtle that should be sitting at
--- its chest saying so.
---
--- Returns true when the turtle is now working.
function Runner:start(reason)
  local admitted, why, kind = lifecycle.admit(ask(self, "prepare"), ask(self, "ready"))
  if not admitted then
    effect(self, "tone", "error")
    effect(self, "log", "deploy refused: " .. tostring(why))
    self:park(why, kind)
    return false
  end

  -- Home is declared *here*, immediately before the job restarts, because
  -- everything the job does is relative to it. Declaring it earlier - at the
  -- moment of the order rather than the moment of departure - would anchor a
  -- turtle to wherever it happened to be standing when the radio spoke.
  effect(self, "setHome")
  self.job = self.module.restart and self.module.restart(self.job) or self.job
  self.node.parked = false
  self.node.parkKind = nil
  self.node.parkReason = nil
  effect(self, "saveNode", self.node)
  if reason then
    effect(self, "log", reason)
  end
  return true
end

--- One pass of the job, and whatever its ending means.
function Runner:work()
  local jobContext = {
    report = function(phase, detail)
      effect(self, "report", phase, detail)
    end,
    -- The job asks this rather than being told, because a job is the only thing
    -- that knows where it is safe to stop. D004: a recall is a goal, not an
    -- interrupt.
    aborted = function()
      return self.flags.recall and "recalled by base" or nil
    end,
  }

  local ok, stopped, stopKind = self.module.run(self.job, jobContext)

  local outcome = lifecycle.after({
    ok = ok,
    stopped = stopped,
    stopKind = stopKind,
    recalled = self.flags.recall,
    continuous = self.module.continuous,
  })

  if outcome.kind == "recalled" then
    -- Cleared here rather than in `lifecycle`, because clearing a flag is an
    -- effect and that module has none.
    self.flags.recall = false
  end
  if not ok then
    effect(self, "log", "job stopped: " .. tostring(stopped))
  end
  if outcome.tone then
    effect(self, "tone", outcome.tone)
  end

  if outcome.action == "cycle" then
    -- Route assignment comes before the fuel preflight, which is what `start`
    -- does: a newly leased outer sector can cost more than the one just
    -- finished, and checking the old route then claiming a new one is how a
    -- turtle leaves without its return reserve.
    effect(self, "report", "cycling", "unloaded - resuming assigned sector")
    return self:start("automatic mining cycle starting")
  end

  return self:park(outcome.reason, outcome.kind)
end

--- One unit of waiting: service a pending order, or idle.
---
--- `deploy` is handled here because it is the one order that ends the parked
--- state and the runner is what knows how. Everything else is a handler,
--- because everything else needs a screen or a shell.
---
--- A handler returning true means it has already put the turtle to work.
function Runner:wait()
  local order = lifecycle.pending(self.flags)

  if order == nil then
    effect(self, "idle")
    return false
  end

  if order == "deploy" then
    self.flags.deploy = false
    return self:start("redeployed")
  end

  local handler = self.handlers[order]
  if type(handler) ~= "function" then
    -- An order nobody can service would otherwise be serviced forever, at full
    -- speed, because nothing clears it. Dropping it is the lesser evil and
    -- saying so is the point.
    self.flags[order] = nil
    effect(self, "log", "no handler for " .. tostring(order) .. " - order dropped")
    return false
  end

  return handler(self) == true
end

--- One step of the machine, whichever state it is in.
function Runner:step()
  if self.node.parked then
    return self:wait()
  end
  return self:work()
end

--- The service body. Never returns; the supervisor treats one that does as a
--- fault, and this agrees with it.
function Runner:run()
  while true do
    self:step()
  end
end

return runner
