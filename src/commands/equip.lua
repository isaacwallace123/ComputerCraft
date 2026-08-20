--- Swap a modem onto this turtle without losing the pickaxe.
---
--- §4's second category: a **command** runs once, prints, and exits. `equip` was
--- always this and was filed as an app because ICOS 1 had nowhere else to put
--- it. Nothing about the logic changed; it stopped requiring the desktop shell
--- to ask one question, which is the only reason it could not run on a turtle
--- that was not running ICOS 1.
---
--- ## Why this exists at all
---
--- A turtle has two upgrade slots. A mining turtle with a modem has both full,
--- so fitting an ender modem means *replacing* one - and `turtle.equipLeft` and
--- `turtle.equipRight` happily swap out whatever is on that side, pickaxe
--- included. Do it by hand on the wrong side and the turtle can no longer mine,
--- which is discovered when it arrives at a sector and digs nothing.
---
--- So this finds the side that already holds a modem and replaces only that one.
---
--- ## When it has to ask
---
--- A modem is a peripheral and is visible by side. **A pickaxe is a tool and
--- reports nothing at all**, so an equipped pickaxe and an empty slot are
--- indistinguishable from Lua. When no modem is equipped there is no way to tell
--- which side is safe, so the question goes to the person standing there rather
--- than being guessed - and guessing wrong costs the turtle its tool.

package.path = "/?.lua;/?/init.lua;" .. package.path

if not turtle then
  printError("This is a turtle program.")
  return
end

--- Which inventory slot holds a modem, if any.
---
--- Matched by name rather than by peripheral type, because an item in a slot is
--- not a peripheral - it only becomes one once equipped, which is the thing this
--- command exists to do.
local function modemInInventory()
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail and tostring(detail.name):find("modem") then
      return slot, detail.name
    end
  end
  return nil
end

local function equippedModemSide()
  for _, side in ipairs({ "left", "right" }) do
    if peripheral.hasType(side, "modem") then
      return side
    end
  end
  return nil
end

--- Ask which side is free, when nothing can be inferred.
---
--- Returns nil for cancel, and cancel is the default for anything unrecognised.
--- A misread answer that equipped over the pickaxe would be a turtle that looks
--- fine and mines nothing, so the safe reading of a typo is "do nothing".
local function askFreeSide()
  printError("No modem is currently equipped.")
  print("One side holds the pickaxe and Lua cannot tell")
  print("which - a tool reports no peripheral type, so an")
  print("equipped pickaxe and an empty slot look the same.")
  print("Equipping over the pickaxe leaves this turtle")
  print("unable to mine.")
  print("")
  write("Which side is FREE? [left/right/cancel]: ")

  local answer = (read() or ""):lower():match("%a+")
  if answer == "left" or answer == "l" then
    return "left"
  end
  if answer == "right" or answer == "r" then
    return "right"
  end
  return nil
end

print("Turtle upgrades")
print("")
for _, side in ipairs({ "left", "right" }) do
  print(("  %-6s %s"):format(side, peripheral.getType(side) or "tool or empty"))
end
print("")

local slot, itemName = modemInInventory()
if not slot then
  printError("No modem in the turtle's inventory.")
  print("Put the modem in any slot and run this again.")
  return
end

print(("Found %s in slot %d."):format(itemName, slot))
print("")

local side = equippedModemSide()
if side then
  print("Replacing the modem on the " .. side .. " side.")
else
  side = askFreeSide()
  if side == nil then
    print("")
    print("Cancelled. Nothing changed.")
    return
  end
end

turtle.select(slot)
local ok, err = (side == "left" and turtle.equipLeft or turtle.equipRight)()
if not ok then
  printError("Could not equip: " .. tostring(err))
  return
end

print("")
print("Equipped on the " .. side .. " side.")

local swapped = turtle.getItemDetail(slot)
if swapped then
  print(("The old %s is now in slot %d."):format(swapped.name, slot))
  print("Take it out before starting a job.")
end

print("")
print("Reboot (Ctrl+R) so the new modem is picked up.")
