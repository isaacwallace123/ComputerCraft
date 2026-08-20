--- The job loop: run, park, wait for orders, go again.
---
--- This is the half of the turtle runtime that had never been tested, because
--- it lived inside a `while true` that also drew a screen, wrote a file, played
--- a sound and slept. Every effect is now injected, so a whole
--- park-deploy-mine-recall cycle runs here against a table of counters and no
--- world at all.

local expect = require("support.expect")
local it = require("support.spec").it

local runner = require("os.turtle.runner")

--- A job that reports whatever the test tells it to.
local function fakeJob(script)
  script = script or {}
  local job = {
    runs = 0,
    restarts = 0,
    prepared = 0,
    readied = 0,
    continuous = script.continuous == true,
    name = "test job",
  }

  function job.prepare()
    job.prepared = job.prepared + 1
    if script.prepare == false then
      return false, script.prepareWhy or "cannot prepare", script.prepareKind
    end
    return true
  end

  function job.ready()
    job.readied = job.readied + 1
    if script.ready == false then
      return false, script.readyWhy or "not enough fuel", script.readyKind
    end
    return true
  end

  function job.restart(state)
    job.restarts = job.restarts + 1
    return state
  end

  function job.run()
    job.runs = job.runs + 1
    if script.onRun then
      return script.onRun(job)
    end
    return true, script.stopped, script.stopKind
  end

  return job
end

