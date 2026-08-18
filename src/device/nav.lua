--- Position tracking and safe movement.
---
--- The turtle has no idea where it is. This keeps a coordinate relative to
--- wherever the job started and writes it to disk after EVERY confirmed move.
--- That is the whole trick behind surviving a server restart: the world reloads,
--- the turtle reboots, and it still knows where it stands and how to walk home.
---
--- Position updates only after the game confirms the move succeeded, so the
--- count cannot drift away from reality.
---
--- Coordinates are job-relative: home is 0,0,0 and facing 0 is whatever
--- direction the turtle pointed when the job began. +y is up.

local config = require("adapters.cc.config")
local fuel = require("device.fuel")
local peers = require("device.peers")

local STATE_PATH = ".nav"

--- How long to stand and wait for another turtle to clear the block ahead.
--- Right of way goes to the lower computer ID: that turtle waits the full time,
--- the other gives up quickly so its caller can route around. Both sides reach
--- the same decision from numbers they already have, with no negotiation, and
--- the different timeouts break a head-on tie when both peer positions are known.
--- Bounded route detours handle the fallback when status data is unavailable.
local PEER_HOLD = 20
local PEER_YIELD = 3
local PEER_PAUSE = 0.5

local nav = {}

-- facing 0 -> +z, 1 -> +x, 2 -> -z, 3 -> -x  (turning right increments)
local DELTA = {
  [0] = { x = 0, z = 1 },
  [1] = { x = 1, z = 0 },
  [2] = { x = 0, z = -1 },
  [3] = { x = -1, z = 0 },
}

-- World compass, for turning job-relative coordinates into real ones.
-- 0 north (-z), 1 east (+x), 2 south (+z), 3 west (-x) - the order a turtle
-- turns through when it turns right.
local WORLD = {
  [0] = { x = 0, z = -1 },
  [1] = { x = 1, z = 0 },
  [2] = { x = 0, z = 1 },
  [3] = { x = -1, z = 0 },
}

nav.COMPASS = { "north", "east", "south", "west" }

local state = config.load(STATE_PATH, {
  x = 0,
  y = 0,
  z = 0,
  facing = 0,
  moves = 0, -- lifetime counters, for the dashboard
  digs = 0,

  -- Where home actually is in the world, and which way the turtle faced when
  -- the job began. Flat fields rather than a nested table because config.load
  -- merges only one level deep.
  originSet = false,
  originX = 0,
  originY = 0,
  originZ = 0,
  originHeading = 0,
})

local function save()
  config.save(STATE_PATH, state)
end

function nav.position()
  return state.x, state.y, state.z, state.facing
end

function nav.stats()
  return { moves = state.moves, digs = state.digs }
end

--- Declare "here" to be home. Call once when starting a fresh job.
function nav.setHome()
  state.x, state.y, state.z, state.facing = 0, 0, 0, 0
  save()
end

--- Manhattan distance to 0,0,0 - exactly how many moves, and so how much fuel,
--- the trip home costs.
function nav.distanceHome()
  return math.abs(state.x) + math.abs(state.y) + math.abs(state.z)
end

--- Could the turtle still get home right now? The margin covers the moves it
--- takes to notice a problem and any detour around it.
function nav.canReturn(margin)
  return fuel.available() >= nav.distanceHome() + (margin or 0)
end

--- Blocks the turtle must never break, whatever is in its way.
---
--- Without this a turtle placed under another turtle digs its neighbour up on
--- launch - a prospecting job's first move is to rise to cruise altitude, and
--- `up` digs. The fleet eats itself and you are left wondering where a turtle
--- went. Chests are protected for the same reason: that is where the haul goes.
---
--- The second return value separates two situations that used to look identical
--- and are not: a chest is there forever and the route has to change, whereas a
--- turtle is there for a few seconds and the route is fine. Both are still
--- refusals - neither is ever dug - but only one is a reason to give up.
---
--- Note this guards `nav` only. `legacy/apps/swarm.lua` reclaims workers with raw
--- `turtle.dig`, which is deliberate and unaffected.
local function obstacle(inspect)
  local ok, data = inspect()
  if not ok or type(data) ~= "table" then
    return nil
  end

  local name = tostring(data.name)
  if name:find("lava") then
    return "lava", "hazard"
  end
  if name:find("computercraft:turtle") then
    return "turtle in the way", "peer"
  end
  if name:find("computercraft:") or name:find("chest") or name:find("barrel") then
    return "protected block (" .. name .. ")", "protected"
  end
  return nil
end

