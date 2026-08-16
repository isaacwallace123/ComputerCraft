--- Shared worksite geometry: one mine, a fixed set of shafts reused forever.
---
--- The prospecting jobs used to roll a fresh random bearing every cycle, sink a
--- shaft wherever that landed, and never go back. That is why the surface around
--- a base ends up covered in one-shot holes: the hole count grows with the number
--- of CYCLES the fleet has run.
---
--- Here the world is divided once into a grid of square sectors centred on the
--- base. Each sector owns exactly one shaft at its centre, dug on the first visit
--- and simply fallen down on every visit after that. The hole count now grows
--- with the number of SECTORS the fleet has opened, which is bounded by `maxRing`
--- and is a number you can count on one hand for a long time.
---
--- Everything in this file is pure arithmetic over a plan table. The base station
--- and every turtle derive identical coordinates from the same handful of
--- numbers, so a sector map never has to be transmitted - only the plan does.

local plan = {}

plan.DEFAULTS = {
  configured = false,

  -- Centre of the whole worksite in world coordinates, normally the base.
  centreX = 0,
  centreZ = 0,

  -- Surface Y at the centre. Shaft heads start here.
  --
  -- Depth is deliberately NOT part of the plan. Rare wants Y -59 and Resources
  -- wants Y 16, and both should be able to use the same shaft - so the plan owns
  -- the X/Z grid and the surface, and each job keeps its own `targetY`. A shaft
  -- simply gets deepened by whichever turtle needs to go further.
  surfaceY = 64,

  -- Edge length of one sector square, and so the length of its trunk tunnel.
  cellSize = 48,

  -- Flight altitude for surface transit, as an absolute Y.
  cruiseY = 72,

  -- Sectors live in rings around the centre cell. Ring r holds 8r sectors, so
  -- three rings is 48 shafts - far more than a fleet works through in practice.
  maxRing = 3,

  -- First ring that may be opened. Raising this is how you keep the digging away
  -- from where you live: ring r sits at least r * cellSize blocks out, so a
  -- keep-out radius is just a minimum ring. The cost is a longer commute on
  -- every trip, since the shafts are further from the depot.
  minRing = 1,

  -- Rib spacing along the trunk. Three leaves two unmined blocks between ribs,
  -- which vein following covers without excavating them.
  branchSpacing = 3,
}

--- Number of sectors contained in rings 1..r.
local function sectorsWithin(ring)
  return 4 * ring * (ring + 1)
end

--- Sectors skipped by the keep-out radius, and so the offset between a logical
--- sector index (what gets leased) and its absolute position in the ring spiral.
local function skipped(p)
  return sectorsWithin((p.minRing or plan.DEFAULTS.minRing) - 1)
end

function plan.capacity(p)
  return sectorsWithin(p.maxRing or plan.DEFAULTS.maxRing) - skipped(p)
end

--- Closest any block may be dug to the centre, in blocks.
---
--- Not the shaft distance: the innermost sector's shaft sits at
--- `minRing * cellSize`, but its trunk and ribs reach half a cell back towards
--- the centre, and that inner edge is what actually has to clear your base.
function plan.keepout(p)
  local size = p.cellSize or plan.DEFAULTS.cellSize
  return (p.minRing or plan.DEFAULTS.minRing) * size - math.floor(size / 2)
end

--- Smallest ring whose sectors dig no closer than `blocks` from the centre.
--- Inverse of `plan.keepout`, rounded so it never under-shoots the request.
function plan.ringForKeepout(p, blocks)
  local size = p.cellSize or plan.DEFAULTS.cellSize
  return math.max(1, math.ceil((math.max(0, blocks) + math.floor(size / 2)) / size))
end

--- Sector index -> integer cell coordinates around the centre cell.
---
--- Cells are enumerated ring by ring, walking each ring's perimeter, so index 1
--- is always adjacent to base and higher indices spiral outward. The centre cell
--- itself is never returned: that is where the base sits.
function plan.cell(index)
  index = math.floor(index)
  if index < 1 then
    return nil
  end

  local ring = 1
  while index > sectorsWithin(ring) do
    ring = ring + 1
  end

  -- Position around this ring's perimeter, 0-based. Each of the four sides
  -- contributes 2*ring cells, for 8*ring in total.
  local offset = index - sectorsWithin(ring - 1) - 1
  local side = math.floor(offset / (2 * ring))
  local step = offset % (2 * ring)

  if side == 0 then
    return ring, -ring + step, ring
  elseif side == 1 then
    return ring - step, ring, ring
  elseif side == 2 then
    return -ring, ring - step, ring
  end
  return -ring + step, -ring, ring
