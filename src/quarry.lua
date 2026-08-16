--- quarry.lua - digs a rectangular pit and brings everything home.
---
--- SETUP
---   1. Place the turtle where you want the near-left corner of the pit.
---   2. Put a chest DIRECTLY BEHIND it.
---   3. Give it coal or charcoal in any slot.
---   4. Run `quarry`. The pit extends forward and to the right.
---
--- The turtle will not take a step it cannot walk back from: before every move
--- it checks that its remaining fuel still covers the trip home, and it burns
--- coal it mines along the way. If it runs dry anyway it walks home and stops
--- rather than stranding itself in a hole.
---
--- Progress is written to disk continuously, so a server restart, a chunk
--- unload, or you pressing Ctrl+T does not lose the job - startup.lua picks it
--- straight back up.

if not turtle then
  printError("This is a turtle program. Run it on a mining turtle.")
  return
end

local ui = require("lib.ui")
local nav = require("lib.nav")
local config = require("lib.config")

local JOB_PATH = ".quarry"

-- Spare fuel kept on top of the distance home, to cover the moves it takes to
-- notice a problem and the detour round anything in the way.
local SAFETY_MARGIN = 64

local defaults = {
  width = 8, -- blocks to the right
  length = 8, -- blocks forward
  depth = 32, -- blocks down
  layer = 0, -- progress: layers already finished
  active = false,
}

local job = config.load(JOB_PATH, defaults)

--- Each pass clears the level the turtle walks along plus the one beneath it.
local function travelLevel(layer)
  return -(1 + 2 * layer)
end

local function totalLayers()
  return math.ceil(job.depth / 2)
end

local function saveJob()
  config.save(JOB_PATH, job)
end

local function freeSlots()
  local free = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then
      free = free + 1
    end
  end
  return free
end

--- Tip the inventory into the chest behind the start block. Assumes we are home.
local function dumpIntoChest()
  nav.face(2)
  for slot = 1, 16 do
    turtle.select(slot)
    turtle.drop()
  end
  turtle.select(1)
  nav.face(0)
end

--- Mid-layer trip: walk home, empty out, come back to the exact block we left
--- off at. Fuel is topped up first, so coal in the haul gets a chance to become
--- range rather than sitting in a chest.
local function unload()
  local x, y, z, facing = nav.position()

  nav.refuel(nav.fuel() + 1000)

  local ok, err = nav.goHome()
  if not ok then
    return false, err
  end

  dumpIntoChest()

  ok, err = nav.goTo(x, y, z)
  if not ok then
    return false, err
  end
  nav.face(facing)
  return true
end

--- End-of-layer trip: walk home, empty out, and stay there. The next layer
--- always starts from home, which is what makes an interrupted job resumable -
--- whatever odd corner the turtle rebooted in, it walks back and starts over.
local function finishLayer()
  local ok, err = nav.goHome()
  if not ok then
    return false, err
  end
  dumpIntoChest()
  return true
end

--- Guard every step: enough fuel to get home, and somewhere to put the ore.
local function checkpoint()
  local needed = nav.distanceHome() + SAFETY_MARGIN
  if nav.fuel() < needed and not nav.refuel(needed + 500) then
    return false, "out of fuel"
  end

  if freeSlots() == 0 then
    local ok, err = unload()
    if not ok then
      return false, "could not unload: " .. tostring(err)
    end
  end

  return true
end

local function advance()
  local ok, err = checkpoint()
  if not ok then
    return false, err
  end
  return nav.forward()
end

--- Clear the block below the travel level, which is the second of the two
--- layers this pass is responsible for.
local function mineDown()
  local ok, data = turtle.inspectDown()
  if ok and tostring(data.name):find("lava") then
    return true -- leave it sealed rather than flooding the pit
  end
  turtle.digDown()
  return true
end

