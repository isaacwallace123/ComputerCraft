--- Drop-offs: the list, and the choice that commits fuel.
---
--- Phase 4 of docs/icos-2.md. The list is ordinary bookkeeping; the selection is
--- where D009 lives, and every rule §7 states is checked here rather than
--- discovered by a turtle that ran out one block short of a chest it could see.

local expect = require("support.expect")
local it = require("support.spec").it

local list = require("domain.depot.list")
local select = require("domain.depot.select")

local SECOND = 1000
local HOME = { x = 0, y = 64, z = 0 }

local function withDepots(...)
  local state = list.empty()
  for _, depot in ipairs({ ... }) do
    list.add(state, depot)
  end
  return state
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

it("a depot is stored with absolute coordinates and sensible defaults", function()
  local state = list.empty()
  local depot = list.add(state, { label = "North depot", position = { x = 42, y = 84, z = -1084 } })

  expect.equal(depot.id, "north-depot-1", "an id derived from the label")
  expect.truthy(depot.enabled, "enabled by default")
  expect.equal(depot.accepts[1], list.ANY, "and accepting everything")
  expect.equal(depot.position.x, 42, "at the position given")
end)

it("a depot without a usable position is refused", function()
  local state = list.empty()
  local ok = pcall(function()
    list.add(state, { label = "nowhere" })
  end)
  expect.falsy(ok, "no position at all")

  ok = pcall(function()
    list.add(state, { label = "partial", position = { x = 1, y = 2 } })
  end)
  expect.falsy(ok, "and a partial one, because 0,0,0 is a real place")
end)

it("depots keep their order, and can be moved within it", function()
  -- §7: ordering is the tie-break when two are equally close. A matched pair
  -- either side of a base is the ordinary case, and iteration order would pick
  -- differently every trip for no reason anybody could see.
  local state = withDepots(
    { label = "a", position = HOME },
    { label = "b", position = HOME },
    { label = "c", position = HOME }
  )

  expect.truthy(list.move(state, "c-3", -1), "moved up")
  expect.equal(state.depots[2].id, "c-3", "into second place")

  expect.falsy(list.move(state, "a-1", -1), "the first cannot go higher")
  expect.equal(state.depots[1].id, "a-1", "and stays put rather than wrapping to the bottom")
end)

it("accepts matches on plain substrings, not Lua patterns", function()
  -- A person typing `raw_` into a text field should not have to know that `-`
  -- means something. The conventions are the ones `turtle/ore.lua` already uses.
  local ores = { accepts = { "_ore", "raw_" }, position = HOME }
  local state = withDepots(ores)
  local depot = state.depots[1]

  expect.truthy(list.accepts(depot, "minecraft:deepslate_diamond_ore"), "modded and vanilla ores")
  expect.truthy(list.accepts(depot, "minecraft:raw_iron"), "and raw drops")
  expect.falsy(list.accepts(depot, "minecraft:cobblestone"), "but not junk")
  expect.truthy(list.accepts(depot, nil), "an unknown cargo goes anywhere")
end)

it("a full report expires so a depot emptied by hand comes back", function()
  -- Nothing ever reports a depot empty again: a person walks over, takes the
  -- diamonds, and tells nobody. A flag with no expiry removes a depot from
  -- service permanently on the strength of one bad trip.
  local state = withDepots({ label = "north", position = HOME })
  list.reportFull(state, "north-1", 1000 * SECOND)
  local depot = state.depots[1]

  expect.truthy(list.isFull(depot, 1060 * SECOND), "believed a minute later")
  expect.falsy(list.isFull(depot, 3000 * SECOND), "and not half an hour later")

  list.reportFull(state, "north-1", 4000 * SECOND, false)
  expect.falsy(list.isFull(depot, 4000 * SECOND), "or once a turtle says otherwise")
end)

---------------------------------------------------------------------------
-- Choosing, and the fuel it commits
---------------------------------------------------------------------------

it("an empty list means unload below home, exactly as today", function()
  -- D008 is not repealed by this. A fleet that never opens the Drop-offs screen
  -- keeps behaving precisely as it does now, and that is what makes phase 4
  -- safe to ship.
  local state = list.empty()
  expect.equal(select.choose(state, { from = HOME, home = HOME }), nil, "no depot chosen")

  local plan = select.plan(state, { from = { x = 100, y = 64, z = 0 }, home = HOME })
  expect.equal(plan.depot, nil, "the plan says home")
  expect.equal(plan.position, HOME, "at the home block")
  expect.equal(plan.cost, 100, "costed as the trip home")
  expect.contains(plan.reason, "no drop-offs", "and says why")
end)

