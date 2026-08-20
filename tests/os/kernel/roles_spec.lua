--- What a machine may be told to be, and what it is allowed to be.
---
--- Two different questions, asked at two different moments, and conflating them
--- is how a setup menu ends up either hiding the role somebody wanted or
--- offering one the machine cannot perform.
---
---   `offered`  what to show a person standing at the machine, once
---   `check`    whether what it already claims is something it can do, at boot

local expect = require("support.expect")
local it = require("support.spec").it

local roles = require("os.kernel.roles")

local function caps(overrides)
  local out = {
    turtle = false,
    pocket = false,
    modem = true,
    wireless = true,
    monitor = true,
    screen = true,
    located = true,
    chunkLoaded = false,
  }
  for key, value in pairs(overrides or {}) do
    out[key] = value
  end
  return out
end

local function keysOf(list)
  local out = {}
  for _, entry in ipairs(list) do
    out[entry.key] = true
  end
  return out
end

---------------------------------------------------------------------------
-- What gets offered
---------------------------------------------------------------------------

it("every form factor is offered something", function()
  -- A menu with nothing in it is a machine somebody cannot set up, and there is
  -- no recovery path from that except reinstalling.
  for _, shape in ipairs({
    caps({ turtle = true }),
    caps({ pocket = true }),
    caps(),
    caps({ modem = false, wireless = false, monitor = false, located = false }),
  }) do
    expect.truthy(#roles.offered(shape) > 0, "something to choose")
  end
end)

it("a turtle is offered everything except the handheld", function()
  -- Client used to be withheld from a turtle, on the reasoning that a turtle is
  -- a thing that moves. It is a thing that moves *when it is running the turtle
  -- OS* - the role picks the operating system, and a client has no job runner,
  -- so a turtle client sits exactly as still as a computer does.
  --
  -- What that buys is a GPS host that is not a fleet authority. A constellation
  -- needs four, and offering only Server for the job would put four registries
  -- and four sets of sector leases in the world to get four beacons.
  local offered = keysOf(roles.offered(caps({ turtle = true })))
  expect.truthy(offered[roles.TURTLE], "turtle")
  expect.truthy(offered[roles.CLIENT], "and a client, which is a turtle that only hosts GPS")
  expect.truthy(offered[roles.SERVER], "and a server, chunk loading permitting")
  expect.falsy(offered[roles.MOBILE], "but never a handheld")
end)

it("a pocket computer is offered only the handheld", function()
  -- A server must stay loaded, and a machine in somebody's pocket is the
  -- definition of one that does not.
  local offered = keysOf(roles.offered(caps({ pocket = true })))
  expect.truthy(offered[roles.MOBILE], "handheld")
  expect.falsy(offered[roles.SERVER], "never a server")
  expect.falsy(offered[roles.CLIENT], "and not a client either")
end)

it("a computer is offered server and client", function()
  local offered = keysOf(roles.offered(caps()))
  expect.truthy(offered[roles.SERVER], "server")
  expect.truthy(offered[roles.CLIENT], "and client")
end)

it("a turtle may be a server, because a chunky one can host GPS", function()
  -- D022: a Chunky Turtle keeps the shared host chunk loaded, so it is a
  -- legitimate fourth host rather than a curiosity.
  expect.truthy(keysOf(roles.offered(caps({ turtle = true })))[roles.SERVER], "offered")
end)

it("a server is offered to a machine that does not know where it is", function()
  -- `check` refuses one; `offered` shows it anyway. Setup is where somebody is
  -- standing at the machine and can be told to run `where` - hiding the role
  -- until they have would leave them no way to discover it was what they
  -- wanted, and the refusal comes later with an instruction attached.
  local offered = keysOf(roles.offered(caps({ located = false })))
  expect.truthy(offered[roles.SERVER], "still offered")

  local ok, why = roles.check(roles.SERVER, caps({ located = false }))
  expect.falsy(ok, "but refused at boot")
  expect.contains(why, "where it is", "with a reason somebody can act on")
end)

---------------------------------------------------------------------------
-- What gets warned about
---------------------------------------------------------------------------

local function warningFor(key, shape)
  for _, entry in ipairs(roles.OFFERED) do
    if entry.key == key then
      return entry.warn(shape)
    end
  end
  return nil
end

it("a warning is about what is missing, not what is wrong", function()
  -- Every one of these is a role that will still work. A refusal would be
  -- wrong: a handheld with no modem is a usable handheld (D019), and a turtle
  -- with no modem still mines.
  expect.contains(
    warningFor(roles.MOBILE, caps({ pocket = true, modem = false })),
    "offline",
    "the handheld says what it loses"
  )
  expect.contains(
    warningFor(roles.TURTLE, caps({ turtle = true, modem = false })),
    "track",
    "the turtle says nothing will see it"
  )
end)

it("a healthy machine is warned about nothing", function()
  -- A screen that always has a caveat on it is a screen nobody reads.
  expect.equal(warningFor(roles.CLIENT, caps()), nil, "client")
  expect.equal(warningFor(roles.SERVER, caps()), nil, "server")
end)

it("the server warns about the thing that will actually stop it", function()
  -- Ordered by what blocks first: no modem at all beats a wired one, which
  -- beats not knowing where it is.
  expect.contains(warningFor(roles.SERVER, caps({ modem = false })), "modem", "no modem")
  expect.contains(warningFor(roles.SERVER, caps({ wireless = false })), "wired", "wired only")
  expect.contains(warningFor(roles.SERVER, caps({ located = false })), "where", "no position")
end)

---------------------------------------------------------------------------
-- What a machine already is
---------------------------------------------------------------------------

it("an ICOS 1 role maps forward without being re-chosen", function()
  -- The migration that runs on ten machines: the role is renamed and the job it
  -- was already running is left alone.
  expect.equal(roles.roleOf({ role = "miner" }), roles.TURTLE, "miner becomes turtle")
  expect.equal(roles.roleOf({ role = "fleet" }), roles.SERVER, "fleet becomes server")
  expect.equal(roles.roleOf({ role = "controller" }), roles.MOBILE, "controller becomes mobile")
  expect.equal(roles.roleOf({ role = "gps" }), roles.SERVER, "and gps disappears into server")
end)

it("a machine that has been migrated says so", function()
  local migrated = roles.plan({ role = "miner" }, caps({ turtle = true }))
  expect.equal(migrated.role, roles.TURTLE, "runs the turtle OS")
  expect.truthy(migrated.migrated, "and reports that its role was renamed")

  local settled = roles.plan({ role = "turtle" }, caps({ turtle = true }))
  expect.falsy(settled.migrated, "a machine already on the new name is not migrating")
end)

it("an unreadable role becomes the harmless one", function()
  -- A client shows a screen and is wrong harmlessly. A turtle starts driving a
  -- turtle and a server starts answering for the fleet.
  expect.equal(roles.roleOf({}), roles.CLIENT, "no role")
  expect.equal(roles.roleOf({ role = "toaster" }), roles.CLIENT, "and an unknown one")
end)

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------

it("today's roles map onto the four operating systems", function()
  -- The role is a form factor, not a job. A mining turtle and a farming turtle
  -- are the same machine running different code, so ICOS 1's `miner` maps to
  -- `turtle` and mining becomes what it always was: the job it is running.
  expect.equal(roles.roleOf({ role = "miner" }), roles.TURTLE, "a miner is a turtle")
  expect.equal(roles.roleOf({ role = "controller" }), roles.MOBILE, "controller becomes mobile")
  expect.equal(roles.roleOf({ role = "gps" }), roles.SERVER, "a gps host is already a server")
  expect.equal(roles.roleOf({ role = "utility" }), roles.CLIENT, "utility holds no authority")
end)

it("fleet becomes a server, and a client beside it when there is a screen", function()
  -- The awkward one. Â§2 splits `fleet` into a server that holds authoritative
  -- state and a client that draws it, and one machine was doing both.
  expect.equal(roles.roleOf({ role = "fleet" }), roles.SERVER, "the brain half wins")

  local plan = roles.plan({ role = "fleet" }, { screen = true, modem = true, located = true })
  expect.equal(plan.role, roles.SERVER, "primary")
  expect.truthy(plan.client, "with a client beside it")

  -- Mapping it the other way round would mean a base that lost its monitor
  -- stopped being the fleet's brain.
  local headless = roles.plan({ role = "fleet" }, { modem = true, located = true })
  expect.equal(headless.role, roles.SERVER, "still the brain")
  expect.falsy(headless.client, "with nothing to draw on")
end)

it("an ICOS 2 role reads back unchanged", function()
  local plan = roles.plan({ role = "turtle" }, { turtle = true })
  expect.falsy(plan.migrated, "a native role is not a migration")

  plan = roles.plan({ role = "controller" }, { pocket = true, modem = true })
  expect.truthy(plan.migrated, "but an ICOS 1 one is")

  -- `miner` is now one of those, which it was not before. Every turtle in the
  -- live fleet is set up as a miner, so this is the migration that runs on ten
  -- machines rather than a hypothetical one - and what it does is rename the
  -- role and leave the job alone, because mining was always the job.
  plan = roles.plan({ role = "miner" }, { turtle = true })
  expect.equal(plan.role, roles.TURTLE, "a miner becomes a turtle")
  expect.truthy(plan.migrated, "and it is a migration")
end)

it("an unreadable role becomes the harmless one", function()
  -- A client shows a screen and is wrong harmlessly. A turtle starts driving a
  -- turtle and a server starts answering for the fleet.
  expect.equal(roles.roleOf(nil), roles.CLIENT, "no node at all")
  expect.equal(roles.roleOf({}), roles.CLIENT, "no role")
  expect.equal(roles.roleOf({ role = "banana" }), roles.CLIENT, "a role from the future")
end)

it("a machine is checked against what it claims to be", function()
  -- At boot, because "this turtle has no modem" is a sentence somebody can act
  -- on and "attempt to index a nil value" at three in the morning is not.
  local ok, why = roles.check(roles.TURTLE, { turtle = false })
  expect.falsy(ok, "a computer cannot run the turtle operating system")
  expect.contains(why, "turtle", "and says so")

  ok, why = roles.check(roles.SERVER, { modem = false, located = true })
  expect.falsy(ok, "a server with no modem")
  expect.contains(why, "modem", "named")

  ok, why = roles.check(roles.SERVER, { modem = true, located = false })
  expect.falsy(ok, "a server that does not know where it is cannot host GPS")
  expect.contains(why, "where it is", "named")

  expect.truthy(
    roles.check(roles.SERVER, { modem = true, located = true }),
    "and a real one passes"
  )
end)

it("a handheld with no modem is warned, not refused", function()
  -- D019: setup offers this role without a modem and fleet traffic stays offline
  -- until one is attached. A handheld with no modem is still a usable handheld.
  local ok, note = roles.check(roles.MOBILE, { pocket = true, modem = false })
  expect.truthy(ok, "allowed")
  expect.contains(note, "modem", "with a warning")

  expect.falsy(roles.check(roles.MOBILE, { pocket = false }), "but a computer is not a handheld")
end)

it("a turtle may be a GPS host without becoming a fleet authority", function()
  -- A constellation needs four hosts, and the cheapest host is a machine that
  -- sits still and answers. Making somebody choose Server for that would put a
  -- fleet authority on four machines to get four beacons - and four authorities
  -- is four registries, four sets of sector leases, and two turtles in one
  -- shaft.
  local caps = { turtle = true, modem = true, wireless = true, located = true }
  local offered = {}
  for _, entry in ipairs(roles.offered(caps)) do
    offered[entry.key] = true
  end

  expect.truthy(offered[roles.CLIENT], "a turtle may be a client")
  expect.truthy(offered[roles.TURTLE], "and still a turtle")
  expect.truthy(offered[roles.SERVER], "and still a server")
  expect.falsy(offered[roles.MOBILE], "but never a handheld")
end)

it("a turtle server is still held to what a server needs", function()
  -- The check returned early for a turtle, before looking at the modem or the
  -- position - so a turtle server with neither passed the one function whose
  -- whole job is to catch that.
  local blind = roles.check(roles.SERVER, { turtle = true })
  expect.falsy(blind, "no modem is still no modem")

  local lost = roles.check(roles.SERVER, { turtle = true, modem = true })
  expect.falsy(lost, "and a host that does not know where it is cannot host")

  local ok, why = roles.check(roles.SERVER, {
    turtle = true,
    modem = true,
    located = true,
  })
  expect.truthy(ok, "with both, it is allowed")
  expect.contains(why, "chunk-loaded", "and warned about the thing that is left")
end)
