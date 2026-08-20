local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local desired = require("domain.fleet.desired")
local policy = require("os.server.services.policy")
local policyRules = require("domain.fleet.policy")
local registry = require("domain.fleet.registry")

local parked = fleet.parked
local serverContext = fleet.server

---------------------------------------------------------------------------
-- Policy: an unattended fleet that fixes itself and never overrules a person
---------------------------------------------------------------------------

it("a refuelled turtle is sent back to work", function()
  local ctx = serverContext()
  parked(ctx, 7, { parkKind = "fuel", fuel = 500, fuelRequired = 200 })

  local acted = policy.pass(ctx, ctx.clock.now())
  expect.equal(#acted, 1, "one recovery")
  expect.equal(acted[1].rule, "fuel", "the fuel rule")
  expect.equal(registry.get(ctx.state.fleet, 7).desired.mode, "deploy", "goal set, not a command")
end)

it("policy never overrules a person", function()
  -- The rule ICOS 1 stated in a comment and enforced by having no rule that
  -- happened to match. Here it is structural: a standing goal that is not
  -- `deploy` is somebody's decision, and no rule is even consulted.
  local ctx = serverContext()
  local record = parked(ctx, 7, { parkKind = "fuel", fuel = 500, fuelRequired = 200 })
  desired.want(record, "recall", nil, ctx.clock.now())

  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "a recalled turtle is left alone")
  expect.equal(record.desired.mode, "recall", "and stays recalled")

  -- And the guard is the thing being tested, not the absence of a matching rule.
  expect.falsy(policyRules.mayAct(record), "no rule may run against it")
end)

it("a recovery is not re-decided every pass", function()
  local ctx = serverContext()
  parked(ctx, 7, { parkKind = "error", detail = "depot full at 12,64,-3" })

  expect.equal(#policy.pass(ctx, ctx.clock.now()), 1, "acted once")
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "and not again immediately")

  -- The goal is unchanged rather than re-sent, which is the whole reason a
  -- generation compares by content: a policy loop must not bump it every pass.
  local record = registry.get(ctx.state.fleet, 7)
  expect.equal(record.desired.generation, 1, "one generation, not three")

  ctx._clock.advance(policyRules.COOLDOWN.depot + 1)
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "still nothing to say - the goal is right")
end)

it("only one turtle updates per pass", function()
  -- A rolling update that queues ten turtles at once is not rolling, it is a
  -- fleet that all stops at the same moment.
  local ctx = serverContext()
  ctx.version = "2.0.0"
  ctx.policy = policyRules.normalise({ updateParked = true })
  for id = 1, 4 do
    parked(ctx, id, { parkKind = "manual", version = "1.9.0" })
  end

  local acted = policy.pass(ctx, ctx.clock.now())
  expect.equal(#acted, 1, "one at a time")
  expect.equal(acted[1].mode, "update", "and it is an update")

  -- Deterministic, because `pairs` order would make it a different turtle every
  -- pass and a different order after every reboot.
  expect.equal(acted[1].id, 1, "the same turtle every time")
end)

it("updates stay opt-in and skip a turtle that is already in trouble", function()
  local ctx = serverContext()
  ctx.version = "2.0.0"
  parked(ctx, 7, { parkKind = "manual", version = "1.9.0" })
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "off by default")

  ctx.policy = policyRules.normalise({ updateParked = true })
  ctx.attempts = {}
  ctx.state.fleet = registry.empty()
  parked(ctx, 7, { parkKind = "error", detail = "stuck", version = "1.9.0" })
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "a broken turtle needs a person")
end)

it("a device that has gone quiet is not acted on from a stale snapshot", function()
  -- "Parked for fuel" twenty minutes ago is not evidence of anything now.
  local ctx = serverContext()
  parked(ctx, 7, { parkKind = "fuel", fuel = 500, fuelRequired = 200 })
  ctx._clock.advance(20 * 60)

  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "nothing decided from old news")
end)

it("policy can be switched off entirely", function()
  local ctx = serverContext()
  ctx.policy = policyRules.normalise({ enabled = false })
  parked(ctx, 7, { parkKind = "fuel", fuel = 500, fuelRequired = 200 })
  expect.equal(#policy.pass(ctx, ctx.clock.now()), 0, "and then it does nothing at all")
end)
