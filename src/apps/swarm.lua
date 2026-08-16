--- Swarm deployer: plant a line of mining turtles, then eat them back up.
---
--- Load this turtle with turtle items and chests, run `swarm deploy`, and it
--- walks out planting a chest with a worker turtle on top of it every `spacing`
--- blocks. Each worker boots into its own startup, registers with the fleet,
--- and gets to work. `swarm reclaim` walks the same line, empties every chest,
--- digs up every worker and chest, and brings the lot home.
---
--- Why chest-underneath rather than chest-behind: a turtle placed by another
--- turtle ends up facing a direction we cannot control, so "drop behind me" is
--- a coin flip. "Drop below me" always hits the chest it is standing on. That
--- is also why every mining job empties downwards.
---
--- What this is NOT: turtles crafting brand new turtles out of ore they mined.
--- That needs smelting, and turtles cannot smelt. These are pre-built turtles
--- being carried, placed, and picked back up - their computer ID and their
--- whole filesystem survive the round trip, so a reclaimed turtle redeployed
--- later is still configured.

package.path = "/?.lua;/?/init.lua;" .. package.path

if not turtle then
  printError("This is a turtle program.")
  return
end

local ui = require("core.ui")
local log = require("core.log")
local config = require("core.config")
local nav = require("turtle.nav")
local inv = require("turtle.inv")
local fuel = require("turtle.fuel")

local STATE_PATH = ".swarm"

local state = config.load(STATE_PATH, {
  spacing = 6, -- blocks between workers
  planted = 0, -- how many are currently out there
})

local mode = ({ ... })[1]

--- First slot holding an item whose name contains `pattern`.
local function findSlot(pattern)
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail and tostring(detail.name):find(pattern, 1, true) then
      return slot
    end
  end
  return nil
end

local function countItems(pattern)
  local total = 0
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail and tostring(detail.name):find(pattern, 1, true) then
      total = total + detail.count
    end
  end
  return total
end

--- Plant one worker to the right of the current position: chest at ground
--- level, turtle sitting on top of it.
local function plantOne()
  local chestSlot = findSlot("chest")
  local turtleSlot = findSlot("turtle")
  if not chestSlot or not turtleSlot then
    return false, "out of chests or turtles"
  end

  nav.turnRight()

  turtle.select(chestSlot)
  if not turtle.place() then
    turtle.dig() -- something in the way; clear it and retry once
    if not turtle.place() then
      nav.turnLeft()
      return false, "could not place chest"
    end
  end

  if not nav.up() then
    nav.turnLeft()
    return false, "no headroom to place the turtle"
  end

  turtle.select(turtleSlot)
  if not turtle.place() then
    turtle.dig()
    if not turtle.place() then
      nav.down()
      nav.turnLeft()
      return false, "could not place turtle"
    end
  end

  nav.down()
  nav.turnLeft()
  return true
end

--- Undo plantOne: empty the chest, pick up the worker, pick up the chest.
local function reclaimOne()
  nav.turnRight()

  if not nav.up() then
    nav.turnLeft()
    return false, "blocked above"
  end
  turtle.dig() -- the worker turtle
  nav.down()

  -- Empty the chest before breaking it, or its contents scatter and despawn.
  local grabbed = turtle.suck()
  while grabbed do
    grabbed = turtle.suck()
  end
  turtle.dig() -- the chest

  nav.turnLeft()
  return true
end

--- Walk `distance` blocks along the line, digging through anything in the way.
local function advance(distance)
  for _ = 1, distance do
    if not nav.forward() then
      return false
    end
  end
  return true
end

local function deploy()
  local turtles = countItems("turtle")
  local chests = countItems("chest")
  local planned = math.min(turtles, chests)

  ui.clear()
  print("Swarm deploy\n")
  print(("turtles  %d"):format(turtles))
  print(("chests   %d"):format(chests))
  print(("spacing  %d blocks"):format(state.spacing))
  print("")

  if planned == 0 then
    printError("Need at least one turtle and one chest.")
    return
  end

  -- Out and back along the line, plus a margin for digging through terrain.
  local needed = planned * state.spacing * 2 + 200
  print(("Fuel: %d needed, %d aboard"):format(needed, fuel.level()))
  if not fuel.refuelTo(needed) then
    printError("Not enough fuel. Add coal and run again.")
    return
  end

  print("")
  print("Planting " .. planned .. " workers. Ctrl+T to stop.")
  sleep(1)

  nav.setHome()
  state.planted = 0

  for i = 1, planned do
    if not advance(state.spacing) then
      log.warn("blocked after " .. state.planted .. " workers")
      break
    end

    local ok, err = plantOne()
    if not ok then
      log.warn("stopped planting: " .. tostring(err))
      break
    end

    state.planted = i
    config.save(STATE_PATH, state)
    log.info("planted worker " .. i)
    print(("  %d/%d planted"):format(i, planned))
  end

  print("\nReturning home...")
  nav.goHome()

  ui.clear()
  print(("Planted %d workers, %d blocks apart."):format(state.planted, state.spacing))
  print("")
  print("They boot into their own startup and join the fleet.")
  print("Press G on the base to send them all mining.")
end

local function reclaim()
  ui.clear()
  print("Swarm reclaim\n")

  if state.planted == 0 then
    printError("No planted workers on record.")
    print("Nothing to reclaim.")
    return
  end

  print(("Collecting %d workers..."):format(state.planted))
  local needed = state.planted * state.spacing * 2 + 200
  fuel.refuelTo(needed)
  print("")

  local collected = 0
  for i = 1, state.planted do
    if not advance(state.spacing) then
      log.warn("blocked on the way to worker " .. i)
      break
    end

    local ok, err = reclaimOne()
    if ok then
      collected = collected + 1
      print(("  %d/%d collected"):format(collected, state.planted))
    else
      log.warn("worker " .. i .. ": " .. tostring(err))
    end

    if inv.freeSlots() == 0 then
      log.warn("inventory full, heading home early")
      break
    end
  end

  print("\nReturning home...")
  nav.goHome()
  inv.dropAll(turtle.dropDown)

  state.planted = math.max(0, state.planted - collected)
  config.save(STATE_PATH, state)

  ui.clear()
  print(("Collected %d workers into the chest below."):format(collected))
  if state.planted > 0 then
    print(state.planted .. " still unaccounted for.")
  end
end

if mode == "deploy" then
  deploy()
elseif mode == "reclaim" then
  reclaim()
else
  local choice = ui.menu("Swarm", {
    "Deploy workers",
    "Reclaim workers (" .. state.planted .. " out)",
    "Set spacing (" .. state.spacing .. ")",
  })

  if choice == 1 then
    deploy()
  elseif choice == 2 then
    reclaim()
  elseif choice == 3 then
    ui.clear()
    state.spacing = ui.askNumber("Blocks between workers", state.spacing)
    config.save(STATE_PATH, state)
    print("Saved.")
  end
end