--- A runner with every effect recorded rather than performed.
local function build(script, options)
  options = options or {}
  local seen = {
    saved = 0,
    idled = 0,
    homes = 0,
    tones = {},
    reports = {},
    logs = {},
  }
  local job = fakeJob(script)

  local built = runner.new({
    node = options.node or { parked = true },
    flags = options.flags or {},
    job = { active = true },
    module = job,
    effects = {
      saveNode = function()
        seen.saved = seen.saved + 1
      end,
      report = function(phase, detail)
        seen.reports[#seen.reports + 1] = { phase = phase, detail = detail }
      end,
      log = function(message)
        seen.logs[#seen.logs + 1] = message
      end,
      tone = function(name)
        seen.tones[#seen.tones + 1] = name
      end,
      setHome = function()
        seen.homes = seen.homes + 1
      end,
      idle = function()
        seen.idled = seen.idled + 1
      end,
    },
    handlers = options.handlers,
  })

  return built, seen, job
end

---------------------------------------------------------------------------
-- Parking
---------------------------------------------------------------------------

it("parking records a reason, saves it, and says so", function()
  -- All three, because a turtle that parked without saving forgets on reboot,
  -- and one that parked without reporting is a turtle sitting still with a
  -- blank line where the explanation goes.
  local built, seen = build()
  built:park("out of fuel", "fuel")

  expect.truthy(built.node.parked, "parked")
  expect.equal(built.node.parkReason, "out of fuel", "with the reason")
  expect.equal(built.node.parkKind, "fuel", "and the kind")
  expect.equal(seen.saved, 1, "written to disk")
  expect.equal(seen.reports[1].phase, "parked", "and shown on the screen")
end)

it("parking with no reason keeps the one it had", function()
  -- A second park must not blank an explanation somebody is reading.
  local built = build()
  built:park("recalled by base", "recalled")
  built:park()
  expect.equal(built.node.parkReason, "recalled by base", "kept")
end)

---------------------------------------------------------------------------
-- Starting
---------------------------------------------------------------------------

it("a deploy asks both checks and declares home before working", function()
  local built, seen, job = build()
  expect.truthy(built:start(), "started")

  expect.equal(job.prepared, 1, "prepare asked")
  expect.equal(job.readied, 1, "ready asked")
  expect.equal(seen.homes, 1, "home declared")
  expect.equal(job.restarts, 1, "and the job restarted")
  expect.falsy(built.node.parked, "no longer parked")
end)

it("a refused deploy parks with the job's own reason", function()
  -- The turtle should be sitting at its chest saying why, not throwing.
  local built, seen = build({ ready = false, readyWhy = "not enough fuel", readyKind = "fuel" })

  expect.falsy(built:start(), "refused")
  expect.truthy(built.node.parked, "still parked")
  expect.equal(built.node.parkReason, "not enough fuel", "with the reason")
  expect.equal(built.node.parkKind, "fuel", "and the kind")
  expect.equal(seen.tones[1], "error", "and it makes a noise about it")
  expect.equal(seen.homes, 0, "home was not declared for a trip it did not take")
end)

it("prepare is asked before ready, because ready prices the route prepare chose", function()
  -- Backwards, this checks the fuel for the old route and then takes a longer
  -- one, which is how a turtle leaves without its return reserve.
  local order = {}
  local built = build()
  built.module.prepare = function()
    order[#order + 1] = "prepare"
    return true
  end
  built.module.ready = function()
    order[#order + 1] = "ready"
    return true
  end

  built:start()
  expect.equal(order[1], "prepare", "prepare first")
  expect.equal(order[2], "ready", "then ready")
end)

it("a job with no prepare or ready is taken at its word", function()
  local built = build()
  built.module.prepare = nil
  built.module.ready = nil
  expect.truthy(built:start(), "started")
end)

---------------------------------------------------------------------------
-- Working
---------------------------------------------------------------------------

it("a finished job parks and a continuous one goes round again", function()
  local once = build({ stopKind = "complete" }, { node = { parked = false } })
  once:work()
  expect.truthy(once.node.parked, "one-shot parks")

  local always, seen, job = build({ stopKind = "cycle", continuous = true }, {
    node = { parked = false },
  })
  always:work()
  expect.falsy(always.node.parked, "continuous keeps working")
  expect.equal(job.restarts, 1, "having restarted the job")
  expect.equal(seen.homes, 1, "and re-declared home for the new run")
end)

it("a cycle that cannot refuel parks instead of leaving again", function()
  -- The check that stops a turtle setting off on a sector it cannot come back
  -- from. `start` is what performs it, which is why cycling goes through it.
  local built = build({
    stopKind = "cycle",
    continuous = true,
    ready = false,
    readyWhy = "not enough fuel for another run",
  }, { node = { parked = false } })

  built:work()
  expect.truthy(built.node.parked, "parked")
  expect.contains(built.node.parkReason, "not enough fuel", "with the reason")
end)

it("a recall while the job was failing parks as recalled, not as broken", function()
  local built = build({
    onRun = function()
      return false, "hit bedrock"
    end,
  }, { node = { parked = false }, flags = { recall = true } })

  built:work()
  expect.equal(built.node.parkKind, "recalled", "recalled wins")
  expect.falsy(built.flags.recall, "and the flag is cleared so it cannot fire twice")
end)

it("the job is told when it has been recalled, and asks rather than being interrupted", function()
  -- D004: a recall is a goal, not an interrupt. Only the job knows where it is
  -- safe to stop.
  local asked = nil
  local built = build(nil, { node = { parked = false }, flags = { recall = true } })

  built.module.run = function(_, jobContext)
    asked = jobContext.aborted()
    return true, "stopped", "recalled"
  end

  built:work()
  expect.truthy(asked, "the job could see it had been recalled")
end)

---------------------------------------------------------------------------
-- Waiting
---------------------------------------------------------------------------

it("a parked turtle with nothing pending idles rather than spinning", function()
  -- Without this the wait loop runs at full speed and starves every other
  -- coroutine on the machine - on a turtle that means the heartbeat stops and
  -- the base decides it has gone.
  local built, seen = build()
  built:wait()
  expect.equal(seen.idled, 1, "it waited")
end)

it("deploy is serviced by the runner and clears its own flag", function()
  local built = build(nil, { flags = { deploy = true } })
  expect.truthy(built:wait(), "now working")
  expect.falsy(built.flags.deploy, "flag cleared")
  expect.falsy(built.node.parked, "and unparked")
end)

it("an order with a handler is passed to it", function()
  local called = 0
  local built = build(nil, {
    flags = { update = {} },
    handlers = {
      update = function()
        called = called + 1
        return false
      end,
    },
  })

  built:wait()
  expect.equal(called, 1, "the handler ran")
end)

it("an order with no handler is dropped, loudly, rather than serviced forever", function()
  -- Nothing else clears it, so leaving it would spin the machine at full speed
  -- on an order nobody can carry out.
  local built, seen = build(nil, { flags = { settings = {} } })
  built:wait()

  expect.equal(built.flags.settings, nil, "dropped")
  expect.contains(seen.logs[1], "no handler", "and said so")
end)

it("update is serviced before deploy, so a turtle never deploys stale code", function()
  local order = {}
  local built = build(nil, {
    flags = { update = {}, deploy = true },
    handlers = {
      update = function(self)
        order[#order + 1] = "update"
        self.flags.update = nil
        return false
      end,
    },
  })

  built:wait()
  expect.equal(order[1], "update", "update first")
  expect.truthy(built.flags.deploy, "and the deploy is still waiting its turn")
end)

---------------------------------------------------------------------------
-- The whole cycle
---------------------------------------------------------------------------

it("park, deploy, mine, recall - with no world at all", function()
  -- The point of injecting every effect: the entire lifecycle is exercised
  -- here, and none of it was reachable by a test before.
  local built, seen, job = build({ stopKind = "cycle", continuous = true })

  built:step() -- parked, nothing pending
  expect.equal(seen.idled, 1, "waiting")

  built.flags.deploy = true
  built:step() -- deploy
  expect.falsy(built.node.parked, "deployed")

  built:step() -- one mining pass, continuous so it cycles
  expect.equal(job.runs, 1, "mined")
  expect.falsy(built.node.parked, "still going")

  built.flags.recall = true
  built:step() -- next pass sees the recall
  expect.truthy(built.node.parked, "came home")
  expect.equal(built.node.parkKind, "recalled", "because it was recalled")
end)
