--- Who holds which chunk, and which miner works where inside it.
---
--- `domain/chunk/grid.lua` is the geometry; this is the bookkeeping. It is
--- deliberately the same shape as `domain/mine/registry.lua` - claims with a
--- holder and a timestamp, a required `now`, no file and no clock of its own -
--- because it is the same kind of problem and the fleet already has one correct
--- answer to it.
---
--- ## A chunk claim is not a sector lease, in one important way
---
--- A sector lease that expires is handed to somebody else, and the worst case is
--- two turtles in one shaft for a few seconds until one of them notices. A chunk
--- claim that expires and is reassigned puts **two chunk-loading turtles in one
--- chunk**, which is the single thing this system exists to prevent: the second
--- general is a wasted turtle holding ground that was already held, and the
--- fleet's whole coverage budget is spent on duplicates.
---
--- So expiry here does not free the chunk. It marks the post **stale**: it stops
--- counting as coverage, so no miner is sent to work under a general that may not
--- be there, but the chunk is not offered to anybody else. The only two things
--- that free it are an operator saying so, and a general physically reporting
--- from that chunk - presence beats a stale record, which is the one piece of
--- evidence strong enough to overrule the invariant.
---
--- ## Slots are a property of the chunk, not of the headcount
---
--- A chunk is divided into `PER_CHUNK` worker slices once and forever.
--- `os/turtle/jobs/mining/quarry.lua` splits its area by `workerIndex` out of
--- `workerCount`, so it would be tempting to set `workerCount` to however many
--- miners happen to be assigned right now.
---
--- That would be wrong, and expensively so. Every change to `workerCount`
--- changes which cells a turtle owns, which changes its job settings, which bumps
--- a desired-state generation and restarts its cell range - so one miner running
--- out of fuel would re-cut the area under every other miner in the chunk. Fixing
--- the divisor means a slot is a stable thing to be assigned to, an absent miner
--- leaves an unworked slice rather than a reshuffle, and the next free turtle
--- picks that slice up.
---
--- ## Stability is the whole design goal
---
--- Everything here is written so that running it twice in a row changes nothing.
--- The server calls it on a timer; a comparator that could disagree with itself,
--- or an assignment that drifted when nothing had happened, would show up as a
--- fleet that re-tasks itself every few seconds and never finishes a chunk.

local grid = require("domain.chunk.grid")

local coverage = {}

--- Miners working one chunk at once.
---
--- Three. A chunk is 16x16 and 384 tall, so three turtles on disjoint cell
--- ranges is comfortable rather than crowded, and it is the ratio that makes one
--- general worth having: a general is a whole turtle, and one turtle spent to
--- keep three mining is a trade worth making. One would be a turtle per turtle.
coverage.PER_CHUNK = 3

--- Seconds before a claim is treated as stale.
---
--- Fifteen minutes, matching `domain/mine/registry.LEASE_SECONDS`. Generals are
--- stationary inside a chunk they are themselves keeping loaded, so they have
--- less excuse to go quiet than a miner at the bottom of a shaft - but the
--- consequence of being wrong is physical, so this errs long.
coverage.STALE_SECONDS = 900

local function elapsed(at, now)
  if at == nil then
    return math.huge
  end
  return math.max(0, (now - at) / 1000)
end

function coverage.empty()
  return {
    -- The base's chunk. Coverage grows outward from here and nothing is
    -- reachable until it is set, which is correct: a covered region that does
    -- not include home is a region with no way home.
    root = nil,
    posts = {},
    miners = {},
  }
end

--- Make a table read off disk safe to use.
function coverage.normalise(state)
  if type(state) ~= "table" then
    return coverage.empty()
  end
  state.posts = type(state.posts) == "table" and state.posts or {}
  state.miners = type(state.miners) == "table" and state.miners or {}
  if type(state.root) ~= "string" or grid.parse(state.root) == nil then
    state.root = nil
  end
  return state
end

