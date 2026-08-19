--- What a turtle does when a job ends, and which order it takes orders in.
---
--- These decisions lived inside `legacy/miner/runtime.lua`, in the middle of a
--- loop that also draws a screen, writes a file, plays a sound and sleeps - so
--- **none of them had ever been tested.** Section 14 puts the turtle runtime
--- first in the retirement order because it is the piece most likely to need a
--- second attempt, and this is the half that can be pinned down before anything
--- is rewritten around it.

local expect = require("support.expect")
local it = require("support.spec").it

local lifecycle = require("domain.turtle.lifecycle")

---------------------------------------------------------------------------
-- After a job run
---------------------------------------------------------------------------

it("recall outranks a job that finished normally", function()
  local outcome = lifecycle.after({ ok = true, stopKind = "complete", recalled = true })
  expect.equal(outcome.action, "park", "parks")
  expect.equal(outcome.kind, "recalled", "as recalled, not as complete")
end)

it("recall outranks a job that failed", function()
  -- A turtle recalled *while* its job was failing must park as recalled: the
  -- operator asked for it home, and reporting an error instead leaves a turtle
  -- that was told to come back looking like a turtle that broke.
  local outcome = lifecycle.after({ ok = false, stopped = "bedrock", recalled = true })
  expect.equal(outcome.kind, "recalled", "recalled wins")
  expect.equal(outcome.tone, nil, "and it is not an error sound")
end)

it("a job that reports itself recalled is the same as the flag", function()
  local outcome = lifecycle.after({ ok = true, stopKind = "recalled" })
  expect.equal(outcome.kind, "recalled", "either route says recalled")
end)

it("the recall reason mentions where, because that is the bug it prevents", function()
  -- The common reason for a recall is that somebody is about to move the
  -- turtle, and a turtle moved without re-declaring its origin dead-reckons
  -- from the wrong place - a whole shift mined in the wrong sector.
  local outcome = lifecycle.after({ ok = true, recalled = true })
  expect.contains(outcome.reason, "where", "says to run where")
end)

it("a failed job parks as an error and says so out loud", function()
  local outcome = lifecycle.after({ ok = false, stopped = "hit bedrock" })
  expect.equal(outcome.kind, "error", "kind")
  expect.contains(outcome.reason, "hit bedrock", "carrying what the job said")
  expect.equal(outcome.tone, "error", "and an error sound")
end)

it("a fuel stop is not a failure", function()
  -- A turtle that came home because its return reserve said so did exactly the
  -- right thing. Reporting it as an error would train somebody to ignore
  -- errors, which is the same argument D025 makes about the stall counter.
  local outcome = lifecycle.after({ ok = true, stopKind = "fuel", stopped = "reserve reached" })
  expect.equal(outcome.kind, "fuel", "its own kind, not error")
  expect.equal(outcome.tone, "ready", "and the ordinary chime")
end)

it("a continuous job cycles instead of parking", function()
  local outcome = lifecycle.after({ ok = true, stopKind = "cycle", continuous = true })
  expect.equal(outcome.action, "cycle", "goes round again")
  expect.equal(outcome.reason, nil, "with nothing to report - it has not stopped")
end)

it("a one-shot job that reports a cycle has simply finished", function()
  -- `cycle` from a job that is not continuous is a pass completed, not a pass
  -- to repeat. Cycling one would put a turtle in a loop nobody asked for.
  local outcome = lifecycle.after({ ok = true, stopKind = "cycle", continuous = false })
  expect.equal(outcome.action, "park", "parks")
  expect.equal(outcome.kind, "complete", "as complete")
end)

it("a finished job parks as complete with a default reason", function()
  local outcome = lifecycle.after({ ok = true })
  expect.equal(outcome.kind, "complete", "complete")
  expect.truthy(outcome.reason, "and never parks with no reason at all")
end)

