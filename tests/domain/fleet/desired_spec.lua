--- Desired state: the five properties section 5 promises, as tests.
---
--- The plan calls phase 3 the high-risk one, and the reason is that it replaces
--- a safety control while turtles are underground. Every claim it makes is
--- checkable without a world, so every one of them is checked here rather than
--- discovered on a fleet.

local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local desired = require("domain.fleet.desired")

local SECOND = 1000

local function record()
  return {}
end

---------------------------------------------------------------------------
-- Setting a goal
---------------------------------------------------------------------------

it("a new goal gets the next generation", function()
  local device = record()
  local goal, changed = desired.want(device, "recall", nil, 1000 * SECOND)

  expect.truthy(changed, "reported as a change")
  expect.equal(goal.mode, "recall", "the mode")
  expect.equal(goal.generation, 1, "generations start at one")
  expect.equal(desired.reply(device).mode, "recall", "and it is what gets sent")
end)

it("asking for the same goal again does not bump the generation", function()
  -- The property that makes this safe to call from a policy loop on every pass,
  -- which is how it will actually be used. Without it, re-asserting "park"
  -- every thirty seconds would make every device re-apply an order it was
  -- already obeying - the event model wearing a new hat.
  local device = record()
  desired.want(device, "park", nil, 1000 * SECOND)
  local goal, changed = desired.want(device, "park", nil, 1060 * SECOND)

  expect.falsy(changed, "not a change")
  expect.equal(goal.generation, 1, "and the generation held still")
end)

it("a goal that differs in what it carries is a different goal", function()
  -- Â§5: the record removes the three-message set-job / configure / deploy
  -- dance, so a job change and a deployment are one goal with one generation.
  -- They cannot half-arrive, and a turtle can never end up deployed on the job
  -- it had before.
  local device = record()
  desired.want(device, "deploy", { job = "rare" }, 1000 * SECOND)
  local goal, changed = desired.want(device, "deploy", { job = "quarry" }, 1030 * SECOND)

  expect.truthy(changed, "the job changed the goal")
  expect.equal(goal.generation, 2, "so the generation moved")
  expect.equal(goal.job, "quarry", "carrying the new job")
end)

it("settings are compared by content, not by identity", function()
  local device = record()
  desired.want(device, "deploy", { settings = { targetY = -59 } }, 0)
  local _, unchanged = desired.want(device, "deploy", { settings = { targetY = -59 } }, 0)
  expect.falsy(unchanged, "a fresh table with the same contents is the same goal")

  local goal, changed = desired.want(device, "deploy", { settings = { targetY = 12 } }, 0)
  expect.truthy(changed, "a different value is a different goal")
  expect.equal(goal.generation, 2, "and bumps once")
end)

it("an unknown mode is refused rather than stored", function()
  local device = record()
  local ok, err = pcall(function()
    desired.want(device, "explode", nil, 0)
  end)
  expect.falsy(ok, "refused")
  expect.contains(err, "no such mode", "by name")
  expect.equal(desired.reply(device), nil, "and nothing was recorded")
end)

---------------------------------------------------------------------------
-- Convergence
---------------------------------------------------------------------------

it("a device that has applied the goal is converged", function()
  local device = record()
  desired.want(device, "recall", nil, 1000 * SECOND)

  expect.equal(desired.status(device, 1000 * SECOND), "unreachable", "nothing has reported yet")

  desired.observe(device, desired.report(0, "mining"), 1002 * SECOND)
  expect.equal(desired.status(device, 1002 * SECOND), "pending", "heard from, not caught up")

  desired.observe(device, desired.report(1, "recall"), 1004 * SECOND)
  expect.equal(desired.status(device, 1004 * SECOND), "converged", "caught up")
end)

it("pending becomes unreachable when the device also goes quiet", function()
  -- The distinction the old UI could not draw. An order not yet applied by a
  -- device that is still talking is in flight; the same order from a device
  -- that has stopped talking is a missing turtle, and showing both as "sent" is
  -- what made three of them look busy.
  local device = record()
  desired.want(device, "recall", nil, 1000 * SECOND)
  desired.observe(device, desired.report(0, "mining"), 1000 * SECOND)

  expect.equal(desired.status(device, 1030 * SECOND, 60), "pending", "still in flight")
  expect.equal(desired.status(device, 1200 * SECOND, 60), "unreachable", "gone quiet")
end)

it("a device with nothing asked of it is converged", function()
  local device = record()
  expect.truthy(desired.converged(device), "no goal is a goal met")
  expect.equal(desired.status(device, 0), "converged", "and reads as such")
end)

---------------------------------------------------------------------------
-- The device side, where the invariants live
---------------------------------------------------------------------------

