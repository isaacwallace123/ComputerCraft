--- startup.lua - runs automatically every time the computer boots.
---
--- Keep this as a launcher rather than putting real logic in it. If a program
--- here crashes you still land back in this menu instead of a dead computer,
--- and "Exit to shell" is always one keypress away.

local ui = require("lib.ui")

local entries = {
  { label = "Door lock", program = "door.lua" },
  { label = "Redstone pulse", program = "pulse.lua" },
  { label = "Update from GitHub", program = "update.lua" },
}

--- Run a program in a protected call so a crash cannot kill the menu.
local function launch(program)
  ui.clear()
  local ok, err = pcall(dofile, program)
  if not ok then
    -- "Terminated" just means the player pressed Ctrl+T. Not worth a scary screen.
    if tostring(err):find("Terminated") then
      return
    end
    ui.clear()
    printError(program .. " crashed:")
    printError(tostring(err))
    print("\nPress any key to return to the menu.")
    os.pullEvent("key")
  else
    print("\nPress any key to return to the menu.")
    os.pullEvent("key")
  end
end

while true do
  local labels = {}
  for i, entry in ipairs(entries) do
    labels[i] = entry.label
  end
  labels[#labels + 1] = "Exit to shell"

  local choice = ui.menu("Computer " .. os.getComputerID(), labels)

  if choice == nil or choice > #entries then
    ui.clear()
    print("Type `startup` to come back to the menu.")
    return
  end

  launch(entries[choice].program)
end