--- World block this turtle would occupy after `delta`, or nil without an origin.
local function targetWorld(delta)
  if not delta or not state.originSet then
    return nil
  end
  local here = nav.worldPosition()
  if not here then
    return nil
  end
  local forward = WORLD[state.originHeading]
  local right = WORLD[(state.originHeading + 1) % 4]
  local relativeX, relativeZ = delta.x or 0, delta.z or 0
  local worldX = relativeZ * forward.x + relativeX * right.x
  local worldZ = relativeZ * forward.z + relativeX * right.z
  return here.x + worldX, here.y + (delta.y or 0), here.z + worldZ
end

--- Stand and wait for a peer to move out of the way.
---
--- Returns true if the block cleared. The wait length depends on who has right
--- of way, which is what keeps two turtles from politely blocking each other for
--- the rest of the session.
local function waitForPeer(inspect, delta)
  local blocker = peers.at(targetWorld(delta))
  local limit = (blocker and peers.yieldsTo(blocker.id)) and PEER_YIELD or PEER_HOLD

  for _ = 1, limit do
    -- Jitter, so two turtles that met head-on do not sample in lockstep.
    sleep(PEER_PAUSE + math.random() * 0.4)
    local _, kind = obstacle(inspect)
    if kind ~= "peer" then
      return true
    end
  end
  return false
end

--- Move one block, clearing whatever is in the way.
---
--- Gravel and sand fall back into the space and mobs stand in it, so this
--- retries rather than giving up on the first failure. A block that will not
--- break after many attempts is bedrock or someone's claim - we report that
--- instead of grinding forever.
---
--- `delta` is this move's direction in job-relative axes, used only to work out
--- which peer is in the way. It is optional; without it the wait still happens,
--- just without the right-of-way shortcut.
local function push(move, dig, detect, attack, inspect, delta)
  local reason, kind = obstacle(inspect)
  if kind == "peer" and not waitForPeer(inspect, delta) then
    return false, reason, "peer"
  elseif kind and kind ~= "peer" then
    return false, reason, kind
  end

  if not fuel.ensureMove() then
    return false, "out of fuel", "fuel"
  end

  for attempt = 1, 100 do
    if move() then
      state.moves = state.moves + 1
      return true
    end

    if detect() then
      -- Re-check before every dig, not just once on entry. A peer that arrives
      -- while we are chewing through gravel would otherwise be mined up by the
      -- next swing, which is the one failure this whole guard exists to prevent.
      local blocked, blockedKind = obstacle(inspect)
      if blockedKind == "peer" then
        if not waitForPeer(inspect, delta) then
          return false, blocked, "peer"
        end
      elseif blockedKind then
        return false, blocked, blockedKind
      elseif not dig() then
        return false, "unbreakable", "blocked"
      else
        state.digs = state.digs + 1
      end
    else
      -- Nothing solid there, so something alive is standing in it.
      attack()
      sleep(0.2)
    end

    if attempt % 10 == 0 then
      sleep(0.4) -- let falling gravel settle
    end
  end

  return false, "blocked", "blocked"
end

function nav.forward()
  local delta = { x = DELTA[state.facing].x, y = 0, z = DELTA[state.facing].z }
  local ok, err, kind =
    push(turtle.forward, turtle.dig, turtle.detect, turtle.attack, turtle.inspect, delta)
  if not ok then
    return false, err, kind
  end
  state.x = state.x + delta.x
  state.z = state.z + delta.z
  save()
  return true
end

--- Retreat one block without turning and without digging.
--- Used to unwind after stepping into a vein: the space behind is the one we
--- just came out of, so it is always clear - unless another turtle has wandered
--- into it, which is worth waiting out rather than reporting as a dead end.
function nav.back()
  if not fuel.ensureMove() then
    return false, "out of fuel", "fuel"
  end

  local delta = { x = -DELTA[state.facing].x, y = 0, z = -DELTA[state.facing].z }
  local blocker = peers.at(targetWorld(delta))
  local limit = (blocker and peers.yieldsTo(blocker.id)) and PEER_YIELD or PEER_HOLD

  for attempt = 1, limit do
    if turtle.back() then
      state.moves = state.moves + 1
      state.x = state.x - DELTA[state.facing].x
      state.z = state.z - DELTA[state.facing].z
      save()
      return true
    end
    if attempt < limit then
      sleep(PEER_PAUSE + math.random() * 0.4)
    end
  end
  return false, blocker and "turtle in the way" or "blocked", blocker and "peer" or "blocked"
end

function nav.up()
  local ok, err, kind =
    push(turtle.up, turtle.digUp, turtle.detectUp, turtle.attackUp, turtle.inspectUp, { y = 1 })
  if not ok then
    return false, err, kind
  end
  state.y = state.y + 1
  save()
  return true
end

