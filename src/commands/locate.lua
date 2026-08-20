--- Tell this machine where it is standing.
---
--- §4's third category: a **command** runs once, prints, and exits. No page, no
--- taskbar entry, no service. `where` was always this and was filed as an app
--- because ICOS 1 had nowhere else to put it.
---
--- ## The gap this closes
---
--- `adapters/cc/locator.lua` has read `.location` since it was written and
--- **nothing has ever written that file**. Three things depended on it and all
--- three were quietly broken:
---
---   * `os/server/services/gps.lua` is a *critical* service that raises without a
---     saved position, so every ICOS 2 server reported unhealthy. Its error message
---     said to run `where set`, a command that did not exist.
---   * `machine.capabilities().located` was therefore always false, so
---     `roles.check` would refuse every server on the grounds that it did not know
---     where it was.
---   * A general cannot claim a chunk it cannot locate, so chunk coverage could
---     never start.
---
--- ## Every device declares a position, not only turtles
---
--- §9, and it is the reason this is not `where.lua` moved. A GPS host has to know
--- exactly where it is or it lies to the whole fleet; a base needs its own chunk
--- to grow coverage outward from; a turtle needs an origin to dead-reckon from.
--- One file, one format, every machine.
---
--- ## A turtle also gets a heading, and that is the part GPS cannot do
---
--- Four loaded hosts can tell a turtle where it is. Nothing can tell it which way
--- it is facing, because a stationary turtle looks identical from every side. So
--- a turtle is asked, and the answer is written to **both** `.location` and the
--- navigator's own `.nav` in one go - two files that disagree about which way
--- home is would be a turtle mining confidently in the wrong direction.

package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("adapters.cc.config")
local host = require("domain.gps.host")
local calibrate = require("os.turtle.calibrate")
local locator = require("adapters.cc.locator")
local util = require("lib.util")

local COMPASS = { "north", "east", "south", "west" }

--- Ask the constellation, then fall back to asking the person.
---
--- GPS first because it cannot be mistyped, and it is free when it works. It
--- frequently does not - it needs four loaded hosts in range, which is exactly
--- what has not been set up yet on the machine most likely to be running this.
local function position()
  write("Checking for GPS... ")
  local x, y, z = gps.locate(2, false)
  if x then
    print("found")
    print(("GPS puts this machine at %d, %d, %d"):format(x, y, z))
    return math.floor(x), math.floor(y), math.floor(z)
  end
  print("none")

  -- Why, not just that. "none" is accurate and tells somebody nothing: the
  -- usual cause is not a broken radio but a constellation that does not exist
  -- yet, and the fix is to run this on three more machines rather than to
  -- investigate this one.
  --
  -- Every machine in ICOS hosts GPS once it knows where it is, so the four are
  -- any four - a base, a client, two parked turtles. There is no such thing as a
  -- dedicated GPS computer here, which is the part somebody coming from ICOS 1
  -- would not expect.
  print(("Trilateration needs %d machines that already"):format(host.QUORUM))
  print("know where they are. Set this one by hand, and")
  print("every machine after the fourth locates itself.")

  print("")
  print("Press F3 and read the 'Block:' line while")
  print("standing where this machine is. Enter the")
  print("COMPUTER or TURTLE block, not the modem.")
  print("")

  while true do
    write("Position as x y z: ")
    -- Through `util.coordinates`, never a `%d+` scan. ICOS v1.2.5's GPS setup
    -- used a greedy separator that could swallow the minus sign off a negative
    -- Y or Z, and the affected values could never be corrected automatically
    -- because the intended sign was unknowable.
    local px, py, pz = util.coordinates(read())
    if px and py and pz then
      return px, py, pz
    end
    printError("Three numbers, please. Example:  40 83 -1089")
  end
end

local existing = locator.new().saved()
term.clear()
term.setCursorPos(1, 1)
print("Where am I?")
print("")

if existing then
  print(
    ("Currently %d, %d, %d%s"):format(
      existing.x,
      existing.y,
      existing.z,
      existing.heading and (" facing " .. COMPASS[existing.heading + 1]) or ""
    )
  )
  print("")
end

--- A turtle finds out both numbers by itself, or not at all.
---
--- The move is the whole trick: take a fix, step one block, take another, and
--- the difference is the way it was pointing. Then step back, so a calibration
--- leaves the turtle where it was found.
---
--- **No fallback to asking.** A turtle is the machine somebody is least likely
--- to be standing next to, and the manual answer is the one that can be wrong in
--- a way nothing detects - a heading typed a quarter-turn out sends a turtle
--- away from home in a straight line, and the first anybody knows is that it
--- stopped answering. If there is no constellation, the answer is to build one,
--- and this says so rather than offering a way to guess.
if turtle then
  print("")
  write("Asking the constellation... ")

  local found, why =
    calibrate.run(require("adapters.cc.body").new(), require("adapters.cc.locator").new())

  if not found then
    print("no")
    printError(why)
    print("")
    print(("Trilateration needs %d machines that already"):format(host.QUORUM))
    print("know where they are. Set those up first; every")
    print("turtle after the fourth locates itself.")
    return
  end

  print("found")
  print(
    ("It is at %d, %d, %d facing %s."):format(found.x, found.y, found.z, COMPASS[found.heading + 1])
  )

  config.save(locator.PATH, { x = found.x, y = found.y, z = found.z, heading = found.heading })

  -- `setOrigin` resets the relative frame and the world origin in one persisted
  -- update, so a reboot cannot leave half of the recalibration applied.
  require("os.turtle.device.nav").setOrigin(found.x, found.y, found.z, found.heading)

  print("")
  print("Saved. It can dead-reckon at any depth with no")
  print("GPS cluster in range.")
  return
end

-- A computer, which has no heading to find and no way to find one.
--
-- It cannot move, so the trick a turtle uses is not available - and it does not
-- need it: a computer never dead-reckons. A position is the whole answer, and
-- somebody standing at the machine reading F3 is the only source for the first
-- four in a world.
local x, y, z = position()

config.save(locator.PATH, { x = x, y = y, z = z })

print("")
print(("Saved. This machine is at %d, %d, %d."):format(x, y, z))
print("It will host GPS from the next reboot.")
print("")
print("Run this again if the machine is ever moved.")
