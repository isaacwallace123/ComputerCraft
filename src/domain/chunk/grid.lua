--- The chunk grid: the unit the game loads, and therefore the unit work happens in.
---
--- ## Why this exists
---
--- A turtle outside a loaded chunk is not disobedient, it is **not running**.
--- Desired state fixed the delivery of orders (§5) and cannot fix a machine that
--- is not executing, so an unattended fleet needs to carry its own loaded region
--- around with it. That is what a chunk-loading turtle - a *general* - is for,
--- and this file is the arithmetic underneath the whole idea.
---
--- ## One chunk per general, and the measurement that decided it
---
--- Advanced Peripherals' Chunky Turtle "actively loads the current turtle's
--- chunk" and exposes no methods at all - it is a passive upgrade, one chunk,
--- no radius. That is the hardware this fleet runs (`peripheral.find("chunky")`),
--- so `RADIUS` is zero and a footprint is a single chunk.
---
--- It is still expressed as a radius rather than hard-coded to one chunk,
--- because the other chunk loaders in circulation are not zero - CCChunkloader
--- takes a `setRadius` from 0 to 2.5 - and the difference is not cosmetic. Under
--- a radius-1 loader, two generals placed "exactly one chunk apart" sit in
--- different chunks, satisfy every rule anybody would write down, and overlap on
--- six of their nine chunks. The rule that survives a change of mod is **no two
--- footprints intersect**, and one-chunk-apart is what that reduces to at radius
--- zero.
---
--- ## Connectivity is the property that matters, and it is easy to lose
---
--- A miner flying home crosses every chunk between its work and the base. If the
--- covered region has a hole in it, the turtle stops in that hole with a full
--- inventory and stays there until somebody walks out to it. So the covered set
--- is grown **outward from the base chunk, one adjacent chunk at a time**, which
--- makes it 4-connected by construction rather than by inspection.
---
--- That is also why the cheapest possible shape is the right one: a compact blob
--- rooted at the base means every chunk in it is both a work site and a piece of
--- the corridor home, so no general is ever spent purely on transit.
---
--- Everything here is integer arithmetic over plain tables. No world, no clock,
--- no state - `domain/fleet/coverage.lua` holds what is claimed and this holds
--- what the geometry means.

local grid = {}

--- Blocks along one edge of a chunk. Minecraft's, not ours.
grid.SIZE = 16

--- How many chunks out from itself a loader keeps loaded.
---
--- Zero for the Chunky Turtle: its own chunk and nothing else. A footprint is
--- therefore one chunk, and generals tile at one-chunk spacing.
grid.RADIUS = 0

--- Chunk coordinates for a world position.
---
--- Floor division, so negative coordinates land in the chunk a player would
--- name. `-1` is in chunk `-1`, not chunk `0` - which `math.floor` gets right
--- and integer truncation gets wrong for exactly half the world.
function grid.of(x, z)
  return math.floor(x / grid.SIZE), math.floor(z / grid.SIZE)
end

--- The table key for a chunk.
---
--- A string, because Lua tables cannot be keyed by a pair and because this is
--- serialised into a state file that has to survive a round trip through
--- `textutils`. Signed, comma-separated, no padding.
function grid.key(cx, cz)
  return ("%d,%d"):format(math.floor(cx), math.floor(cz))
end

--- The chunk a key names, or nil if it names nothing.
---
--- Nil rather than an error: keys come off disk and out of messages, and a
--- malformed one is a thing to skip rather than a reason to stop leasing chunks
--- to the rest of the fleet.
function grid.parse(key)
  if type(key) ~= "string" then
    return nil
  end
  local cx, cz = key:match("^(-?%d+),(-?%d+)$")
  if cx == nil then
    return nil
  end
  return tonumber(cx), tonumber(cz)
end

--- World bounds of a chunk, inclusive.
---
--- The shape `os/turtle/jobs/mining/quarry.lua` wants: `minX`, `maxX`, `minZ`,
--- `maxZ`. That job's own defaults are already a 16x16 area, which is not a
--- coincidence worth ignoring - a chunk quarry needs no new turtle code at all,
--- only these four numbers and a worker slot.
function grid.bounds(cx, cz)
  local minX = math.floor(cx) * grid.SIZE
  local minZ = math.floor(cz) * grid.SIZE
  return minX, minX + grid.SIZE - 1, minZ, minZ + grid.SIZE - 1
end

--- Where a general stands to hold a chunk.
---
--- The middle, so the post is as far as possible from all four boundaries. A
--- general parked on a chunk edge is one accidental push from holding the wrong
--- chunk, and the whole system's correctness rests on which chunk it is in.
function grid.post(cx, cz)
  local minX, _, minZ, _ = grid.bounds(cx, cz)
  return minX + math.floor(grid.SIZE / 2), minZ + math.floor(grid.SIZE / 2)
end