function nav.down()
  local ok, err, kind = push(
    turtle.down,
    turtle.digDown,
    turtle.detectDown,
    turtle.attackDown,
    turtle.inspectDown,
    { y = -1 }
  )
  if not ok then
    return false, err, kind
  end
  state.y = state.y - 1
  save()
  return true
end

--- Dig the block below without moving. Refuses lava, which we leave sealed
--- rather than flooding the pit, and refuses chests and computers.
function nav.digDown()
  local refusal, kind = obstacle(turtle.inspectDown)
  if refusal then
    return false, refusal, kind
  end
  if not turtle.detectDown() then
    return true
  end
  if not turtle.digDown() then
    return false, "unbreakable"
  end
  state.digs = state.digs + 1
  save()
  return true
end

function nav.digUp()
  local refusal, kind = obstacle(turtle.inspectUp)
  if refusal then
    return false, refusal, kind
  end
  if not turtle.detectUp() then
    return true
  end
  if not turtle.digUp() then
    return false, "unbreakable"
  end
  state.digs = state.digs + 1
  save()
  return true
end

function nav.turnRight()
  turtle.turnRight()
  state.facing = (state.facing + 1) % 4
  save()
end

function nav.turnLeft()
  turtle.turnLeft()
  state.facing = (state.facing + 3) % 4
  save()
end

--- Turn to an absolute facing, the short way round.
function nav.face(facing)
  local diff = (facing - state.facing) % 4
  if diff == 1 then
    nav.turnRight()
  elseif diff == 2 then
    nav.turnRight()
    nav.turnRight()
  elseif diff == 3 then
    nav.turnLeft()
  end
end

--- How many times a route will step out of the way and re-plan before giving up.
local DETOUR_ATTEMPTS = 4

--- Move failures that mean "not this way" rather than "stop working".
---
--- A turtle in the corridor was always a delay. Lava is the same shape of
--- problem and was not treated that way: refusing to mine it is correct, but
--- ending the route over it means one pocket at diamond level costs a whole
--- commute. A protected block and an unbreakable one are no different - the
--- route has to change, the trip does not have to end.
nav.ROUTE_AROUND = {
  peer = true,
  hazard = true,
  protected = true,
  blocked = true,
}

--- Walk to a job-relative coordinate.
--- Rises before travelling and descends last, so the turtle crosses air it has
--- already mined rather than tunnelling through fresh rock on the way back.
---
--- A turtle parked in the corridor is not a failed route. When one is in the way
--- and we do not have right of way, the route steps aside and re-plans from
--- wherever that leaves it, rather than reporting the whole trip as stuck - which
--- is what used to send a miner home the moment it met a colleague.
--- How far above the requested altitude a terrain-following route may climb.
--- Enough for any ordinary hill; a mountain taller than this is dug through as
--- before, because a turtle circling a peak forever is worse than a tunnel.
nav.CLIMB_LIMIT = 40

function nav.goTo(tx, ty, tz, beforeMove, options)
  options = options or {}
  local ceiling = ty + (options.climb or 0)

  local function checked(move)
    if beforeMove then
      local allowed, reason, kind = beforeMove()
      if not allowed then
        return false, reason, kind
      end
    end
    return move()
  end

  --- Cross one axis, optionally going over the ground rather than through it.
  ---
  --- Rising only when the block overhead is already air is the whole point: it
  --- costs nothing to fly over a hill, whereas digging one produces a horizontal
  --- bore through the hillside and, worse, a vertical hole if the turtle climbs
  --- out. Terrain that is genuinely enclosed still gets tunnelled.
  ---
  --- Height once gained is kept until the end of the route, and that is not
  --- laziness. Sinking back to the requested altitude as soon as the ground
  --- falls away looks tidier and is far worse: over stepped ground - a
  --- shoreline, a ravine wall, a hillside of one-block terraces - the turtle
  --- spends the entire crossing climbing and dropping the same blocks, one step
  --- at a time. The single descent at the end of `legs` costs exactly the same
  --- moves as the first sink would have, and every later one is pure waste.
  local function cross(axis, target, facing)
    if axis() == target then
      return true
    end
    nav.face(facing)
    while axis() ~= target do
      if options.climb and state.y < ceiling and turtle.detect() and not turtle.detectUp() then
        local lifted, liftError, liftKind = checked(nav.up)
        if not lifted then
          return false, liftError, liftKind
        end
      else
        local ok, err, kind = checked(nav.forward)
        if not ok then
          return false, err, kind
        end
      end
    end
    return true
  end

  --- Rise, cross X, cross Z, descend. Each leg runs to completion or reports why.
  local function legs()
    while state.y < ty do
      local ok, err, kind = checked(nav.up)
      if not ok then
        return false, err, kind
      end
    end

    local crossedX, xError, xKind = cross(function()
      return state.x
    end, tx, state.x < tx and 1 or 3)
    if not crossedX then
      return false, xError, xKind
    end

    local crossedZ, zError, zKind = cross(function()
      return state.z
    end, tz, state.z < tz and 0 or 2)
    if not crossedZ then
      return false, zError, zKind
    end

    while state.y > ty do
      local ok, err, kind = checked(nav.down)
      if not ok then
        return false, err, kind
      end
    end

    return true
  end

  --- Get out of the corridor. Up first: overhead is the direction least likely
  --- to hold another turtle, since traffic runs along tunnels rather than
  --- through their ceilings, and it is also the way past a pool of lava lying
  --- in the floor of a tunnel.
  local function sidestep()
    if checked(nav.up) then
      return true
    end
    for _ = 1, 4 do
      nav.turnRight()
      if checked(nav.forward) then
        return true
      end
    end
    return checked(nav.down)
  end

  local lastError, lastKind = nil, nil
  for attempt = 1, DETOUR_ATTEMPTS do
    local ok, err, kind = legs()
    if ok then
      return true
    end
    lastError, lastKind = err, kind
    if not nav.ROUTE_AROUND[kind or ""] or attempt == DETOUR_ATTEMPTS then
      return false, err, kind
    end
    if not sidestep() then
      return false, err, kind
    end
  end

  return false, lastError or "route blocked", lastKind or "blocked"
