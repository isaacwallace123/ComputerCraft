--- Chunk coverage: the geometry, the invariant, and the spread.
---
--- Every case here runs with no world, no clock and no turtles, which is the
--- point. "Two chunk loaders never end up in one chunk" is a property, and a
--- property is worth more as a test than as a paragraph - especially this one,
--- whose failure mode in game is a wasted turtle standing in ground somebody
--- else is already holding, doing nothing visibly wrong.

local coverage = require("domain.fleet.coverage")
local expect = require("support.expect")
local grid = require("domain.chunk.grid")
local it = require("support.spec").it

--- A fixed clock. Coverage takes `now` everywhere for the reason
--- `domain/mine/registry.lua` does, so a spec supplies one and time only moves
--- when the test says so.
local T0 = 1700000000000

local function seconds(n)
  return T0 + n * 1000
end

--- A state with the base at world 0,0 and `count` generals posted outward.
local function region(count)
  local state = coverage.empty()
  coverage.setRoot(state, 0, 0)
  for index = 1, count do
    local post = assert(coverage.postFor(state, T0), "ran out of frontier")
    coverage.claim(state, 100 + index, post.cx, post.cz, T0)
  end
  return state
end

---------------------------------------------------------------------------
-- The grid
---------------------------------------------------------------------------

it("a world position lands in the chunk a player would name", function()
  local cx, cz = grid.of(0, 0)
  expect.equal(cx, 0, "origin x")
  expect.equal(cz, 0, "origin z")

  -- The half of the world that integer truncation gets wrong. Block -1 is in
  -- chunk -1; truncating towards zero would put it in chunk 0 and quietly
  -- overlap two footprints across the axis.
  cx, cz = grid.of(-1, -16)
  expect.equal(cx, -1, "block -1 is in chunk -1")
  expect.equal(cz, -1, "block -16 is the first block of chunk -1")

  cx = grid.of(16, 0)
  expect.equal(cx, 1, "block 16 starts chunk 1")
end)

it("a chunk's bounds are exactly what the quarry job wants", function()
  local minX, maxX, minZ, maxZ = grid.bounds(2, -3)
  expect.equal(minX, 32, "minimum x")
  expect.equal(maxX, 47, "maximum x")
  expect.equal(minZ, -48, "minimum z")
  expect.equal(maxZ, -33, "maximum z")

  -- Sixteen wide and sixteen long, which is the area `quarry.lua` already
  -- defaults to. That is why a chunk quarry needed no new job.
  expect.equal(maxX - minX + 1, grid.SIZE, "one chunk wide")
  expect.equal(maxZ - minZ + 1, grid.SIZE, "one chunk long")
end)

it("a post stands in the middle of its chunk, never on an edge", function()
  local x, z = grid.post(0, 0)
  local minX, maxX, minZ, maxZ = grid.bounds(0, 0)
  expect.truthy(x > minX and x < maxX, "x is off both edges")
  expect.truthy(z > minZ and z < maxZ, "z is off both edges")

  -- And it is in the chunk it claims to be in, which is the only thing the
  -- whole system's correctness actually rests on.
  local cx, cz = grid.of(x, z)
  expect.equal(cx, 0, "the post is in its own chunk")
  expect.equal(cz, 0, "the post is in its own chunk")
end)