it("every park carries a reason and a kind, whatever the job said", function()
  -- A park with no reason is a turtle sitting still with a blank line where the
  -- explanation goes, which is the state this fleet has spent the most time
  -- diagnosing.
  for _, result in ipairs({
    { ok = true },
    { ok = false },
    { ok = true, stopKind = "fuel" },
    { ok = true, recalled = true },
    { ok = true, stopKind = "cycle" },
  }) do
    local outcome = lifecycle.after(result)
    if outcome.action == "park" then
      expect.truthy(outcome.reason and #outcome.reason > 0, "a reason")
      expect.truthy(outcome.kind, "and a kind")
    end
  end
end)

---------------------------------------------------------------------------
-- Which order to service
---------------------------------------------------------------------------

it("nothing pending is nil, not an error", function()
  expect.equal(lifecycle.pending({}), nil, "an idle parked turtle")
  expect.equal(lifecycle.pending(nil), nil, "and a missing table is not a crash")
end)

it("update goes first, because it replaces the code that would do the rest", function()
  local order = lifecycle.pending({ update = {}, assignment = {}, deploy = true })
  expect.equal(order, "update", "update")
end)

it("deploy goes last, because it is the one that ends being parked", function()
  -- Servicing deploy before a pending job change would deploy the turtle on the
  -- job it had before, which is exactly the three-message race section 5
  -- collapses into one goal.
  expect.equal(lifecycle.pending({ deploy = true, changeJob = true }), "changeJob", "job first")
  expect.equal(lifecycle.pending({ deploy = true, setJob = {} }), "setJob", "remote job first")
  expect.equal(lifecycle.pending({ deploy = true, settings = {} }), "settings", "settings first")
  expect.equal(lifecycle.pending({ deploy = true }), "deploy", "and alone it is serviced")
end)

it("the priority order is the list, in order", function()
  -- Asserted against the declared list rather than restated, so the list stays
  -- the single place the order is written down.
  for index, name in ipairs(lifecycle.PRIORITY) do
    local flags = {}
    for later = index, #lifecycle.PRIORITY do
      flags[lifecycle.PRIORITY[later]] = true
    end
    expect.equal(lifecycle.pending(flags), name, "with everything from " .. name .. " pending")
  end
end)

---------------------------------------------------------------------------
-- The keys on the turtle itself
---------------------------------------------------------------------------

it("a parked turtle can be deployed and a running one cannot", function()
  -- Not a guard bolted on afterwards: `deploy` is simply not in the running
  -- table, which is why it cannot be got wrong by somebody adding a key later.
  expect.equal(lifecycle.keypress("d", true), "deploy", "parked, d deploys")
  expect.equal(lifecycle.keypress("enter", true), "deploy", "and so does enter")
  expect.equal(lifecycle.keypress("d", false), nil, "running, d means nothing")
end)

it("a running turtle can be recalled and a parked one cannot", function()
  expect.equal(lifecycle.keypress("r", false), "recall", "running, r recalls")
  expect.equal(lifecycle.keypress("r", true), nil, "parked, it is already home")
end)

it("quit works in either state, because it is the way out", function()
  expect.equal(lifecycle.keypress("q", true), "quit", "parked")
  expect.equal(lifecycle.keypress("q", false), "quit", "and running")
end)

it("a key nobody bound means nothing, in either state", function()
  expect.equal(lifecycle.keypress("z", true), nil, "parked")
  expect.equal(lifecycle.keypress("z", false), nil, "running")
  expect.equal(lifecycle.keypress(nil, true), nil, "and no key at all is not a crash")
end)

it("every key maps to a flag the priority list knows, or to quit", function()
  -- A key that raised a flag nothing services would be a button that does
  -- nothing, which is worse than no button.
  local known = { quit = true }
  for _, name in ipairs(lifecycle.PRIORITY) do
    known[name] = true
  end
  known.recall = true -- serviced by the job loop, not by the park loop

  for state, bindings in pairs(lifecycle.KEYS) do
    for key, action in pairs(bindings) do
      expect.truthy(known[action], state .. " key " .. key .. " raises a known flag: " .. action)
    end
  end
end)

---------------------------------------------------------------------------
-- Admitting a deploy
---------------------------------------------------------------------------

it("a deploy needs both checks, and prepare is asked first", function()
  -- `prepare` claims a sector and `ready` prices the route home. Asking them
  -- the other way round checks the fuel for the old route and then takes a
  -- longer one, which is how a turtle leaves without its return reserve.
  expect.truthy(lifecycle.admit({ ok = true }, { ok = true }), "both happy")

  local admitted, why, kind =
    lifecycle.admit({ ok = false, why = "no sector", kind = "setup" }, nil)
  expect.falsy(admitted, "refused")
  expect.equal(why, "no sector", "with prepare's reason")
  expect.equal(kind, "setup", "and prepare's kind")

  local second, secondWhy = lifecycle.admit({ ok = true }, { ok = false, why = "not enough fuel" })
  expect.falsy(second, "refused")
  expect.equal(secondWhy, "not enough fuel", "with ready's reason")
end)

it("a refusal always has a reason and a kind", function()
  local admitted, why, kind = lifecycle.admit({ ok = false }, nil)
  expect.falsy(admitted, "refused")
  expect.truthy(why, "with something to show")
  expect.truthy(kind, "and something to group by")
end)
