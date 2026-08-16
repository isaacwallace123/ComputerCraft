--- nav.lua - position tracking and safe movement for turtles.
---
--- The turtle has no idea where it is. This keeps a coordinate relative to
--- wherever the job started, and writes it to disk after EVERY successful move.
--- That is the whole trick behind surviving a server restart or a chunk unload:
--- when the turtle boots back up it still knows where it stands and how to walk
--- home. Position is only ever updated after the game confirms the move, so the
--- count cannot drift.
---
--- Coordinates are job-relative: home is 0,0,0 and facing 0 is whatever
--- direction the turtle pointed when the job began. +y is up.

local config = require("lib.config")

local STATE_PATH = ".nav"

local nav = {}

-- facing 0 -> +z, 1 -> +x, 2 -> -z, 3 -> -x  (turning right increments)
local DELTA = {
  [0] = { x = 0, z = 1 },
  [1] = { x = 1, z = 0 },
  [2] = { x = 0, z = -1 },
  [3] = { x = -1, z = 0 },
}

local state = config.load(STATE_PATH, { x = 0, y = 0, z = 0, facing = 0 })

local function save()
  config.save(STATE_PATH, state)
end

--- Current position and facing.
function nav.position()
  return state.x, state.y, state.z, state.facing
end

--- Declare "here" to be home. Call this once when starting a fresh job.
function nav.setHome()
  state = { x = 0, y = 0, z = 0, facing = 0 }
  save()
end

--- Manhattan distance back to 0,0,0 - which is exactly how many moves, and so
--- how much fuel, the trip home costs.
function nav.distanceHome()
  return math.abs(state.x) + math.abs(state.y) + math.abs(state.z)
end

--- Fuel as a number. Turtles report "unlimited" when fuel is switched off
--- server-side, which would blow up any numeric comparison.
function nav.fuel()
  local level = turtle.getFuelLevel()
  if level == "unlimited" then
    return math.huge
  end
  return level
end

--- Burn items from the inventory until we hit `target`, one at a time so we
--- never torch a whole stack of coal to top up by 80.
function nav.refuel(target)
  if nav.fuel() >= target then
    return true
  end
  for slot = 1, 16 do
    turtle.select(slot)
    while nav.fuel() < target and turtle.refuel(1) do
    end
    if nav.fuel() >= target then
      break
    end
  end
  turtle.select(1)
  return nav.fuel() >= target
end

--- True if the turtle could not get home right now. The margin covers the
--- moves it takes to notice the problem in the first place.
function nav.stranded(margin)
  return nav.fuel() < nav.distanceHome() + (margin or 0)
end

local function isLava(inspect)
  local ok, data = inspect()
  return ok and type(data) == "table" and tostring(data.name):find("lava") ~= nil
end

--- Try to move, clearing whatever is in the way.
--- Gravel and sand fall back into the space, and mobs stand in it, so this
--- retries rather than giving up on the first failure. A block that will not
--- break after many attempts is bedrock or claimed territory - we stop instead
--- of grinding forever.
local function push(move, dig, detect, attack, inspect)
  if isLava(inspect) then
    return false, "lava"
  end
  for attempt = 1, 100 do
    if move() then
      return true
    end
    if detect() then
      if not dig() then
        return false, "unbreakable"
      end
    else
      -- Nothing solid there, so something alive is standing in the way.
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

function nav.up()
  local ok, err =
    push(turtle.up, turtle.digUp, turtle.detectUp, turtle.attackUp, turtle.inspectUp)
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

--- Turn to an absolute facing, taking the shorter way round.
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
--- Rises before travelling and descends last, so the turtle crosses open air
--- rather than tunnelling through fresh rock on the way back.
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

--- Return to the starting block, facing the way the turtle originally faced.
function nav.goHome()
  local ok, err = nav.goTo(0, 0, 0)
  if not ok then
    return false, err
  end
  nav.face(0)
  return true
end

return nav
