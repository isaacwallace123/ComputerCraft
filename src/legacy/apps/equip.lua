--- Swap a modem onto this turtle without losing the pickaxe.
---
--- A turtle has two upgrade slots. A mining turtle with a modem has both full,
--- so fitting an ender modem means replacing the old one - and `turtle.equipX`
--- happily swaps out whatever is already on that side, pickaxe included. Do it
--- by hand on the wrong side and the turtle can no longer mine.
---
--- This finds the side that currently holds a modem and replaces only that one.
--- If no modem is equipped it asks, because a pickaxe and an empty slot are
--- indistinguishable from Lua - neither reports as a peripheral.

package.path = "/?.lua;/?/init.lua;" .. package.path

if not turtle then
  printError("This is a turtle program.")
  return
end

local ui = require("legacy.shell.ui")

--- Which inventory slot holds a modem, if any.
local function findModemInInventory()
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail and tostring(detail.name):find("modem") then
      return slot, detail.name
    end
  end
  return nil
end

--- A modem is a peripheral, so it is visible by side. A pickaxe is a tool and
--- reports nothing at all - which is why an empty side looks identical.
local function equippedModemSide()
  for _, side in ipairs({ "left", "right" }) do
    if peripheral.hasType(side, "modem") then
      return side
    end
  end
  return nil
end

ui.clear()
print("Turtle upgrades\n")

for _, side in ipairs({ "left", "right" }) do
  local kind = peripheral.getType(side)
  print(("  %-6s %s"):format(side, kind or "tool or empty"))
end
print("")

local slot, itemName = findModemInInventory()
if not slot then
  printError("No modem in the turtle's inventory.")
  print("Put the ender modem in any slot and run this again.")
  return
end

print("Found " .. itemName .. " in slot " .. slot .. ".\n")

local side = equippedModemSide()

if side then
  print("Replacing the modem on the " .. side .. " side.")
else
  printError("No modem is currently equipped.")
  print("One side holds the pickaxe, and Lua cannot tell which.")
  print("Equipping over the pickaxe would leave the turtle unable")
  print("to mine, so pick carefully.\n")

  local choice = ui.menu("Which side is FREE?", { "left", "right", "cancel" })
  if not choice or choice == 3 then
    ui.clear()
    print("Cancelled. Nothing changed.")
    return
  end
  side = choice == 1 and "left" or "right"
end

turtle.select(slot)
local equip = side == "left" and turtle.equipLeft or turtle.equipRight

local ok, err = equip()
if not ok then
  printError("Could not equip: " .. tostring(err))
  return
end

print("")
print("Equipped on the " .. side .. " side.")

local swapped = turtle.getItemDetail(slot)
if swapped then
  print("The old " .. swapped.name .. " is now in slot " .. slot .. ".")
  print("Take it out before starting a job.")
end

print("")
print("Reboot (Ctrl+R) so the new modem is picked up.")