it("a device applies an order once and ignores the replay", function()
  local incoming = { mode = "recall", generation = 41 }

  local accepted = assert(desired.apply(40, incoming), "newer than what it had")
  expect.equal(accepted.generation, 41, "at the new generation")

  expect.equal(desired.apply(41, incoming), nil, "the same message again changes nothing")
  expect.equal(desired.apply(99, incoming), nil, "and neither does an older one")
end)

it("an order that overtook a newer one cannot undo it", function()
  -- Rednet promises nothing about ordering. A reply carrying generation 40 can
  -- arrive after one carrying 41, and monotonicity is the only thing standing
  -- between that and a recalled turtle quietly going back to work.
  expect.equal(desired.apply(41, { mode = "deploy", generation = 40 }), nil, "refused")
  expect.truthy(desired.apply(41, { mode = "deploy", generation = 42 }), "but a newer one is taken")
end)

it("a malformed or missing reply means carry on, never stop", function()
  -- D004, expressed as a return value. Losing the server, or receiving
  -- nonsense, must leave a turtle doing exactly what it was already doing -
  -- because the alternative is a fleet that strands itself the moment the base
  -- station reboots.
  expect.equal(desired.apply(5, nil), nil, "no reply at all")
  expect.equal(desired.apply(5, "recall"), nil, "not a table")
  expect.equal(desired.apply(5, {}), nil, "no generation and no mode")
  expect.equal(desired.apply(5, { mode = "recall" }), nil, "no generation")
  expect.equal(desired.apply(5, { generation = 9 }), nil, "no mode")
  expect.equal(
    desired.apply(5, { mode = "wander", generation = 9 }),
    nil,
    "a mode it does not know"
  )
end)

it("a device with no applied generation takes the first order it sees", function()
  local accepted = assert(desired.apply(nil, { mode = "park", generation = 1 }), "a fresh device")
  expect.equal(accepted.mode, "park", "applies")
end)

it("a rebooted device does not re-run an order it already carried out", function()
  -- The applied generation is persisted, so a turtle that recalls and then
  -- reboots reads it back and stays put. A recall that re-ran on every boot
  -- would be a turtle that could never be redeployed.
  local persisted = 41
  local reply = { mode = "recall", generation = 41 }
  expect.equal(desired.apply(persisted, reply), nil, "already done")
end)

it("everything the goal carries reaches the device", function()
  local accepted = assert(desired.apply(0, {
    mode = "deploy",
    generation = 7,
    job = "rare",
    settings = { targetY = -59 },
    reason = "diamonds",
  }))
  expect.equal(accepted.job, "rare", "job")
  expect.equal(accepted.settings.targetY, -59, "settings")
  expect.equal(accepted.reason, "diamonds", "and why, for the log")
end)

---------------------------------------------------------------------------
-- End to end
---------------------------------------------------------------------------

it("a recall survives a turtle being away for twenty minutes", function()
  -- The failure the whole phase exists for: the base sends recall, the turtle
  -- is in an unloaded chunk, the message is gone, the dashboard says "sent",
  -- and nothing ever happens.
  local device = record()
  local applied = 0

  -- The turtle is working and up to date.
  desired.observe(device, desired.report(applied, "mining"), 0)
  expect.equal(desired.status(device, 0), "converged", "nothing outstanding")

  -- Recall is asked for while the turtle is out of range. Nothing is delivered.
  desired.want(device, "recall", nil, 10 * SECOND)
  expect.equal(desired.status(device, 30 * SECOND, 60), "pending", "in flight")
  expect.equal(desired.status(device, 1200 * SECOND, 60), "unreachable", "and then plainly not")

  -- Twenty minutes later the chunk loads and the turtle checks in. The order is
  -- still there, because it was never a message.
  local reply = desired.reply(device)
  local accepted = assert(desired.apply(applied, reply), "the order is waiting for it")
  expect.equal(accepted.mode, "recall", "and it is the recall")

  applied = accepted.generation
  desired.observe(device, desired.report(applied, "recall"), 1210 * SECOND)
  expect.equal(desired.status(device, 1210 * SECOND), "converged", "converged at last")
end)

it("two orders while a device is away collapse to the newer one", function()
  -- The device never sees the intermediate state, which is the point: desired
  -- state is where a device should be, not a queue of things it must replay.
  local device = record()
  desired.want(device, "recall", nil, 0)
  desired.want(device, "park", { reason = "operator" }, 10 * SECOND)

  local accepted = assert(desired.apply(0, desired.reply(device)))
  expect.equal(accepted.mode, "park", "only the latest goal")
  expect.equal(accepted.generation, 2, "at the latest generation")
end)
