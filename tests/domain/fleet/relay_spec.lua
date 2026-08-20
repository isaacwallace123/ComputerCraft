--- A general carrying its crew's heartbeats to the base.
---
--- The property everything here protects: **a relayed device must not look
--- fresher than it is.** If the base stamped every entry in a batch with the
--- moment the batch arrived, a miner that went quiet twenty minutes ago would
--- read as online for as long as its general kept talking - which is exactly
--- the failure the staleness thresholds exist to catch, reintroduced one layer
--- up and much harder to see.

local expect = require("support.expect")
local it = require("support.spec").it

local relay = require("domain.fleet.relay")

local NOW = 1700000000 * 1000
local SECOND = 1000

local function report(phase)
  return { snapshot = { phase = phase }, applied = { generation = 3, epoch = "e" } }
end

it("a general forwards what its crew told it, with how long ago", function()
  local state = relay.empty()
  expect.truthy(relay.hear(state, 4, report("mining"), NOW))
  expect.truthy(relay.hear(state, 7, report("returning"), NOW + 4 * SECOND))

  local batch = relay.batch(state, NOW + 4 * SECOND)
  expect.equal(#batch, 2)

  -- Oldest first, so the base applies them in the order they happened.
  expect.equal(batch[1].id, 4)
  expect.equal(batch[1].age, 4, "heard four seconds ago")
  expect.equal(batch[2].id, 7)
  expect.equal(batch[2].age, 0, "and this one just now")

  expect.equal(batch[1].snapshot.phase, "mining", "the snapshot travels unchanged")
  expect.equal(batch[2].applied.generation, 3, "and so does what it has applied")
end)

it("the base subtracts the age rather than stamping the batch", function()
  -- The whole correctness argument in one assertion.
  local heard = relay.heardAt(NOW, 30)
  expect.equal(heard, NOW - 30 * SECOND, "thirty seconds before the batch landed")

  expect.equal(relay.heardAt(NOW, 0), NOW, "something just heard is now")
  expect.equal(relay.heardAt(NOW, nil), NOW, "and a missing age is not a guess")

  -- A general whose clock runs fast must not be able to place a report in the
  -- future, which would make the device permanently the freshest on the roster.
  expect.equal(relay.heardAt(NOW, -50), NOW, "clamped")
end)

it("a general stops mentioning crew it has not heard from", function()
  -- Past `KEEP` the general knows nothing useful, and the base's own
  -- `OFFLINE_AFTER` is the honest judge. Repeating a stale report would hold a
  -- dead turtle alive on the roster.
  local state = relay.empty()
  relay.hear(state, 4, report("mining"), NOW)

  expect.equal(#relay.batch(state, NOW + 19 * SECOND), 1, "still worth repeating")
  expect.equal(#relay.batch(state, NOW + 21 * SECOND), 0, "and past that, silence")
  expect.truthy(relay.KEEP < 60, "sooner than the base writes a device off")
end)

it("a general hands out the goal the base gave it, and invents nothing", function()
  -- A general that made up a goal, or stamped one with its own numbering, would
  -- be a second authority - and a fleet with two of those has them disagree.
  local state = relay.empty()
  relay.remember(state, { ["4"] = { mode = "recall", generation = 9, epoch = "e" } })

  local goal = assert(relay.goalFor(state, 4), "the base handed one down")
  expect.equal(goal.mode, "recall")
  expect.equal(goal.generation, 9, "unchanged")
  expect.equal(goal.epoch, "e", "under the base's run of numbering, not its own")

  expect.equal(relay.goalFor(state, 7), nil, "and nothing for somebody it holds no goal for")
end)

it("goals are replaced, never merged", function()
  -- A goal the base has stopped sending is a goal that no longer exists.
  -- Merging would leave a general handing out an order the base has forgotten,
  -- which is the one thing a cache must never do.
  local state = relay.empty()
  relay.remember(state, { ["4"] = { mode = "deploy", generation = 1 } })
  relay.remember(state, { ["7"] = { mode = "recall", generation = 2 } })

  expect.equal(relay.goalFor(state, 4), nil, "gone, because the base stopped sending it")
  expect.truthy(relay.goalFor(state, 7))
end)

it("a general forgets crew that moved to another general", function()
  -- Two generals relaying one device would report it with different ages, and
  -- which the base believed would depend on which message landed last.
  local state = relay.empty()
  relay.hear(state, 4, report("mining"), NOW)
  relay.hear(state, 7, report("mining"), NOW)

  relay.only(state, { 7 })

  local batch = relay.batch(state, NOW)
  expect.equal(#batch, 1)
  expect.equal(batch[1].id, 7, "only the one still on this crew")
end)

it("nonsense from a crew member is not forwarded", function()
  -- A general that accepted rubbish would forward it, and the base would show a
  -- device that does not exist.
  local state = relay.empty()
  expect.falsy(relay.hear(state, "four", report("mining"), NOW))
  expect.falsy(relay.hear(state, 4, "mining", NOW))
  expect.falsy(relay.hear(nil, 4, report("mining"), NOW))
  expect.equal(#relay.batch(state, NOW), 0)
  expect.equal(#relay.batch(nil, NOW), 0)
end)
