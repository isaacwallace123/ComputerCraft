--- The supervisor: one service dying is one service dying.
---
--- Plain Lua coroutines and an injected clock, so the parts that only happen
--- after five failures and thirty seconds are exercised by advancing a number.
--- Nobody would ever sit and wait for those in a world, which is precisely why
--- they are the parts that ship broken.

local expect = require("support.expect")
local it = require("support.spec").it

local service = require("os.kernel.service")
local supervisor = require("os.kernel.supervisor")

--- A clock the test drives by hand.
local function fakeClock()
  local self = { time = 0 }
  self.port = {
    now = function()
      return self.time
    end,
    sleep = function() end,
  }
  function self.advance(seconds)
    self.time = self.time + seconds * 1000
    return self.time
  end
  return self
end

--- A service that counts how many events it saw and can be told to explode.
local function counter(id, options)
  options = options or {}
  local state = { id = id, events = 0, contexts = 0, boom = options.boom }
  state.definition = service.define({
    id = id,
    critical = options.critical,
    requires = options.requires,
    run = function(context)
      state.contexts = state.contexts + 1
      state.context = context
      while true do
        if state.boom then
          error(id .. " exploded", 0)
        end
        if options.returns then
          return
        end
        local event = { coroutine.yield(options.filter) }
        state.events = state.events + 1
        state.last = event[1]
      end
    end,
  })
  return state
end

