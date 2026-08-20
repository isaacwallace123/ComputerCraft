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

it("a client appears on the page whose whole subject is what clients do", function()
  -- Clients asked the server for the fleet three times a minute and never
  -- appeared in it, so five located GPS hosts standing round a base read as
  -- "1 of 4 hosts". The page was right about what it could see; nothing had
  -- ever told it they were there.
  local ctx = fleet.server()
  discovery.handle(ctx, 9, {
    kind = "mirror",
    snapshot = {
      label = "gps-9",
      role = "client",
      kind = "computer",
      located = true,
      world = { x = 10, y = 64, z = -3 },
      orders = false,
    },
  })

  local rows = app.rows(ctx.state, ctx.clock.now())
  expect.equal(#rows, 1, "the client is on the roster")
  expect.equal(rows[1].label, "gps-9")
  expect.truthy(rows[1].serving, "and it is hosting, which is the whole question")
end)

it("a machine that cannot carry out an order is never given one", function()
  -- Everything that talks to the server is in the registry and most of it is not
  -- a turtle. A client handed "recall" would report it as pending forever,
  -- because there is nothing on a client that could carry one out - which reads
  -- on the Fleet page as a machine ignoring the base.
  local ctx = fleet.server()
  discovery.handle(ctx, 9, {
    kind = "mirror",
    snapshot = { label = "gps-9", role = "client", located = true, orders = false },
  })
  discovery.handle(ctx, 7, fleet.heartbeat())

  discovery.handle(ctx, 1, { kind = "want", mode = "recall" })

  local registry = require("domain.fleet.registry")
  expect.equal(registry.get(ctx.state.fleet, 7).desired.mode, "recall", "the turtle was told")
  expect.equal(registry.get(ctx.state.fleet, 9).desired, nil, "and the client was not")
end)

it("a device that has never heard of the field still gets orders", function()
  -- Absent means yes, which is the safe direction: every turtle in the world
  -- predates this field, and a missing one must not mean a turtle that silently
  -- never gets told anything again.
  local ctx = fleet.server()
  discovery.handle(ctx, 7, fleet.heartbeat())
  discovery.handle(ctx, 1, { kind = "want", mode = "deploy" })

  local registry = require("domain.fleet.registry")
  expect.equal(registry.get(ctx.state.fleet, 7).desired.mode, "deploy")
end)