--- Declare the base's chunk.
---
--- Derived from a world position rather than given as a chunk, because every
--- caller has coordinates and none of them should be doing the floor division
--- themselves - that is the arithmetic `grid.of` exists to have exactly one copy
--- of.
function coverage.setRoot(state, x, z)
  local cx, cz = grid.of(x, z)
  state.root = grid.key(cx, cz)
  return state.root
end

--- Is this post still answering?
local function live(post, now)
  return post ~= nil and elapsed(post.at, now) < coverage.STALE_SECONDS
end

--- Every chunk held by a general that is still reporting.
function coverage.held(state, now)
  local out = {}
  for key, post in pairs(state.posts) do
    if live(post, now) then
      for _, covered in ipairs(grid.footprint(post.cx, post.cz)) do
        out[covered] = key
      end
    end
  end
  return out
end

--- Chunks that are held *and* joined to the base.
---
--- The only chunks a miner may be sent into. An island of coverage is worse than
--- none: it looks like somewhere to work, and the flight home crosses ground
--- nobody is loading.
function coverage.covered(state, now)
  if state.root == nil then
    return {}
  end
  return grid.reachable(coverage.held(state, now), state.root)
end

--- Give a general a chunk, or say why not.
---
--- Returns the post, or nil and a sentence. The sentence is meant to be shown on
--- the general's own screen and read by somebody standing next to it, so it says
--- what to do rather than what is wrong.
function coverage.claim(state, generalId, cx, cz, now)
  cx, cz = math.floor(cx), math.floor(cz)
  local key = grid.key(cx, cz)
  local existing = state.posts[key]

  -- The invariant, and the only place it is enforced. Two chunk loaders in one
  -- chunk is not a race to settle later - it is a whole turtle standing there
  -- holding ground that was already held.
  --
  -- A *stale* holder is different: something is physically reporting from this
  -- chunk right now, and that is better evidence than a record nobody has
  -- refreshed in fifteen minutes. Presence wins, and the claim transfers.
  if existing and existing.general ~= generalId and live(existing, now) then
    return nil, ("chunk %d,%d is held by general %s"):format(cx, cz, tostring(existing.general))
  end

  -- One general, one chunk. A general that has moved releases what it had before
  -- taking anything new, or a fleet slowly accumulates ghost claims from every
  -- post its generals have ever stood in.
  coverage.release(state, generalId)

  state.posts[key] = {
    general = generalId,
    cx = cx,
    cz = cz,
    at = now,
    exhausted = existing and existing.exhausted == true or false,
  }
  return state.posts[key]
end

--- Keep a claim alive from ordinary status traffic.
---
--- Returns true when something was refreshed. Like the mine registry's `renew`,
--- this is driven off the heartbeat a general is already sending rather than a
--- message of its own - a stationary turtle saying "I am still here" every two
--- seconds is what a heartbeat already means.
function coverage.renew(state, generalId, now)
  for _, post in pairs(state.posts) do
    if post.general == generalId then
      post.at = now
      return true
    end
  end
  return false
end

--- Drop whatever this general was holding.
function coverage.release(state, generalId)
  local released = 0
  for key, post in pairs(state.posts) do
    if post.general == generalId then
      state.posts[key] = nil
      released = released + 1
    end
  end
  return released
end

--- Free a chunk by hand.
---
--- The operator's half of the staleness rule. A general that was destroyed
--- rather than merely quiet holds its chunk until somebody says otherwise,
--- because the alternative - freeing it automatically - is the duplicate-loader
--- failure this file exists to prevent.
function coverage.vacate(state, key)
  local post = state.posts[key]
  if post == nil then
    return false
  end
  state.posts[key] = nil
  for id, assignment in pairs(state.miners) do
    if assignment.chunk == key then
      state.miners[id] = nil
    end
  end
  return true
end

--- Mark a chunk worked out.
---
--- Kept rather than deleted, so the general holding it still counts as coverage
--- - an exhausted chunk in the middle of the region is still part of the route
--- home, and dropping it would punch a hole in the connected set.
function coverage.exhaust(state, key)
  local post = state.posts[key]
  if post == nil then
    return false
  end
  post.exhausted = true
  for id, assignment in pairs(state.miners) do
    if assignment.chunk == key then
      state.miners[id] = nil
    end
  end
  return true