--- Boustrophedon sweep: up one column, shuffle sideways, back down the next.
local function sweepLayer()
  local right = true

  for column = 1, job.width do
    for cell = 1, job.length do
      mineDown()
      if cell < job.length then
        local ok, err = advance()
        if not ok then
          return false, err
        end
      end
    end

    if column < job.width then
      local turn = right and nav.turnRight or nav.turnLeft
      turn()
      local ok, err = advance()
      if not ok then
        return false, err
      end
      mineDown()
      turn()
      right = not right
    end
  end

  return true
end

local function descendToLayer(layer)
  local target = travelLevel(layer)
  while select(2, nav.position()) > target do
    local ok, err = nav.down()
    if not ok then
      return false, err
    end
  end
  return true
end

local function drawStatus(message)
  ui.header("Quarry")
  local x, y, z = nav.position()
  term.setCursorPos(3, 3)
  term.write(("area    %dx%d, %d deep"):format(job.width, job.length, job.depth))
  term.setCursorPos(3, 4)
  term.write(("layer   %d / %d"):format(job.layer, totalLayers()))
  term.setCursorPos(3, 5)
  term.write(("at      %d, %d, %d"):format(x, y, z))
  term.setCursorPos(3, 6)
  term.write(("fuel    %s  (home is %d away)"):format(tostring(turtle.getFuelLevel()), nav.distanceHome()))
  term.setCursorPos(3, 8)
  term.write(message or "")
  ui.footer("Ctrl+T to stop - progress is saved")
end

--- Ask for the pit dimensions. Only runs for a fresh job.
local function setup()
  ui.header("New Quarry")
  print("Chest goes directly BEHIND the turtle.")
  print("The pit runs forward and to the right.\n")

  local function ask(prompt, current)
    write(prompt .. " [" .. current .. "]: ")
    local answer = tonumber(read() or "")
    return answer and math.floor(answer) or current
  end

  job.width = ask("Width (right)", job.width)
  job.length = ask("Length (forward)", job.length)
  job.depth = ask("Depth (down)", job.depth)
  job.layer = 0
  job.active = true

  nav.setHome()
  saveJob()
end

local function run()
  while job.layer < totalLayers() do
    -- Always start a layer from home. On a resume the turtle could have
    -- rebooted anywhere, so this is what gets it back on the rails.
    drawStatus("returning to start")
    local ok, err = nav.goHome()
    if not ok then
      return false, err
    end

    drawStatus("descending")
    ok, err = descendToLayer(job.layer)
    if not ok then
      if err == "unbreakable" then
        drawStatus("hit bedrock - finishing")
        break
      end
      return false, err
    end

    drawStatus("mining layer " .. (job.layer + 1))
    ok, err = sweepLayer()
    if not ok then
      return false, err
    end

    ok, err = finishLayer()
    if not ok then
      return false, err
    end

    job.layer = job.layer + 1
    saveJob()
  end

  return true
end

-- A job left active means we were interrupted. Carry on from where we stopped.
if job.active then
  ui.header("Quarry")
  print("Unfinished job found: layer " .. job.layer .. " of " .. totalLayers() .. ".\n")
  print("Resuming in 5s. Press any key to start a new one instead.")

  local timer = os.startTimer(5)
  local resume = true
  while true do
    local event, id = os.pullEvent()
    if event == "timer" and id == timer then
      break
    elseif event == "key" then
      resume = false
      break
    end
  end

  if not resume then
    -- Walk back to the old home before forgetting where it was.
    print("\nReturning home first...")
    nav.goHome()
    setup()
  end
else
  setup()
end

local ok, err = run()

drawStatus(ok and "done - heading home" or ("stopped: " .. tostring(err)))
if nav.goHome() then
  dumpIntoChest()
end

if ok then
  job.active = false
  saveJob()
end

ui.clear()
if ok then
  print("Quarry complete. " .. totalLayers() .. " layers, everything in the chest.")
else
  printError("Quarry stopped: " .. tostring(err))
  print("Progress is saved - run `quarry` again to resume.")
end
