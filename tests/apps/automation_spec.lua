--- The policy lives on the server, and the page only asks.

local expect = require("support.expect")
local fleet = require("support.fleet")
local it = require("support.spec").it

local automation = require("apps.automation.app")
local discovery = require("os.server.services.discovery")
local policyService = require("os.server.services.policy")

it("a toggle changes one switch and leaves the rest alone", function()
  -- Sending the whole policy would mean two people on two screens overwriting
  -- each other's unrelated changes, and neither would attribute it to the page
  -- they were looking at.
  local ctx = fleet.server()
  policyService.save(ctx, { enabled = true, retryDepot = true, updateParked = false })

  local reply = assert(discovery.handle(ctx, 1, automation.intent("updateParked", true)))

  expect.truthy(reply.policy.updateParked, "the switch moved")
  expect.truthy(reply.policy.retryDepot, "and an unrelated one did not")
  expect.truthy(reply.policy.enabled, "nor the master")
end)

it("the reply is the state after the change, not before it", function()
  -- A page that set a toggle and then asked what the toggle was would show a
  -- value it inferred rather than one the server confirmed, and the two diverge
  -- exactly when something has gone wrong.
  local ctx = fleet.server()
  policyService.save(ctx, { enabled = true, retryDepot = false })

  local reply = assert(discovery.handle(ctx, 1, automation.intent("retryDepot", true)))
  expect.truthy(reply.policy.retryDepot, "confirmed by the server")
  expect.truthy(policyService.settings(ctx).retryDepot, "and actually stored")
end)

it("a switch the policy does not have is never sent", function()
  -- The catalogue of switches is the domain's DEFAULTS, so a page cannot write
  -- a key the server would refuse to load.
  expect.falsy(automation.intent("launchMissiles", true), "not a policy field")
  expect.truthy(automation.intent("enabled", false), "and a real one is")
end)

it("reading the policy without setting anything changes nothing", function()
  local ctx = fleet.server()
  policyService.save(ctx, { enabled = false })

  local reply = assert(discovery.handle(ctx, 1, { kind = "policy" }))
  expect.falsy(reply.policy.enabled, "read back as it was")
  expect.falsy(policyService.settings(ctx).enabled, "and left alone")
end)

it("the policy rides on the mirror rather than costing a second round trip", function()
  -- Five booleans that change when a person changes them. A second request to
  -- read them would double a client's radio traffic to learn nothing new
  -- ninety-nine times out of a hundred.
  local ctx = fleet.server()
  policyService.save(ctx, { enabled = true })

  local mirror = assert(discovery.handle(ctx, 1, { kind = discovery.MIRROR }))
  expect.truthy(mirror.policy, "the mirror carries it")
  expect.truthy(mirror.policy.enabled, "with the right value")
end)

it("the page says when nothing is recovering itself", function()
  local off = { enabled = false }
  local text = automation.summary(off)
  expect.contains(text, "nothing recovers", "an off master is stated plainly")

  local on = { enabled = true, resumeRefueled = true, retryDepot = true }
  expect.contains(automation.summary(on), "2 recovery rules", "and an on one is counted")

  expect.contains(automation.summary(nil), "waiting", "a client with no server says so")
end)
