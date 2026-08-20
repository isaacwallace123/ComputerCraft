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
local console = require("os.kernel.console")
local locator = require("adapters.cc.locator")
local prompt = require("os.kernel.prompt")
local util = require("lib.util")

local COMPASS = { "north", "east", "south", "west" }

--- Which way this machine points, chosen rather than typed.
---
--- `prompt.choose` is what `commands/setup.lua` uses, and this asked for a
--- number instead - so the one question in the fleet with four possible answers
--- was the one place somebody could type a fifth. Arrow keys, a highlight band,
--- and a click all work; every other prompt in the system behaves this way and
--- there was no reason this one did not.
---
--- Returns a heading 0-3, or nil if they backed out. Cancelling means "change
--- nothing", which the caller has to be able to act on: a `locate` that wrote a
--- heading somebody declined to give would be worse than one that gave up.
local function heading(screen)
  local entries = {}
  for _, name in ipairs(COMPASS) do
    entries[#entries + 1] = { label = name }
  end

  -- A turtle's screen faces the person reading it, so it points away from them -
  -- the single most confusing thing about this question, and it belongs above
  -- the list rather than after it.
  --
  -- Thirty-six characters, because `console:panelLine` pads to `width - 2` and a
  -- turtle is thirty-nine wide - so a longer sentence is not a longer sentence,
  -- it is a truncated one, and the half that gets cut is the half that explains
  -- the trap.
  local chosen = prompt.choose(screen, entries, {
    title = "Which way is it pointing?",
    note = "F3 shows Facing. Turtles point away.",
  })

  return chosen and chosen - 1 or nil
end

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

local x, y, z = position()

local facing = nil
if turtle then
  -- Built here rather than at the top of the file: a computer never asks this,
  -- and constructing a console it will not draw on would be a screen adapter
  -- wrapped around `term` for nothing.
  facing = heading(console.new(require("adapters.cc.screen").new(term)))

  if facing == nil then
    -- Backed out. The position is still worth having and the heading is the half
    -- that cannot be guessed, so nothing is written: a `.location` with a
    -- heading somebody declined to give is a turtle mining confidently in the
    -- wrong direction.
    term.clear()
    term.setCursorPos(1, 1)
    printError("Cancelled - nothing was saved.")
    return
  end

  term.clear()
  term.setCursorPos(1, 1)
end

-- Written before the navigator, so a crash between the two leaves a machine that
-- knows where it is and not one that has moved its own origin without saying so.
config.save(locator.PATH, { x = x, y = y, z = z, heading = facing })

if turtle then
  -- `setOrigin` resets the relative frame and the world origin in one persisted
  -- update, so a reboot cannot leave half of the recalibration applied.
  require("os.turtle.device.nav").setOrigin(x, y, z, facing)
end

print("")
print(("Saved. This machine is at %d, %d, %d."):format(x, y, z))
if facing then
  print(("It faces %s, so it can dead-reckon at any"):format(COMPASS[facing + 1]))
  print("depth with no GPS cluster in range.")
end
print("")
print("Run this again if the machine is ever moved.")