end

--- Full description of one sector: its shaft, its bounds, and the trunk it works.
---
--- The trunk always runs along X at the shaft's Z, spanning the whole cell, with
--- ribs reaching out to the cell edge on both sides in Z. Keeping the trunk
--- axis-aligned matters because `nav.goTo` only travels on cardinals - a radial
--- trunk would be walked as a staircase and cost far more digging.
--- `index` is a logical sector number, 1..capacity. The keep-out radius shifts it
--- outward in the spiral, so sector 1 is always the nearest sector the fleet is
--- allowed to open rather than the nearest that exists.
function plan.sector(p, index)
  if index < 1 or index > plan.capacity(p) then
    return nil
  end

  local cx, cz, ring = plan.cell(index + skipped(p))
  if not cx then
    return nil
  end

  local size = p.cellSize or plan.DEFAULTS.cellSize
  local half = math.floor(size / 2)
  local shaftX = (p.centreX or 0) + cx * size
  local shaftZ = (p.centreZ or 0) + cz * size

  return {
    index = index,
    ring = ring,
    cellX = cx,
    cellZ = cz,
    shaftX = shaftX,
    shaftZ = shaftZ,
    minX = shaftX - half,
    maxX = shaftX - half + size - 1,
    minZ = shaftZ - half,
    maxZ = shaftZ - half + size - 1,
    -- Trunk endpoints. Work always starts at minX and advances towards maxX so
    -- a saved frontier means the same thing on every visit.
    trunkZ = shaftZ,
    trunkFromX = shaftX - half,
    trunkToX = shaftX - half + size - 1,
    trunkLength = size,
    -- One short of half a cell on purpose. A rib reaching a full `half` from the
    -- trunk lands on the first block of the next sector, which is how two
    -- turtles that were given disjoint ground end up nose to nose anyway.
    ribReach = half - 1,
  }
end

--- Cruise altitude for a sector.
---
--- Every turtle flies out from the same base, so the airspace directly above it
--- is the one place the whole fleet shares. Eight staggered lanes greatly reduce
--- crossings; sectors farther out reuse them, with peer avoidance handling the
--- remaining encounters.
function plan.laneY(p, index)
  local base = p.cruiseY or plan.DEFAULTS.cruiseY
  return base + ((math.floor(index) - 1) % 8)
end

--- Clamp a plan into a usable shape. Called on both sides of the network so a
--- malformed or half-configured plan can never send a turtle somewhere absurd.
function plan.normalise(p)
  local result = {}
  for key, value in pairs(plan.DEFAULTS) do
    result[key] = value
  end
  for key, value in pairs(p or {}) do
    if plan.DEFAULTS[key] ~= nil then
      result[key] = value
    end
  end

  result.centreX = math.floor(tonumber(result.centreX) or 0)
  result.centreZ = math.floor(tonumber(result.centreZ) or 0)
  -- Eight cruise lanes need two blocks above the surface and must remain at or
  -- below Y 319, so a worksite above 310 cannot be represented safely.
  result.surfaceY = math.floor(math.max(-63, math.min(310, tonumber(result.surfaceY) or 64)))
  result.cellSize = math.floor(math.max(16, math.min(128, tonumber(result.cellSize) or 48)))
  result.maxRing = math.floor(math.max(1, math.min(8, tonumber(result.maxRing) or 3)))
  -- A keep-out that swallowed every ring would leave nothing to mine.
  result.minRing = math.floor(math.max(1, math.min(result.maxRing, tonumber(result.minRing) or 1)))
  result.branchSpacing = math.floor(math.max(2, math.min(8, tonumber(result.branchSpacing) or 3)))

  -- Cruising below the surface would fly turtles through the ground, and the
  -- eight lanes above `cruiseY` all have to stay under the build limit.
  local lowest = result.surfaceY + 2
  result.cruiseY = math.floor(tonumber(result.cruiseY) or (result.surfaceY + 8))
  result.cruiseY = math.max(lowest, math.min(312, result.cruiseY))

  result.configured = result.configured == true
  return result
end

function plan.describe(p, index)
  local sector = plan.sector(p, index)
  if not sector then
    return "no sector"
  end
  return ("sector %d  shaft %d,%d  trunk %d long"):format(
    sector.index,
    sector.shaftX,
    sector.shaftZ,
    sector.trunkLength
  )
end

return plan