end

--- Where the next general should stand.
---
--- The base chunk if nothing holds it yet, otherwise the nearest chunk touching
--- the covered region. Returns nil when there is no root - a fleet that has not
--- been told where home is has nowhere to start from, and guessing would anchor
--- the whole worksite to whichever turtle asked first.
function coverage.postFor(state, now)
  if state.root == nil then
    return nil, "the base has no chunk yet - run `commands/locate` on the server, or place the mine"
  end

  local held = coverage.held(state, now)
  if not held[state.root] then
    local cx, cz = grid.parse(state.root)
    return { cx = cx, cz = cz, key = state.root }
  end

  local frontier = grid.frontier(held, state.root)
  if #frontier == 0 then
    return nil, "every chunk touching the covered region is already held"
  end
  return frontier[1]
end

--- Chunks that can take another miner, nearest home first.
---
--- Nearest first because a compact region is a cheap one: every chunk close to
--- base is both a work site and part of the corridor out to the next one, so
--- filling inward-out means no general is ever spent purely on transit.
function coverage.openChunks(state, now)
  local covered = coverage.covered(state, now)
  local rootX, rootZ = grid.parse(state.root or "")
  if rootX == nil then
    return {}
  end

  local taken = {}
  for _, assignment in pairs(state.miners) do
    taken[assignment.chunk] = (taken[assignment.chunk] or 0) + 1
  end

  local out = {}
  for key in pairs(covered) do
    local post = state.posts[key]
    if post and not post.exhausted and (taken[key] or 0) < coverage.PER_CHUNK then
      local cx, cz = grid.parse(key)
      out[#out + 1] = {
        key = key,
        cx = cx,
        cz = cz,
        used = taken[key] or 0,
        distance = grid.distance(cx, cz, rootX, rootZ),
      }
    end
  end

  table.sort(out, function(a, b)
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.key < b.key
  end)
  return out
end

--- Which slot in this chunk is free, lowest first.
---
--- Lowest rather than any, so a chunk that loses its middle worker gives that
--- exact slice to the next turtle instead of opening a fourth. Deterministic for
--- the same reason everything else here is: the server re-runs this on a timer.
function coverage.freeSlot(state, key)
  local used = {}
  for _, assignment in pairs(state.miners) do
    if assignment.chunk == key then
      used[assignment.slot] = true
    end
  end
  for slot = 1, coverage.PER_CHUNK do
    if not used[slot] then
      return slot
    end
  end
  return nil
end

--- Is this miner's assignment still worth keeping?
local function standing(state, assignment, covered)
  if type(assignment) ~= "table" or covered[assignment.chunk] == nil then
    return false
  end
  local post = state.posts[assignment.chunk]
  return post ~= nil and not post.exhausted
end

--- Where this miner should be working.
---
--- Returns the assignment and whether it is new. **An existing valid assignment
--- is returned unchanged**, which is the property the whole file is built
--- around: the caller turns an assignment into a desired-state goal, and a goal
--- that differed from the last one would bump a generation and re-task a turtle
--- that was working perfectly well.
function coverage.assign(state, minerId, now)
  local id = tostring(minerId)
  local covered = coverage.covered(state, now)
  local existing = state.miners[id]

  if standing(state, existing, covered) then
    existing.at = now
    return existing, false
  end

  -- Whatever it had is no longer somewhere it can work. Dropped before choosing,
  -- so the slot it was holding is available to itself.
  state.miners[id] = nil

  local open = coverage.openChunks(state, now)
  if #open == 0 then
    return nil, false
  end

  local chunk = open[1]
  local slot = coverage.freeSlot(state, chunk.key)
  if slot == nil then
    return nil, false
  end

  state.miners[id] = { chunk = chunk.key, slot = slot, at = now }
  return state.miners[id], true
end