--- The four chunks sharing an edge with this one.
---
--- Four, not eight. A diagonal neighbour touches only at a corner, and a turtle
--- flying between two diagonally adjacent loaded chunks passes through one of
--- the two unloaded chunks between them - so treating diagonals as connected
--- would produce a region that looks joined and is not.
function grid.neighbours(cx, cz)
  cx, cz = math.floor(cx), math.floor(cz)
  return {
    { cx + 1, cz },
    { cx - 1, cz },
    { cx, cz + 1 },
    { cx, cz - 1 },
  }
end

--- Chunks between two chunks, walking on cardinals.
---
--- Manhattan rather than Euclidean because `os/turtle/device/nav.lua` travels on
--- cardinals: a diagonal flight is walked as a staircase, so the distance that
--- predicts fuel and time is the one that counts turns as well as steps.
function grid.distance(ax, az, bx, bz)
  return math.abs(ax - bx) + math.abs(az - bz)
end

--- Every chunk a loader at `cx, cz` holds.
---
--- A square of side `2r+1`. At the fleet's radius of zero this is one key, and
--- the loop is still written out rather than special-cased so that changing
--- `RADIUS` changes behaviour rather than revealing an assumption.
function grid.footprint(cx, cz, radius)
  radius = radius or grid.RADIUS
  local keys = {}
  for dx = -radius, radius do
    for dz = -radius, radius do
      keys[#keys + 1] = grid.key(cx + dx, cz + dz)
    end
  end
  return keys
end

--- Chunks between two posts that do not overlap.
---
--- `2r+1`, which is 1 at radius zero - the "exactly one chunk apart" that a
--- one-chunk loader wants, arrived at rather than assumed.
function grid.spacing(radius)
  return 2 * (radius or grid.RADIUS) + 1
end

--- Do two loaders at these posts hold any chunk in common?
---
--- The invariant, stated once. Square footprints, so this is a separating-axis
--- test on two axes and needs no set arithmetic.
function grid.overlaps(ax, az, bx, bz, radius)
  radius = radius or grid.RADIUS
  return math.abs(ax - bx) <= 2 * radius and math.abs(az - bz) <= 2 * radius
end

--- The chunks reachable from `root` through `held`, walking on edges.
---
--- `held` is a set of chunk keys. Returns a set of the keys in the same
--- 4-connected component as the root, which is the only part of a covered region
--- a turtle can safely be sent into: everything else is an island whose route
--- home crosses ground nobody is loading.
---
--- A root that is not itself held returns an empty set. That is the honest
--- answer - if nothing is holding the base chunk, nothing is reachable from it -
--- and it is what stops a fleet being dispatched into a region it cannot come
--- back through.
function grid.reachable(held, rootKey)
  local seen = {}
  if type(held) ~= "table" or not held[rootKey] then
    return seen
  end

  local queue = { rootKey }
  seen[rootKey] = true
  local head = 1

  while head <= #queue do
    local key = queue[head]
    head = head + 1
    local cx, cz = grid.parse(key)
    if cx then
      for _, neighbour in ipairs(grid.neighbours(cx, cz)) do
        local other = grid.key(neighbour[1], neighbour[2])
        if held[other] and not seen[other] then
          seen[other] = true
          queue[#queue + 1] = other
        end
      end
    end
  end

  return seen
end

--- Chunks that are not held but touch something that is, nearest the root first.
---
--- The expansion order, and the reason the covered region stays cheap. Growing
--- outward from the base a ring at a time keeps the blob compact, and a compact
--- blob is one where nearly every chunk is both worked and walked through - so
--- the corridor costs nothing extra.
---
--- Ties break on the key, so two chunks at the same distance are always chosen
--- in the same order. Determinism matters more than it looks here: the server
--- runs this on a timer, and a comparator that could disagree with itself would
--- dispatch a general, change its mind, and dispatch it back.
function grid.frontier(held, rootKey)
  local rootX, rootZ = grid.parse(rootKey)
  if rootX == nil then
    return {}
  end

  -- Only the component containing the root may be grown. An island's frontier
  -- would extend an island, which is more coverage and no more reachable ground.
  local reachable = grid.reachable(held, rootKey)

  local candidates = {}
  local added = {}
  for key in pairs(reachable) do
    local cx, cz = grid.parse(key)
    if cx then
      for _, neighbour in ipairs(grid.neighbours(cx, cz)) do
        local other = grid.key(neighbour[1], neighbour[2])
        if not held[other] and not added[other] then
          added[other] = true
          candidates[#candidates + 1] = {
            key = other,
            cx = neighbour[1],
            cz = neighbour[2],
            distance = grid.distance(neighbour[1], neighbour[2], rootX, rootZ),
          }
        end
      end
    end
  end

  table.sort(candidates, function(a, b)
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.key < b.key
  end)

  return candidates
end

return grid
