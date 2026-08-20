local expect = require("support.expect")
local registry = require("apps.registry")
local it = require("support.spec").it
local fleet = require("support.fleet")

local roles = require("os.kernel.roles")
local services = require("apps.services.app")
local shell = require("os.client.shell")
local turtleOs = require("os.turtle.main")
local ui = require("ui.init")

local booted = fleet.booted
local fakeClock = fleet.clock

---------------------------------------------------------------------------
-- The Services page: the surface you use when everything else is broken
---------------------------------------------------------------------------

it("the failing service is first, because the healthy ones need no attention", function()
  local clock = fakeClock(0)
  local machine = booted(roles.CLIENT, {
    draw = function()
      error("no screen", 0)
    end,
  })
  machine.clock = machine.clock or clock

  for _ = 1, 10 do
    machine.supervisor:step()
    machine.clock.advance(60)
  end

  local rows = services.rows(machine.supervisor, machine.clock.port.now())
  expect.equal(rows[1].id, "screen", "the broken one is at the top")
  expect.equal(rows[1].status, "gave up", "and says so plainly")
  expect.contains(rows[1].detail, "no screen", "with what it actually said")
end)

it("a backing-off service says how long until it tries again", function()
  -- The state a machine spends its time in while somebody is walking over to
  -- look at it, and the one that looks like nothing on every other screen.
  expect.equal(services.status({ state = "running" }), "running", "plain")
  expect.equal(services.status({ state = "waiting", retryIn = 7.2 }), "retrying 8s", "counts down")
  expect.equal(services.status({ gaveUp = true, state = "waiting" }), "gave up", "or has stopped")

  -- `waiting` is what the supervisor calls it and "retrying" is what a person
  -- needs; the internal word and the displayed word are allowed to differ.
  expect.equal(services.status({ state = "waiting" }), "retrying", "even with no timer")
end)

it("a degraded machine is still healthy, and the page says both", function()
  -- Somebody reading a page with a red row and the word "healthy" underneath
  -- needs to be told why those are both true, or they conclude it is lying.
  local machine = booted(roles.CLIENT, {
    draw = function()
      error("no screen", 0)
    end,
  })

  for _ = 1, 10 do
    machine.supervisor:step()
    machine.clock.advance(60)
  end

  local summary = services.summary(machine.supervisor, machine.clock.port.now())
  expect.truthy(machine.supervisor:healthy(), "the machine is healthy")
  expect.contains(summary, "degraded", "and the summary admits what is not")
end)

it("an unhealthy machine names the service that made it so", function()
  local machine = booted(roles.TURTLE, {
    runJob = function()
      error("bedrock", 0)
    end,
  })

  for _ = 1, 10 do
    machine.supervisor:step()
    machine.clock.advance(60)
  end

  local summary = services.summary(machine.supervisor, machine.clock.port.now())
  expect.contains(summary, "unhealthy", "unhealthy")
  expect.contains(summary, "job", "and it names the job")
end)

it("a non-critical failure is warned about, not alarmed about", function()
  -- Painting a degraded client the same red as a dead turtle trains somebody to
  -- ignore both.
  local T = require("ui.theme").TOKENS
  expect.equal(services.tone({ gaveUp = true, critical = true }), T.destructive, "critical is red")
  expect.equal(services.tone({ gaveUp = true, critical = false }), T.warn, "the rest is amber")
  expect.equal(services.tone({ state = "running", failures = 0 }), T.good, "and running is green")
  expect.equal(services.tone({ state = "running", failures = 3 }), T.warn, "unless it is flapping")
end)

it("the page counts restarts rather than the failure counter", function()
  -- Failures resets to zero the moment a service comes back, so a service that
  -- has crashed forty times today and is up right now shows zero - which is
  -- true and useless.
  local columns = services.columns()
  local last = columns[#columns]
  expect.equal(last.Key, "restarts", "restarts, not failures")
end)

it("a turtle gets the Services page without a turtle version being written", function()
  -- The whole benefit of filtering by surface. Somebody standing in front of a
  -- stopped turtle wants "job: gave up - bedrock", and that page appeared by
  -- declaring the surface rather than by being ported.
  local available = registry.available("turtle", "launcher")
  local ids = {}
  for _, entry in ipairs(available) do
    ids[entry.id] = true
  end
  expect.truthy(ids.services, "the diagnostic page is there")

  -- Devices is deliberately not there: a turtle showing a fleet roster would be
  -- a turtle drawing something it has no copy of.
  for _, entry in ipairs(available) do
    expect.falsy(entry.id == "devices", "no fleet roster on a turtle")
  end
end)

it("a turtle's supervisor is on its context, so the page has something to read", function()
  local machine = booted(roles.TURTLE)
  expect.truthy(machine.context.supervisor, "attached")
  expect.equal(machine.context.supervisor, machine.supervisor, "and it is its own")

  local rows = services.rows(machine.context.supervisor, machine.clock.port.now())
  expect.equal(#rows, #turtleOs.services(), "listing every service the turtle runs")
end)