it("a disabled, full or unaccepting depot is not chosen", function()
  local state = withDepots(
    { label = "off", position = { x = 1, y = 64, z = 0 }, enabled = false },
    { label = "full", position = { x = 2, y = 64, z = 0 } },
    { label = "ores", position = { x = 3, y = 64, z = 0 }, accepts = { "_ore" } }
  )
  list.reportFull(state, "full-2", 0)

  local chosen = select.choose(state, {
    from = HOME,
    home = HOME,
    item = "minecraft:cobblestone",
    now = 0,
  })
  expect.equal(chosen, nil, "none of the three qualify")

  chosen =
    assert(select.choose(state, { from = HOME, home = HOME, item = "minecraft:iron_ore", now = 0 }))
  expect.equal(chosen.id, "ores-3", "but the ore depot takes ore")
end)

it("the nearest usable depot wins, and list order breaks a tie", function()
  local state = withDepots(
    { label = "far", position = { x = 200, y = 64, z = 0 } },
    { label = "first equal", position = { x = 50, y = 64, z = 0 } },
    { label = "second equal", position = { x = 0, y = 64, z = 50 } }
  )

  local chosen = assert(select.choose(state, { from = HOME, home = HOME, now = 0 }))
  expect.equal(chosen.id, "first-equal-2", "the earlier of the two equally close")
end)

---------------------------------------------------------------------------
-- D009, which is the whole risk of this phase
---------------------------------------------------------------------------

it("the cost of a depot includes getting home again", function()
  -- A turtle is not safe when it reaches a chest. It is safe when it can still
  -- get home afterwards, and the two differ by an entire return leg.
  local depot = { position = { x = 100, y = 64, z = 0 } }
  local from = { x = 0, y = 64, z = 0 }

  expect.equal(select.distance(from, depot.position), 100, "the outward leg alone")
  expect.equal(select.cost(from, depot, HOME), 200, "and the round trip is what is costed")
end)

it("distance is Manhattan, because a turtle cannot fly diagonally", function()
  -- `nav.goTo` only moves on cardinals, so a diagonal is walked as a staircase.
  -- Euclidean would under-estimate every route, and the error would land in the
  -- one number that must never be optimistic.
  expect.equal(select.distance({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }), 7, "not 5")
end)

it("a depot beyond the fuel budget is disqualified, not merely expensive", function()
  -- A turtle that picked the nearest depot it could not reach would strand
  -- itself while believing it had made the safe choice.
  local state = withDepots(
    { label = "close but blocked", position = { x = 60, y = 64, z = 0 } },
    { label = "reachable", position = { x = 20, y = 64, z = 0 } }
  )

  local chosen, cost = select.choose(state, { from = HOME, home = HOME, fuel = 50, now = 0 })
  expect.equal(assert(chosen).id, "reachable-2", "the one it can actually complete")
  expect.equal(cost, 40, "with the round trip costed")

  expect.equal(
    select.choose(state, { from = HOME, home = HOME, fuel = 10, now = 0 }),
    nil,
    "and nothing at all when none are affordable"
  )
end)

it("a plan hands back the depot and the fuel it commits, in one call", function()
  -- One call rather than two so the two cannot disagree. A caller that asked for
  -- the depot and then computed the reserve itself would eventually compute it
  -- from a different position, and the failure is a turtle that runs out one
  -- block short of a chest it can see.
  local state = withDepots({ label = "north", position = { x = 40, y = 64, z = 0 } })
  local plan = select.plan(state, { from = { x = 100, y = 64, z = 0 }, home = HOME, now = 0 })

  expect.equal(assert(plan.depot).id, "north-1", "the depot")
  expect.equal(assert(plan.position).x, 40, "where to go")
  expect.equal(plan.cost, 100, "60 out to it, then 40 home")
end)

it("an unusable list falls back to home rather than to nothing", function()
  local state = withDepots({ label = "off", position = HOME, enabled = false })
  local plan = select.plan(state, { from = { x = 30, y = 64, z = 0 }, home = HOME, now = 0 })

  expect.equal(plan.depot, nil, "no depot")
  expect.equal(plan.cost, 30, "costed as the trip home")
  expect.contains(plan.reason, "none usable", "and distinguishes that from an empty list")
end)
