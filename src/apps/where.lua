--- Tell this turtle where it is standing, so the fleet can report real world
--- coordinates instead of job-relative ones.
---
--- Run it once per turtle, standing where the turtle is. It only needs saying
--- again if you physically move the turtle to a new home.
---
--- Why this instead of GPS: a GPS cluster is four computers on plain wireless
--- modems (ender modems report nil distance, so they cannot host), and even
--- then a turtle at Y=-59 a hundred blocks out is far outside wireless range.
--- The turtle already tracks its offset from home exactly - it only ever needs
--- one fixed reference point, and you can read that off F3 in five seconds.

package.path = "/?.lua;/?/init.lua;" .. package.path

if not turtle then
  printError("This is a turtle program.")
  return
end

local ui = require("core.ui")
local nav = require("turtle.nav")

ui.clear()
print("Where am I?\n")

local existing = nav.origin()
if existing then
  print(
    ("Currently: %d, %d, %d facing %s\n"):format(
      existing.x,
      existing.y,
      existing.z,
      nav.COMPASS[existing.heading + 1]
    )
  )
end

-- GPS is still worth a try: if a cluster happens to be in range it saves the
-- typing, and it cannot be wrong.
write("Checking for GPS... ")
local located = nil
if not nav.hasOrigin() then
  located = nav.worldPosition()
end
print(located and "found" or "none")
print("")

local x, y, z

if located then
  x, y, z = located.x, located.y, located.z
  print(("GPS puts this turtle at %d, %d, %d\n"):format(x, y, z))
else
  print("Press F3 and read the 'Block:' line while")
  print("standing where the turtle is.\n")

  local answer = ui.ask("Position as  x y z", nil)
  local px, py, pz = tostring(answer):match("(-?%d+)%D+(-?%d+)%D+(-?%d+)")
  if not px then
    printError("Could not read three numbers from that.")
    print("Example:  40 83 -1089")
    return
  end
  x, y, z = tonumber(px), tonumber(py), tonumber(pz)
end

print("")
print("F3 also shows 'Facing'. Which way is the")
print("TURTLE pointing? (its screen faces you, so")
print("it points the opposite way to your view)")
print("")

local heading = ui.menu("Turtle faces", nav.COMPASS)
if not heading then
  ui.clear()
  print("Cancelled - nothing changed.")
  return
end

-- `setOrigin` resets the relative frame and world origin in one persisted
-- update, so a reboot cannot leave half of the recalibration applied.
nav.setOrigin(x, y, z, heading - 1)

ui.clear()
print("Saved.\n")
print(("Home is %d, %d, %d facing %s"):format(x, y, z, nav.COMPASS[heading]))
print("")
print("The dashboard will now show real coordinates,")
print("at any depth, with no GPS cluster needed.")
