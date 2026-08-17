--- Sector physical state lives at the base, not in one turtle's job file.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

local function newRegistry()
  scenario.new({ groundY = 64 })
  local plan = require("mine.plan")
  local registry = require("mine.registry")
  local state = registry.load()
  state.plan = plan.normalise({
    configured = true,
    centreX = 0,
    centreZ = 0,
    surfaceY = 64,
    cellSize = 16,
    maxRing = 2,
    minRing = 1,
  })
  return registry, state
end

it("registry records and reports an open shaft head", function()
  local registry, state = newRegistry()

  expect.equal(#registry.exposed(state), 0, "nothing exposed to begin with")

  expect.truthy(
    registry.surface(state, 7, 3, { state = "open", headY = 71, headOffset = 2, reason = "no cap block" }),
    "surface report accepted"
  )

  local exposed = registry.exposed(state)
  expect.equal(#exposed, 1, "one exposed sector")
  expect.equal(exposed[1].index, 3, "the right sector")
  expect.equal(exposed[1].headY, 71, "records the head height")
  expect.contains(exposed[1].reason, "cap block", "records why")

  registry.surface(state, 7, 3, { state = "sealed", headY = 71, headOffset = 2 })
  expect.equal(#registry.exposed(state), 0, "sealing clears it")
end)

it("an exposed sector is leased out ahead of fresh ground", function()
  local registry, state = newRegistry()

  -- Sector 5 is finished, but its head was left open.
  registry.report(state, 1, 5, "rare@-59", 16, 10, true)
  registry.surface(state, 1, 5, { state = "open", headY = 64, headOffset = 0 })

  local index = registry.claim(state, 2, "rare@-59", nil, 0)
  expect.equal(index, 5, "the open sector is handed out first, exhausted or not")
end)

it("a sealed exhausted sector is not handed out again", function()
  local registry, state = newRegistry()

  registry.report(state, 1, 5, "rare@-59", 16, 10, true)
  registry.surface(state, 1, 5, { state = "sealed", headY = 64, headOffset = 0 })

  local index = registry.claim(state, 2, "rare@-59", nil, 0)
  expect.truthy(index ~= 5, "finished and shut means done, got " .. tostring(index))
end)

it("a turtle is told the head another turtle already found", function()
  local registry, state = newRegistry()
  registry.surface(state, 1, 4, { state = "sealed", headY = 78, headOffset = -3 })

  local known = registry.surfaceOf(state, 4)
  expect.truthy(known, "the base remembers")
  expect.equal(known and known.headOffset, -3, "including where along the trunk")
  expect.equal(known and known.headY, 78, "and how high the ground was")

  expect.falsy(registry.surfaceOf(state, 9), "nothing invented for unvisited sectors")
end)

it("registry state written before physical tracking still loads", function()
  local registry, state = newRegistry()
  -- Exactly the shape ICOS v1.2.8 persisted: no `surface` key at all.
  state.sectors["2"] = { holder = nil, work = { ["rare@-59"] = { frontier = 4 } } }

  local rows = registry.summary(state)
  local found = false
  for _, row in ipairs(rows) do
    if row.index == 2 then
      found = true
      expect.equal(row.surface, "unknown", "an old record reads as unknown, not open")
    end
  end
  expect.truthy(found, "the old record still appears")
  expect.equal(#registry.exposed(state), 0, "and is not mistaken for a hole")
end)