--- Which general a miner is working under, or nil.
---
--- Derived rather than stored, and that is the point: a miner is assigned a
--- chunk and a general holds that chunk, so the pairing already exists and
--- storing it again would be a second copy that can disagree with the first.
--- Reassign the chunk and the crew follows without anybody updating a list.
function coverage.generalOf(state, minerId)
  local assignment = state.miners[tostring(minerId)]
  if assignment == nil then
    return nil
  end
  local post = state.posts[assignment.chunk]
  if post == nil then
    return nil
  end
  return post.general
end

--- The miners working under one general.
---
--- The one fact about a general that nothing else knows. The base has the fleet
--- and it has the chunk claims; the pairing of a miner to the general covering
--- its ground is what this answers, and it is what a general's own screen shows.
---
--- Sorted, so a general's screen does not reshuffle its crew between two draws
--- of an unchanged assignment.
function coverage.crewOf(state, generalId)
  local out = {}
  for id, assignment in pairs(state.miners or {}) do
    local post = state.posts[assignment.chunk]
    if post ~= nil and post.general == generalId then
      out[#out + 1] = { id = tonumber(id) or id, chunk = assignment.chunk, slot = assignment.slot }
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end

--- Forget a miner, freeing its slice for somebody else.
function coverage.forget(state, minerId)
  local id = tostring(minerId)
  local had = state.miners[id] ~= nil
  state.miners[id] = nil
  return had
end

--- Drop assignments for miners nobody has heard from.
---
--- Unlike a chunk claim, an abandoned slice is safe to hand on: the consequence
--- of being wrong is two turtles quarrying disjoint cell ranges in one chunk,
--- which is what the chunk is divided into slices for in the first place.
function coverage.expireMiners(state, now)
  local dropped = 0
  for id, assignment in pairs(state.miners) do
    if elapsed(assignment.at, now) >= coverage.STALE_SECONDS then
      state.miners[id] = nil
      dropped = dropped + 1
    end
  end
  return dropped
end

--- The quarry settings for an assignment.
---
--- Exactly the shape `os/turtle/jobs/mining/quarry.lua` already reads, which is
--- the reason a chunk quarry needed no new turtle code: that job's defaults are
--- a 16x16 area split by `workerIndex` of `workerCount`, and a chunk is a 16x16
--- area. All this does is say which one.
function coverage.quarry(assignment, bounds)
  if type(assignment) ~= "table" then
    return nil
  end
  local cx, cz = grid.parse(assignment.chunk)
  if cx == nil then
    return nil
  end
  local minX, maxX, minZ, maxZ = grid.bounds(cx, cz)
  bounds = bounds or {}

  return {
    minX = minX,
    maxX = maxX,
    minZ = minZ,
    maxZ = maxZ,
    topY = math.floor(bounds.topY or 64),
    bottomY = math.floor(bounds.bottomY or -59),
    workerIndex = assignment.slot,
    -- Fixed, not the live headcount. See the header: a divisor that moved would
    -- re-cut the area under every other turtle in the chunk.
    workerCount = coverage.PER_CHUNK,
  }
end

--- What the Fleet and Devices pages show.
---
--- Rows rather than a formatted string, sorted nearest-home first so the list
--- reads outward from the base the way the region grew.
function coverage.summary(state, now)
  local covered = coverage.covered(state, now)
  local rootX, rootZ = grid.parse(state.root or "")

  local counts = {}
  for _, assignment in pairs(state.miners) do
    counts[assignment.chunk] = (counts[assignment.chunk] or 0) + 1
  end

  local rows = {}
  for key, post in pairs(state.posts) do
    local cx, cz = grid.parse(key)
    rows[#rows + 1] = {
      key = key,
      cx = cx,
      cz = cz,
      general = post.general,
      miners = counts[key] or 0,
      exhausted = post.exhausted == true,
      stale = not live(post, now),
      -- Held but not joined to the base. Worth showing on its own, because it
      -- is the one state that looks like coverage and is not usable as any.
      island = covered[key] == nil and live(post, now),
      distance = rootX and grid.distance(cx, cz, rootX, rootZ) or 0,
    }
  end

  table.sort(rows, function(a, b)
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.key < b.key
  end)
  return rows
end

return coverage
