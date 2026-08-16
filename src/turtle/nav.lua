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

local config = require("core.config")
local fuel = require("turtle.fuel")

local STATE_PATH = ".nav"

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
  return fuel.level() >= nav.distanceHome() + (margin or 0)
end

--- Blocks the turtle must never break, whatever is in its way.
---
--- Without this a turtle placed under another turtle digs its neighbour up on
--- launch - the expedition's first move is to rise to cruise altitude, and
--- `up` digs. The fleet eats itself and you are left wondering where a turtle
--- went. Chests are protected for the same reason: that is where the haul goes.
---
--- Note this guards `nav` only. `apps/swarm.lua` reclaims workers with raw
--- `turtle.dig`, which is deliberate and unaffected.
local function refuses(inspect)
  local ok, data = inspect()
  if not ok or type(data) ~= "table" then
    return nil
  end

  local name = tostring(data.name)
  if name:find("lava") then
    return "lava"
  end
  if name:find("computercraft:") or name:find("chest") or name:find("barrel") then
    return "protected block (" .. name .. ")"
  end
  return nil
end

--- Move one block, clearing whatever is in the way.
---
--- Gravel and sand fall back into the space and mobs stand in it, so this
--- retries rather than giving up on the first failure. A block that will not
--- break after many attempts is bedrock or someone's claim - we report that
--- instead of grinding forever.
local function push(move, dig, detect, attack, inspect)
  local refusal = refuses(inspect)
  if refusal then
    return false, refusal
  end

  for attempt = 1, 100 do
    if move() then
      state.moves = state.moves + 1
      return true
    end

    if detect() then
      if not dig() then
        return false, "unbreakable"
      end
      state.digs = state.digs + 1
    else
      -- Nothing solid there, so something alive is standing in it.
      attack()
      sleep(0.2)
    end

    if attempt % 10 == 0 then
      sleep(0.4) -- let falling gravel settle
    end
  end

  return false, "blocked"
end

function nav.forward()
  local ok, err = push(turtle.forward, turtle.dig, turtle.detect, turtle.attack, turtle.inspect)
  if not ok then
    return false, err
  end
  state.x = state.x + DELTA[state.facing].x
  state.z = state.z + DELTA[state.facing].z
  save()
  return true
end

--- Retreat one block without turning and without digging.
--- Used to unwind after stepping into a vein: the space behind is the one we
--- just came out of, so it is always clear.
function nav.back()
  if not turtle.back() then
    return false, "blocked"
  end
  state.moves = state.moves + 1
  state.x = state.x - DELTA[state.facing].x
  state.z = state.z - DELTA[state.facing].z
  save()
  return true
end

function nav.up()
  local ok, err = push(turtle.up, turtle.digUp, turtle.detectUp, turtle.attackUp, turtle.inspectUp)
  if not ok then
    return false, err
  end
  state.y = state.y + 1
  save()
  return true
end

function nav.down()
  local ok, err =
    push(turtle.down, turtle.digDown, turtle.detectDown, turtle.attackDown, turtle.inspectDown)
  if not ok then
    return false, err
  end
  state.y = state.y - 1
  save()
  return true
end

--- Dig the block below without moving. Refuses lava, which we leave sealed
--- rather than flooding the pit, and refuses chests and computers.
function nav.digDown()
  local refusal = refuses(turtle.inspectDown)
  if refusal then
    return false, refusal
  end
  if turtle.digDown() then
    state.digs = state.digs + 1
    save()
  end
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

--- Walk to a job-relative coordinate.
--- Rises before travelling and descends last, so the turtle crosses air it has
--- already mined rather than tunnelling through fresh rock on the way back.
function nav.goTo(tx, ty, tz)
  while state.y < ty do
    local ok, err = nav.up()
    if not ok then
      return false, err
    end
  end

  if state.x ~= tx then
    nav.face(state.x < tx and 1 or 3)
    while state.x ~= tx do
      local ok, err = nav.forward()
      if not ok then
        return false, err
      end
    end
  end

  if state.z ~= tz then
    nav.face(state.z < tz and 0 or 2)
    while state.z ~= tz do
      local ok, err = nav.forward()
      if not ok then
        return false, err
      end
    end
  end

  while state.y > ty do
    local ok, err = nav.down()
    if not ok then
      return false, err
    end
  end

  return true
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

--- Record where home is in the world, and which way the turtle faced when the
--- job started. `heading` is an index into nav.COMPASS.
---
--- This is what makes real world coordinates possible without GPS. The turtle
--- already knows its offset from home exactly - every move is only counted once
--- the game confirms it - so one fixed reference point is all that is missing.
function nav.setOrigin(x, y, z, heading)
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

--- Real world coordinates.
---
--- Prefers dead reckoning from a known origin over GPS, which is the opposite
--- of the obvious choice and deliberate: GPS needs four computers on plain
--- wireless modems, reports nil distance through ender modems, and is out of
--- range exactly where you need it - a turtle at Y=-59 a hundred blocks out is
--- some 330 blocks from a surface cluster. Dead reckoning costs nothing, works
--- at any depth, and is as accurate as the navigation itself.
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
