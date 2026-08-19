--- `.location`, and the three things that were broken because nothing wrote it.
---
--- `adapters/cc/locator.lua` has read `.location` since it was written and no
--- code anywhere produced that file. It was not a small gap: the GPS service is
--- *critical* and raises without a saved position, `roles.check` refuses a server
--- that does not know where it is, and a general cannot claim a chunk it cannot
--- locate. All three failed on a file that never existed.
---
--- These cases are about the contract rather than the prompts. `commands/locate.lua`
--- is an interactive script and the interesting half is what it leaves behind:
--- a record every one of those three readers can use, in a shape they agree on.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

--- Write a saved position the way `commands/locate.lua` does.
local function locate(x, y, z, facing)
  local config = require("adapters.cc.config")
  local locator = require("adapters.cc.locator")
  config.save(locator.PATH, { x = x, y = y, z = z, heading = facing })
end

it("nothing to read before it is run, and that is not an error", function()
  scenario.new({ groundY = 64 })
  local locator = require("adapters.cc.locator")

  -- Nil rather than a plausible-looking origin at 0,0,0. That is a real place in
  -- the world, and believing a machine was standing there has already cost this
  -- fleet a wasted night.
  expect.falsy(locator.new().saved(), "no position until somebody says so")
end)

it("a saved position is what the locator port reads back", function()
  scenario.new({ groundY = 64 })
  locate(138, -59, -1176, 1)

  local saved = require("adapters.cc.locator").new().saved()
  expect.equal(assert(saved, "there is a record").x, 138, "x")
  expect.equal(saved.y, -59, "y")
  expect.equal(saved.z, -1176, "z")
  expect.equal(saved.heading, 1, "and the heading GPS could never have supplied")
end)

it("a located machine may be a server; an unlocated one may not", function()
  local created = scenario.new({ groundY = 64 })
  local machine = require("adapters.cc.machine")
  local roles = require("os.kernel.roles")
  local locator = require("adapters.cc.locator")

  local ports = { locator = locator.new() }
  local before = machine.capabilities(ports)
  expect.falsy(before.located, "nothing has been declared yet")

  local ok, why = roles.check(roles.SERVER, { modem = true, located = before.located })
  expect.falsy(ok, "so it cannot host GPS")
  expect.contains(why, "where it is", "and says so")

  locate(0, 64, 0, 0)
  local after = machine.capabilities(ports)
  expect.truthy(after.located, "now it knows")
  expect.truthy(
    roles.check(roles.SERVER, { modem = true, located = after.located }),
    "and may host"
  )
  expect.truthy(created ~= nil, "the world exists")
end)

it("the GPS service serves the saved position, and refuses without one", function()
  scenario.new({ groundY = 64 })
  local gps = require("os.server.services.gps")
  local locator = require("adapters.cc.locator")

  local context = { locator = locator.new() }
  local position, why = gps.position(context)
  expect.falsy(position, "a host with no position must not answer")
  expect.contains(why, "locate", "and names the command that fixes it")

  locate(10, 70, -20, 0)
  context.locator = locator.new()

  -- What a person entered, never what `gps.locate` returned. A constellation
  -- bootstrapped off its own error drifts with every host that joins, and a host
  -- that is confidently wrong is worse than no host at all.
  local served = assert(gps.position(context), "it answers now")
  expect.equal(served.x, 10, "x")
  expect.equal(served.y, 70, "y")
  expect.equal(served.z, -20, "z")
end)

it("a fresh read is taken each time, so locating mid-session is picked up", function()
  scenario.new({ groundY = 64 })
  local port = require("adapters.cc.locator").new()

  expect.falsy(port.saved(), "nothing yet")
  locate(1, 2, 3, 0)

  -- The adapter reads the file rather than caching at construction, which is
  -- what lets somebody run `locate` on a machine that is already up without
  -- rebooting it. The read is once per route, not once per move.
  expect.equal(assert(port.saved(), "the same port sees it").x, 1, "picked up without a reboot")
end)

it("coverage can root itself once the server knows where it is", function()
  scenario.new({ groundY = 64 })
  local coverage = require("domain.fleet.coverage")
  local coverageService = require("os.server.services.coverage")
  local locator = require("adapters.cc.locator")
  local mine = require("domain.mine.registry")

  locate(40, 64, -70, 0)

  local context = {
    locator = locator.new(),
    state = { coverage = coverage.empty(), mine = mine.empty() },
  }

  -- The whole chain, end to end: a person runs one command, and the fleet gains
  -- a chunk to grow its loaded region outward from. Without `.location` this
  -- returned nil and no general was ever posted.
  local root = coverageService.root(context)
  expect.equal(root, "2,-5", "the base chunk, derived from the saved position")
end)
