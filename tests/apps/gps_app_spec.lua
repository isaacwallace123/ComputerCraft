--- Seeing the constellation, which no single machine can.

local expect = require("support.expect")
local fleet = require("support.fleet")
local it = require("support.spec").it

local app = require("apps.gps.app")
local discovery = require("os.server.services.discovery")
local host = require("domain.gps.host")

--- A fleet where `count` machines are located, parked computers.
local function located(count)
  local ctx = fleet.server()
  for id = 1, count do
    discovery.handle(ctx, id, {
      kind = "status",
      snapshot = {
        label = "machine-" .. id,
        located = true,
        parked = true,
        world = { x = id, y = 64, z = 0 },
      },
    })
  end
  return ctx
end

it("three hosts is exactly as useless as zero, and the page says which", function()
  -- Trilateration needs four. Three is not "nearly working", and the difference
  -- is invisible from any individual machine - which is the whole reason this
  -- page exists.
  local ctx = located(3)
  local rows = app.rows(ctx.state, ctx.clock.now())

  expect.equal(app.quorum(rows), 3, "three hosting")
  local text = app.summary(rows)
  expect.contains(text, "locate 1 more", "and it says what to do about it")
end)

it("four is the number, and it says so differently", function()
  local ctx = located(host.QUORUM)
  local text = app.summary(app.rows(ctx.state, ctx.clock.now()))
  expect.contains(text, "works", "the constellation works")
end)

it("located and hosting are different questions", function()
  -- A machine can know where it is and still tell nobody. "Located but silent"
  -- is the state somebody needs to see to understand why four machines with
  -- positions are still not a constellation.
  local moving = app.hosting({ located = true, parked = false })
  expect.falsy(moving, "a turtle under way does not host")

  local handheld = app.hosting({ located = true, parked = true, role = "controller" })
  expect.falsy(handheld, "and a handheld never does")

  local lost = app.hosting({ located = false, parked = true })
  expect.falsy(lost, "nor one that does not know where it is")

  expect.truthy(app.hosting({ located = true, parked = true }), "a parked, located machine does")
end)

it("a machine that is not hosting says why, not just no", function()
  local _, why = app.hosting({ located = false })
  expect.equal(why, "no position", "the reason is the actionable half")

  local _, moving = app.hosting({ located = true, parked = false })
  expect.equal(moving, "moving", "and so is this one")
end)

it("hosts are listed first, so the count is readable without counting", function()
  local ctx = located(2)
  discovery.handle(ctx, 9, {
    kind = "status",
    snapshot = { label = "aaa-unlocated", located = false, parked = true },
  })

  local rows = app.rows(ctx.state, ctx.clock.now())
  expect.truthy(rows[1].serving, "a host first")
  expect.falsy(rows[#rows].serving, "and the one that is not, last")
end)

it("an empty fleet is not an error", function()
  local ctx = fleet.server()
  local rows = app.rows(ctx.state, ctx.clock.now())
  expect.equal(#rows, 0, "nothing to show")
  expect.contains(app.summary(rows), "0 of 4", "and it says so plainly")
end)