end

--- Back to the starting block, facing the original direction.
function nav.goHome()
  local ok, err = nav.goTo(0, 0, 0)
  if not ok then
    return false, err
  end
  nav.face(0)
  return true
end

--- Declare the current block as home in both coordinate systems, and record
--- which way the turtle faces there. `heading` is an index into nav.COMPASS.
---
--- This is what makes real world coordinates possible without GPS. The turtle
--- already knows its offset from home exactly - every move is only counted once
--- the game confirms it - so one fixed reference point is all that is missing.
function nav.setOrigin(x, y, z, heading)
  state.x, state.y, state.z, state.facing = 0, 0, 0, 0
  state.originSet = true
  state.originX, state.originY, state.originZ = x, y, z
  state.originHeading = heading % 4
  save()
end

function nav.hasOrigin()
  return state.originSet == true
end

function nav.origin()
  if not state.originSet then
    return nil
  end
  return {
    x = state.originX,
    y = state.originY,
    z = state.originZ,
    heading = state.originHeading,
  }
end

--- Convert an absolute world block into this job's relative coordinate system.
function nav.worldToRelative(x, y, z)
  if not state.originSet then
    return nil, "world origin is not configured - run where on this turtle"
  end
  local dx, dz = x - state.originX, z - state.originZ
  local forward = WORLD[state.originHeading]
  local right = WORLD[(state.originHeading + 1) % 4]
  return {
    x = dx * right.x + dz * right.z,
    y = y - state.originY,
    z = dx * forward.x + dz * forward.z,
  }
end

--- Convert a world-axis offset into job-relative axes.
function nav.worldOffsetToRelative(dx, dy, dz)
  if not state.originSet then
    return nil, "world heading is not configured"
  end
  local forward = WORLD[state.originHeading]
  local right = WORLD[(state.originHeading + 1) % 4]
  return {
    x = dx * right.x + dz * right.z,
    y = dy,
    z = dx * forward.x + dz * forward.z,
  }
end

--- Convert scanner front/right/up offsets at the current facing into an
--- absolute job-relative coordinate.
function nav.scannerTarget(front, right, up)
  local forwardDelta = DELTA[state.facing]
  local rightDelta = DELTA[(state.facing + 1) % 4]
  return {
    x = state.x + front * forwardDelta.x + right * rightDelta.x,
    y = state.y + up,
    z = state.z + front * forwardDelta.z + right * rightDelta.z,
  }
end

--- Real world coordinates.
---
--- Prefers dead reckoning from a known origin over GPS, which is deliberate:
--- GPS needs four loaded hosts and does not provide heading. Ender modems make
--- an excellent long-range constellation, but the saved origin keeps movement
--- independent of host chunk loading, radio range, and temporary network loss.
--- Dead reckoning costs nothing and is as accurate as the navigation itself.
function nav.worldPosition()
  if state.originSet then
    local forward = WORLD[state.originHeading]
    local right = WORLD[(state.originHeading + 1) % 4]
    return {
      x = state.originX + state.z * forward.x + state.x * right.x,
      y = state.originY + state.y,
      z = state.originZ + state.z * forward.z + state.x * right.z,
    }
  end

  local x, y, z = gps.locate(2, false)
  if not x then
    return nil
  end
  return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
end

return nav
