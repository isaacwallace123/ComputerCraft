--- startup.lua - runs automatically every time the computer boots.
---
--- Keep this as a launcher rather than putting real logic in it. If a program
--- here crashes you still land back in this menu instead of a dead computer,
--- and "Exit to shell" is always one keypress away.
---
--- On a turtle with an unfinished quarry this hands straight over to quarry.lua,
--- which is what makes a job survive a server restart: the world reloads, the
--- turtle reboots, and it walks back to work on its own.

local ui = require("lib.ui")
local config = require("lib.config")

local isTurtle = turtle ~= nil

--- Run a program in a protected call so a crash cannot kill the menu.
local function launch(program)
  ui.clear()
  local ok, err = pcall(dofile, program)
  if not ok and not tostring(err):find("Terminated") then
    ui.clear()
    printError(program .. " crashed:")
    printError(tostring(err))
  end
  print("\nPress any key to return to the menu.")
  os.pullEvent("key")
end

-- Unfinished quarry? Resume it before doing anything else. quarry.lua gives you
-- five seconds to interrupt, so this is not a trap.
if isTurtle and fs.exists(".quarry") then
  local job = config.load(".quarry", { active = false })
  if job.active then
    launch("quarry.lua")
  end
end

local entries = {}

if isTurtle then
  entries[#entries + 1] = { label = "Quarry", program = "quarry.lua" }
else
  entries[#entries + 1] = { label = "Door lock", program = "door.lua" }
  entries[#entries + 1] = { label = "Redstone pulse", program = "pulse.lua" }
end

entries[#entries + 1] = { label = "Scan for ore", program = "scan.lua" }
entries[#entries + 1] = { label = "Update from GitHub", program = "update.lua" }

while true do
  local labels = {}
  for i, entry in ipairs(entries) do
    labels[i] = entry.label
  end
  labels[#labels + 1] = "Exit to shell"

  local title = (isTurtle and "Turtle " or "Computer ") .. os.getComputerID()
  local choice = ui.menu(title, labels)

  if choice == nil or choice > #entries then
    ui.clear()
    print("Type `startup` to come back to the menu.")
    return
  end

  launch(entries[choice].program)
end