local function withServices(...)
  local clock = fakeClock()
  local errors = {}
  local sup = supervisor.new({
    clock = clock.port,
    onError = function(id, reason)
      errors[#errors + 1] = { id = id, reason = reason }
    end,
  })
  for _, entry in ipairs({ ... }) do
    sup:add(entry.definition)
  end
  return sup, clock, errors
end

--- The health row for one service. Raises rather than returning nil: a test
--- looking up a service that is not registered has already failed, and saying so
--- here beats an "attempt to index a nil value" three lines later.
local function healthOf(sup, id)
  for _, row in ipairs(sup:health()) do
    if row.id == id then
      return row
    end
  end
  error("no service named " .. tostring(id), 2)
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

it("a service is handed its context first and events after", function()
  -- Getting this backwards hands a service its first event as its context and
  -- every event thereafter as nothing at all.
  local one = counter("one")
  local sup, clock = withServices(one)
  local ports = { transport = {}, clock = clock.port }

  sup:start(ports)
  sup:step()
  expect.equal(one.contexts, 1, "run was called once")
  expect.equal(one.context, ports, "with the context")

  sup:step({ "rednet_message", 7 })
  expect.equal(one.events, 1, "and then an event")
  expect.equal(one.last, "rednet_message", "the right one")
end)

it("a service that asks for one event only gets that one", function()
  -- CC's own filter: a coroutine that yields a string is asking to be resumed
  -- only for that event, which is what `os.pullEvent(name)` compiles down to.
  -- Honouring it means an existing service loop needs no changes to run here
  -- rather than under `parallel`.
  local picky = counter("picky", { filter = "timer" })
  local sup, clock = withServices(picky)
  sup:start({})
  sup:step()

  sup:step({ "rednet_message" })
  expect.equal(picky.events, 0, "ignored")
  sup:step({ "timer", 1 })
  expect.equal(picky.events, 1, "taken")
end)

---------------------------------------------------------------------------
-- One dying is one dying
---------------------------------------------------------------------------

it("a service that throws does not take its neighbours with it", function()
  -- The whole reason this exists. `parallel.waitForAny` returns when any
  -- coroutine finishes, so today an error escaping the fleet service stops
  -- discovery, leases, policy, logging and persistence together.
  local good, bad = counter("good"), counter("bad", { boom = true })
  local sup, clock, errors = withServices(good, bad)
  sup:start({})
  sup:step()

  expect.equal(good.contexts, 1, "the healthy one started")
  expect.equal(#errors, 1, "the other reported once")
  expect.contains(errors[1].reason, "bad exploded", "with its error")

  sup:step({ "timer" })
  expect.equal(good.events, 1, "and the healthy one is still taking events")
  expect.equal(sup:running(), 1, "with one of two running")
end)

it("a service that returns is a fault, not a success", function()
  -- A service runs for the life of the machine, so falling off the end of `run`
  -- is a fault. Treated as one so it backs off rather than being restarted in a
  -- tight loop, which would spin the machine at full speed forever.
  local quitter = counter("quitter", { returns = true })
  local sup, clock, errors = withServices(quitter)
  sup:start({})
  sup:step()

  expect.contains(errors[1].reason, "returned", "reported as a return")
  expect.equal(healthOf(sup, "quitter").state, "waiting", "and backing off rather than respinning")
end)

it("a service missing a port it declared is refused before it starts", function()
  -- Otherwise it is a nil index somewhere inside its own loop, on a machine with
  -- no screen, at whatever moment it first reaches that line.
  local needy = counter("needy", { requires = { "transport", "storage" } })
  local sup, clock, errors = withServices(needy)
  sup:start({ transport = {} })

  expect.equal(needy.contexts, 0, "never ran")
  expect.contains(errors[1].reason, "storage", "and the missing port is named")
end)

---------------------------------------------------------------------------
-- Backoff, and giving up loudly
---------------------------------------------------------------------------

it("restarts back off, and the delay grows", function()
  local bad = counter("bad", { boom = true })
  local sup, clock = withServices(bad)
  sup:start({})
  sup:step()

  local health = healthOf(sup, "bad")
  expect.equal(health.state, "waiting", "waiting to retry")
  expect.near(health.retryIn, 1, 0.01, "one second after the first failure")

  clock.advance(1)
  sup:step()
  expect.near(healthOf(sup, "bad").retryIn, 2, 0.01, "two after the second")

  clock.advance(2)
  sup:step()
  expect.near(healthOf(sup, "bad").retryIn, 4, 0.01, "then four")
end)

it("a service is not retried before its backoff has elapsed", function()
  local bad = counter("bad", { boom = true })
  local sup, clock = withServices(bad)
  sup:start({})
  sup:step()
  expect.equal(bad.contexts, 1, "ran once")

  clock.advance(0.5)
  sup:step()
  expect.equal(bad.contexts, 1, "not yet")

  clock.advance(0.6)
  sup:step()
  expect.equal(bad.contexts, 2, "and then again")
end)

it("a crash loop gives up and says so, rather than retrying forever", function()
  -- D025's lesson, applied: back off, then stop and say so. A supervisor that
  -- silently restarted a crash-looping service for an hour would be worse than
  -- no supervisor, because the dashboard would say everything was fine.
  local bad = counter("bad", { boom = true })
  local sup, clock = withServices(bad)
  sup:start({})

  for _ = 1, 10 do
    sup:step()
    clock.advance(60)
  end

  local health = healthOf(sup, "bad")
  expect.truthy(health.gaveUp, "gave up")
  expect.equal(health.state, "stopped", "and stopped")
  expect.equal(bad.contexts, supervisor.GIVE_UP_AFTER, "after exactly the allowed attempts")
  expect.contains(health.lastError, "exploded", "with the reason kept")
end)

it("a service that recovers has its failure count cleared", function()
  -- Two different questions - "is this flaky" and "is this crash-looping right
  -- now" - so two different numbers. A service that fails twice and then runs
  -- for a week should not be one failure from being abandoned.
  local flaky = counter("flaky", { boom = true })
  local sup, clock = withServices(flaky)
  sup:start({})
  sup:step()
  clock.advance(2)
  sup:step()

  expect.equal(healthOf(sup, "flaky").failures, 2, "two consecutive failures")

  flaky.boom = false
  clock.advance(5)
  sup:step()
  sup:step({ "timer" })

  local health = healthOf(sup, "flaky")
  expect.equal(health.failures, 0, "cleared by a successful resume")
  expect.equal(health.restarts, 2, "but the restart count is kept for the panel")
end)

it("an operator can revive a service that gave up", function()
  -- Deliberately manual. A supervisor that reset its own counter on a timer
  -- would turn "gave up after five failures" into "retries forever, slowly",
  -- which is the state this design exists to make visible rather than to reach.
  local bad = counter("bad", { boom = true })
  local sup, clock = withServices(bad)
  sup:start({})
  for _ = 1, 10 do
    sup:step()
    clock.advance(60)
  end
  expect.truthy(healthOf(sup, "bad").gaveUp, "abandoned")

  bad.boom = false
  expect.truthy(sup:revive("bad"), "revived")
  sup:step()
  expect.falsy(healthOf(sup, "bad").gaveUp, "running again")
  expect.equal(healthOf(sup, "bad").failures, 0, "with a clean slate")
end)

---------------------------------------------------------------------------
-- Health
---------------------------------------------------------------------------

it("a critical service giving up makes the machine unhealthy", function()
  -- GPS is the example that matters: an outage breaks navigation for the whole
  -- fleet, and it must not be possible for a bug in the auto-recovery policy to
  -- cause one.
  local gps = counter("gps", { boom = true, critical = true })
  local policy = counter("policy")
  local sup, clock = withServices(gps, policy)
  sup:start({})

  expect.truthy(sup:healthy(), "healthy to begin with")

  for _ = 1, 10 do
    sup:step()
    clock.advance(60)
  end

  local healthy, why = sup:healthy()
  expect.falsy(healthy, "and unhealthy once a critical service gives up")
  expect.contains(why, "gps", "naming it")
end)

it("a non-critical service giving up degrades quietly", function()
  local policy = counter("policy", { boom = true })
  local sup, clock = withServices(policy)
  sup:start({})
  for _ = 1, 10 do
    sup:step()
    clock.advance(60)
  end

  expect.truthy(sup:healthy(), "the machine still does its job")
  expect.truthy(healthOf(sup, "policy").gaveUp, "but the failure is still reported")
end)

it("health reports what the Services page draws", function()
  -- The panel sketch in §8, as data. The supervisor never prints - a supervisor
  -- that drew would be a service that draws, which §8 forbids.
  local one, two = counter("discovery"), counter("leases", { boom = true })
  local sup, clock = withServices(one, two)
  sup:start({})
  sup:step()

  local rows = sup:health()
  expect.equal(#rows, 2, "one row per service")
  expect.equal(rows[1].id, "discovery", "in registration order")
  expect.equal(rows[1].state, "running", "with its state")
  expect.equal(rows[2].restarts, 0, "restarts")
  expect.truthy(rows[2].lastError, "and the last error where there is one")
end)

it("how long a service ran between yields is recorded", function()
  -- Cooperative multitasking cannot be enforced from here: a service that never
  -- yields starves every other service and no runtime built on `coroutine` can
  -- preempt it. The most this can do is notice, so a starving service shows up
  -- as a number rather than as a machine that feels sluggish.
  local clock = fakeClock()
  local sup = supervisor.new({ clock = clock.port })
  sup:add(service.define({
    id = "hog",
    run = function()
      while true do
        clock.advance(2)
        coroutine.yield()
      end
    end,
  }))

  sup:start({})
  sup:step()
  expect.truthy(healthOf(sup, "hog").slowest >= 2000, "two seconds inside one resume, noticed")
end)

---------------------------------------------------------------------------
-- The manifest
---------------------------------------------------------------------------

it("a malformed service is refused where it was written", function()
  local ok, err = pcall(service.define, { run = function() end })
  expect.falsy(ok, "no id")
  expect.contains(err, "string id", "said so")

  ok, err = pcall(service.define, { id = "x" })
  expect.falsy(ok, "no run")
  expect.contains(err, "run function", "said so")

  ok = pcall(service.define, { id = "x", run = function() end, requires = "transport" })
  expect.falsy(ok, "requires must be a list")
end)

it("two services cannot share an id", function()
  local sup = supervisor.new({ clock = fakeClock().port })
  sup:add(service.define({ id = "twice", run = function() end }))
  local ok, err = pcall(function()
    sup:add(service.define({ id = "twice", run = function() end }))
  end)
  expect.falsy(ok, "refused")
  expect.contains(err, "duplicate", "by name")
end)

---------------------------------------------------------------------------
-- Shutting down
---------------------------------------------------------------------------

it("a machine going down is not a service failing", function()
  -- CC delivers `terminate` into the coroutine, where it surfaces as an error
  -- out of whatever the service was parked in. So a clean Ctrl-T made every
  -- service on the machine report a fault, and put one warning per service in
  -- the log - which is how a log teaches people to ignore failures.
  local clock = fakeClock()
  local reported = {}
  local sup = supervisor.new({
    clock = clock.port,
    onError = function(id)
      reported[#reported + 1] = id
    end,
  })

  for _, id in ipairs({ "one", "two", "three" }) do
    sup:add(service.define({
      id = id,
      run = function()
        while true do
          coroutine.yield()
          error("Terminated", 0)
        end
      end,
    }))
  end

  sup:start({})
  sup:step()
  expect.equal(#reported, 0, "nothing wrong yet")

  sup:shutdown({ "terminate" })
  expect.equal(#reported, 0, "and a deliberate stop reports nothing")
  expect.equal(sup:running(), 0, "everything stopped")
end)

it("a real failure is still reported after a shutdown has not happened", function()
  -- The guard is on the shutdown, not on the reporting. A service that dies on
  -- an ordinary event must still be heard about, or the fix above would have
  -- silenced the thing the supervisor exists for.
  local clock = fakeClock()
  local reported = {}
  local sup = supervisor.new({
    clock = clock.port,
    onError = function(id)
      reported[#reported + 1] = id
    end,
  })
  sup:add(service.define({
    id = "breaks",
    run = function()
      coroutine.yield()
      error("genuinely broken", 0)
    end,
  }))

  sup:start({})
  sup:step()
  sup:step({ "tick" })
  expect.equal(#reported, 1, "reported")
  expect.equal(reported[1], "breaks", "by name")
end)