it("footprint and spacing agree, at this radius and at others", function()
  expect.equal(#grid.footprint(0, 0, 0), 1, "a chunky turtle holds one chunk")
  expect.equal(grid.spacing(0), 1, "so generals tile one chunk apart")

  -- The case that motivated expressing this as a radius at all: under a
  -- radius-1 loader, "exactly one chunk apart" overlaps on six of nine.
  expect.equal(#grid.footprint(0, 0, 1), 9, "a radius-1 loader holds nine")
  expect.equal(grid.spacing(1), 3, "and has to tile three apart")
  expect.truthy(grid.overlaps(0, 0, 1, 0, 1), "one apart overlaps at radius 1")
  expect.falsy(grid.overlaps(0, 0, 3, 0, 1), "three apart does not")
end)

it("diagonal chunks are not connected", function()
  local held = { ["0,0"] = true, ["1,1"] = true }
  local reachable = grid.reachable(held, "0,0")

  -- A turtle flying between two diagonally adjacent loaded chunks passes
  -- through one of the two unloaded chunks between them. Treating a corner as a
  -- join would produce a region that looks whole and strands turtles in it.
  expect.truthy(reachable["0,0"], "the root is reachable")
  expect.falsy(reachable["1,1"], "a corner touch is not a connection")
end)

---------------------------------------------------------------------------
-- The invariant
---------------------------------------------------------------------------

it("two generals never hold the same chunk", function()
  local state = coverage.empty()
  coverage.setRoot(state, 0, 0)

  local first = coverage.claim(state, 7, 0, 0, T0)
  expect.truthy(first, "the first general gets the chunk")

  local second, why = coverage.claim(state, 8, 0, 0, T0)
  expect.falsy(second, "the second is refused")
  expect.contains(why, "held by general 7", "and told who has it")
end)

it("a refusal says where the chunk is and who holds it", function()
  local state = coverage.empty()
  coverage.setRoot(state, 0, 0)
  coverage.claim(state, 7, 3, -2, T0)

  local _, why = coverage.claim(state, 8, 3, -2, T0)
  expect.contains(why, "3,-2", "the refusal names the chunk")
end)

it("a general holds one chunk, releasing whatever it held before", function()
  local state = coverage.empty()
  coverage.setRoot(state, 0, 0)
  coverage.claim(state, 7, 0, 0, T0)
  coverage.claim(state, 7, 1, 0, T0)

  expect.falsy(state.posts["0,0"], "the old post is given up")
  expect.truthy(state.posts["1,0"], "and the new one is held")
end)

it("a stale claim is not handed to somebody else", function()
  local state = coverage.empty()
  coverage.setRoot(state, 0, 0)
  coverage.claim(state, 7, 0, 0, T0)

  local late = seconds(coverage.STALE_SECONDS + 60)

  -- It stops counting as coverage, because nothing should be sent to work under
  -- a general that may not be there...
  expect.falsy(coverage.covered(state, late)["0,0"], "a stale post is not coverage")

  -- ...but the chunk is still claimed. Freeing it automatically is how two
  -- loaders end up in one chunk, which is the one outcome this file exists to
  -- prevent.
  expect.truthy(state.posts["0,0"], "the claim is kept")
  local frontier = grid.frontier(coverage.held(state, late), "0,0")
  expect.equal(#frontier, 0, "and it is not offered as somewhere to go")
end)

it("a general reporting from a stale chunk takes it over", function()
  local state = coverage.empty()
  coverage.setRoot(state, 0, 0)
  coverage.claim(state, 7, 0, 0, T0)

  local late = seconds(coverage.STALE_SECONDS + 60)
  local post = coverage.claim(state, 9, 0, 0, late)

  -- Presence beats a record nobody has refreshed. A turtle physically standing
  -- in the chunk is the strongest evidence available about who holds it.
  expect.truthy(post, "the replacement is allowed in")
  expect.equal(state.posts["0,0"].general, 9, "and the claim transfers")
end)

it("an operator can free a chunk whose general was destroyed", function()
  local state = region(2)
  local key = "0,0"
  expect.truthy(coverage.vacate(state, key), "the post is released")
  expect.falsy(state.posts[key], "and the chunk is free")
end)

---------------------------------------------------------------------------
-- Growing the region
---------------------------------------------------------------------------

it("coverage starts at the base and grows outward, staying joined", function()
  local state = region(6)
  local covered = coverage.covered(state, T0)

  local count = 0
  for _ in pairs(covered) do
    count = count + 1
  end
  expect.equal(count, 6, "every general is part of one region")

  -- Reachability is computed from the root, so this passing *is* the statement
  -- that the region is connected: an island would simply not be counted.
  expect.truthy(covered["0,0"], "the base chunk is covered first")
end)

it("the first post is the base chunk, not wherever anybody asked from", function()
  local state = coverage.empty()
  coverage.setRoot(state, 40, -70)

  local post = assert(coverage.postFor(state, T0), "a rooted region has somewhere to start")
  local cx, cz = grid.of(40, -70)
  expect.equal(post.cx, cx, "x")
  expect.equal(post.cz, cz, "z")
end)

it("a fleet with no base is told so rather than guessing", function()
  local state = coverage.empty()
  local post, why = coverage.postFor(state, T0)
  expect.falsy(post, "there is nowhere to start")
  expect.contains(why, "no chunk yet", "and it says why")
end)

it("an island of coverage is held but never worked", function()
  local state = coverage.empty()
  coverage.setRoot(state, 0, 0)
  coverage.claim(state, 7, 0, 0, T0)
  -- Placed by hand, four chunks away, joined to nothing.
  coverage.claim(state, 8, 4, 4, T0)

  expect.truthy(coverage.held(state, T0)["4,4"], "the chunk is held")
  expect.falsy(coverage.covered(state, T0)["4,4"], "but it is not reachable")

  local rows = coverage.summary(state, T0)
  local island = nil
  for _, row in ipairs(rows) do
    if row.key == "4,4" then
      island = row
    end
  end
  expect.truthy(
    assert(island, "the held chunk appears in the summary").island,
    "and it is reported as an island rather than as coverage"
  )
end)

---------------------------------------------------------------------------
-- Spreading the miners
---------------------------------------------------------------------------

it("miners fill a chunk before opening the next one", function()
  local state = region(3)

  for index = 1, coverage.PER_CHUNK do
    local assignment = assert(coverage.assign(state, index, T0), "there is ground to work")
    expect.equal(assignment.chunk, "0,0", "miner " .. index .. " works the nearest chunk")
    expect.equal(assignment.slot, index, "and takes the next free slice")
  end

  -- Only once the first is full does the second open. Compact beats spread out:
  -- every chunk near base is both a work site and part of the way home.
  local fourth = assert(coverage.assign(state, 4, T0), "three chunks, so there is room")
  expect.truthy(fourth.chunk ~= "0,0", "the fourth miner moves outward")
end)

it("an assignment does not drift when nothing has happened", function()
  local state = region(3)
  local first = assert(coverage.assign(state, 1, T0), "assigned once")

  local repeated, changed = coverage.assign(state, 1, seconds(30))
  local again = assert(repeated, "still assigned")
  expect.equal(again.chunk, first.chunk, "same chunk")
  expect.equal(again.slot, first.slot, "same slice")
  expect.falsy(changed, "and nothing is reported as new")
end)

it("a miner that leaves frees its slice without re-cutting the chunk", function()
  local state = region(2)
  for index = 1, coverage.PER_CHUNK do
    coverage.assign(state, index, T0)
  end

  local vacated = assert(state.miners["2"], "the second miner was assigned").slot
  coverage.forget(state, 2)

  local replacement = assert(coverage.assign(state, 99, T0), "the freed slice is available")
  expect.equal(replacement.chunk, "0,0", "the replacement works the same chunk")
  expect.equal(replacement.slot, vacated, "and takes exactly the slice that was dropped")

  -- The divisor never moves, so the turtles that stayed are working the same
  -- cells they were before. A `workerCount` derived from the live headcount
  -- would have re-cut the area under all of them.
  local settings = assert(coverage.quarry(state.miners["1"], {}), "a slice has settings")
  expect.equal(settings.workerCount, coverage.PER_CHUNK, "the split is fixed")
end)

it("a worked-out chunk stops taking miners but stays part of the region", function()
  local state = region(3)
  coverage.assign(state, 1, T0)
  coverage.exhaust(state, "0,0")

  expect.falsy(state.miners["1"], "its miners are released")

  local next_ = assert(coverage.assign(state, 1, T0), "two more chunks are covered")
  expect.truthy(next_.chunk ~= "0,0", "and nobody new is sent there")

  -- Still held, still coverage. An exhausted chunk in the middle of the region
  -- is the route home for everything beyond it, and dropping it would punch a
  -- hole in the connected set.
  expect.truthy(coverage.covered(state, T0)["0,0"], "the base chunk still counts")
end)

it("no miner is assigned before any chunk is covered", function()
  local state = coverage.empty()
  coverage.setRoot(state, 0, 0)

  -- The rule that keeps a turtle out of ground nobody is loading. Desired state
  -- would deliver the order perfectly; the turtle would then freeze mid-flight.
  expect.falsy(coverage.assign(state, 1, T0), "nowhere to send it yet")
end)

it("the quarry settings are the chunk, split by slot", function()
  local state = region(1)
  local assignment = assert(coverage.assign(state, 1, T0), "one covered chunk is enough")
  local settings = assert(coverage.quarry(assignment, { topY = 70, bottomY = -59 }))

  local minX, maxX, minZ, maxZ = grid.bounds(0, 0)
  expect.equal(settings.minX, minX, "minimum x")
  expect.equal(settings.maxX, maxX, "maximum x")
  expect.equal(settings.minZ, minZ, "minimum z")
  expect.equal(settings.maxZ, maxZ, "maximum z")
  expect.equal(settings.topY, 70, "top")
  expect.equal(settings.bottomY, -59, "bottom")
  expect.equal(settings.workerIndex, 1, "this turtle's slice")
  expect.equal(settings.workerCount, coverage.PER_CHUNK, "out of a fixed divisor")
end)

it("every slice of a chunk is worked, and no cell twice", function()
  local state = region(1)

  -- The quarry job splits `areaCells` by `workerIndex` of `workerCount`. If the
  -- slices did not tile the chunk exactly, the fleet would either leave a strip
  -- standing or send two turtles to the same block.
  local cells = grid.SIZE * grid.SIZE
  local seen = 0
  for slot = 1, coverage.PER_CHUNK do
    local first = math.floor(cells * (slot - 1) / coverage.PER_CHUNK)
    local after = math.floor(cells * slot / coverage.PER_CHUNK)
    seen = seen + (after - first)
  end
  expect.equal(seen, cells, "the slices tile the chunk exactly")
  expect.truthy(coverage.assign(state, 1, T0), "and there is somewhere to work")
end)

---------------------------------------------------------------------------
-- The service, driven end to end with no world
---------------------------------------------------------------------------

--- A server context with a fleet, a mine, and no radio.
---
--- The same shape `os/server/main.lua` builds, minus everything the coverage
--- service does not touch. `persist` writes through the storage port, so a
--- recording one is enough to let a claim flush without a filesystem.
local function server()
  local registry = require("domain.fleet.registry")
  local mine = require("domain.mine.registry")

  local written = {}
  return {
    clock = {
      now = function()
        return T0
      end,
      sleep = function() end,
    },
    storage = {
      read = function()
        return nil
      end,
      write = function(path, text)
        written[path] = text
        return true
      end,
    },
    serialise = {
      encode = function()
        return ""
      end,
      decode = function()
        return {}
      end,
    },
    locator = {
      saved = function()
        return { x = 0, y = 64, z = 0 }
      end,
      gps = function() end,
    },
    paths = { fleet = ".fleet2", coverage = ".coverage" },
    state = {
      fleet = registry.empty(),
      mine = mine.empty(),
      coverage = coverage.empty(),
    },
    written = written,
  }
end

--- Put a device in the registry with the snapshot it would have sent.
local function reports(context, id, snap)
  local registry = require("domain.fleet.registry")
  return registry.observe(context.state.fleet, id, snap, T0)
end

local function turtle(extra)
  local snap = {
    role = "miner",
    label = "turtle-" .. tostring(extra and extra.id or 1),
    parked = true,
    phase = "parked",
  }
  for key, value in pairs(extra or {}) do
    snap[key] = value
  end
  return snap
end

it("a parked turtle with a chunk loader is made a general", function()
  local coverageService = require("os.server.services.coverage")
  local context = server()
  reports(context, 5, turtle({ chunky = true }))

  local wants = coverageService.plan(context, T0)
  expect.equal(#wants, 1, "one order")
  local order = assert(wants[1], "an order was planned")
  expect.equal(order.job, "general", "and it is the chunk loader job")

  -- The first post is the base's own chunk, and the settings are a place in the
  -- world rather than an offset - a general is told where to stand, not how far
  -- to walk.
  local cx, cz = grid.of(order.settings.postX, order.settings.postZ)
  expect.equal(cx, 0, "posted to the base chunk")
  expect.equal(cz, 0, "posted to the base chunk")
end)

it("a turtle with no chunk loader is never made a general", function()
  local coverageService = require("os.server.services.coverage")
  local context = server()
  reports(context, 5, turtle({ chunky = false }))

  for _, want in ipairs(coverageService.plan(context, T0)) do
    expect.truthy(want.job ~= "general", "it is not offered a chunk to hold")
  end
end)

it("two candidates in one pass are never sent to the same chunk", function()
  local coverageService = require("os.server.services.coverage")
  local context = server()
  reports(context, 5, turtle({ chunky = true }))
  reports(context, 6, turtle({ chunky = true }))

  local posts = {}
  for _, want in ipairs(coverageService.plan(context, T0)) do
    if want.job == "general" then
      local key = grid.key(grid.of(want.settings.postX, want.settings.postZ))
      expect.falsy(posts[key], "two generals were sent to " .. key)
      posts[key] = true
    end
  end

  -- The bug this guards is the base breaking its own invariant: without
  -- claiming a chunk at the moment it is *offered*, every candidate in a pass
  -- reads the same frontier and is sent to the same place.
  local count = 0
  for _ in pairs(posts) do
    count = count + 1
  end
  expect.equal(count, 2, "both were posted, to different chunks")
end)

it("a general standing somewhere claims the chunk it is actually in", function()
  local coverageService = require("os.server.services.coverage")
  local context = server()
  reports(
    context,
    5,
    turtle({ chunky = true, job = "general", parked = false, world = { x = 40, y = 64, z = -20 } })
  )

  coverageService.plan(context, T0)

  -- Derived from the position in the heartbeat, not from anything the general
  -- claimed. An observation, not an assertion.
  local cx, cz = grid.of(40, -20)
  local post =
    assert(context.state.coverage.posts[grid.key(cx, cz)], "the chunk it is standing in is claimed")
  expect.equal(post.general, 5, "by the turtle standing there")
end)

it("miners are only assigned to chunks a general is holding", function()
  local coverageService = require("os.server.services.coverage")
  local context = server()
  reports(context, 9, turtle({ id = 9 }))

  -- No general anywhere, so no covered ground, so nowhere safe to send it. The
  -- order would arrive perfectly and the turtle would freeze mid-flight.
  expect.equal(#coverageService.plan(context, T0), 0, "nothing is assigned")

  reports(
    context,
    5,
    turtle({ chunky = true, job = "general", parked = false, world = { x = 8, y = 64, z = 8 } })
  )

  local wants = coverageService.plan(context, T0)
  expect.equal(#wants, 1, "now there is somewhere to work")
  local order = assert(wants[1], "an order was planned")
  expect.equal(order.job, "quarry", "and it is a chunk quarry")
  expect.equal(order.settings.minX, 0, "over the chunk the general is holding")
  expect.equal(order.settings.maxX, 15, "over the chunk the general is holding")
  expect.equal(order.settings.workerCount, coverage.PER_CHUNK, "split into fixed slices")
end)

it("three miners share a chunk and a fourth waits for more ground", function()
  local coverageService = require("os.server.services.coverage")
  local context = server()
  reports(
    context,
    5,
    turtle({ chunky = true, job = "general", parked = false, world = { x = 8, y = 64, z = 8 } })
  )
  for id = 10, 13 do
    reports(context, id, turtle({ id = id }))
  end

  local slices = {}
  for _, want in ipairs(coverageService.plan(context, T0)) do
    if want.job == "quarry" then
      slices[want.settings.workerIndex] = true
    end
  end

  local taken = 0
  for _ in pairs(slices) do
    taken = taken + 1
  end

  -- One general, three miners. The fourth is not refused or errored, it simply
  -- has nowhere to go until the region grows - which is the ratio falling out of
  -- the geometry rather than being enforced as a rule.
  expect.equal(taken, coverage.PER_CHUNK, "the chunk takes exactly its slices")
end)

it("running the same pass twice changes nothing", function()
  local coverageService = require("os.server.services.coverage")
  local context = server()
  reports(
    context,
    5,
    turtle({ chunky = true, job = "general", parked = false, world = { x = 8, y = 64, z = 8 } })
  )
  reports(context, 9, turtle({ id = 9 }))

  coverageService.pass(context, T0)
  local acted = coverageService.pass(context, T0)

  -- The property the whole design is built around. `desired.want` bumps a
  -- generation whenever a goal differs, so a pass that re-decided would re-task
  -- the fleet every six seconds and no chunk would ever be finished.
  expect.equal(#acted, 0, "the second pass sets nothing new")
end)

it("a device carrying somebody else's order is left alone", function()
  local coverageService = require("os.server.services.coverage")
  local desired = require("domain.fleet.desired")
  local context = server()
  reports(
    context,
    5,
    turtle({ chunky = true, job = "general", parked = false, world = { x = 8, y = 64, z = 8 } })
  )
  local record = reports(context, 9, turtle({ id = 9 }))

  -- An operator recalled it. Coverage may not overrule that, for the same reason
  -- `policy.mayAct` may not: a base that re-tasked a machine somebody had just
  -- configured is a base nobody leaves running.
  desired.want(record, "recall", {}, T0)

  for _, want in ipairs(coverageService.plan(context, T0)) do
    expect.truthy(want.id ~= 9, "the recalled turtle is not re-tasked")
  end
end)

it("a server with no base chunk assigns nothing at all", function()
  local coverageService = require("os.server.services.coverage")
  local context = server()
  context.locator = {
    saved = function()
      return nil
    end,
    gps = function() end,
  }
  reports(context, 5, turtle({ chunky = true }))

  -- No position and no mine. Guessing would anchor the whole worksite to
  -- whichever turtle happened to report first.
  expect.equal(#coverageService.plan(context, T0), 0, "nothing is dispatched")
end)

---------------------------------------------------------------------------
-- Surviving a round trip
---------------------------------------------------------------------------

it("a state read off disk is safe to use", function()
  local repaired = coverage.normalise({ posts = "not a table", root = 12 })
  expect.truthy(type(repaired.posts) == "table", "posts is usable")
  expect.truthy(type(repaired.miners) == "table", "miners is usable")
  expect.falsy(repaired.root, "a root that is not a chunk key is dropped")

  -- A malformed root must not become a real place. `grid.parse` returning nil is
  -- the whole guard, and the alternative - defaulting to 0,0 - would anchor the
  -- worksite to a chunk nobody chose.
  local post, why = coverage.postFor(repaired, T0)
  expect.falsy(post, "and nothing is dispatched")
  expect.truthy(why ~= nil, "with a reason")
end)
