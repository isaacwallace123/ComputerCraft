--- Boot entry point. Reads this machine's role and hands over to its app.
---
--- This is what makes the fleet survive a server restart: the world reloads,
--- every turtle boots, reads its role, and goes straight back to work. The
--- three second pause is the escape hatch, so a turtle with a broken job is
--- never an unrecoverable brick.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local config = require("core.config")

local APPS = {
  miner = "apps/miner.lua",
  fleet = "apps/fleet.lua",
}

local node = config.load(".node", { role = nil, label = nil })

if not node.role then
  shell.run("install.lua")
  return
end

local app = APPS[node.role]

local function menu()
  while true do
    local entries = {}
    if app then
      entries[#entries + 1] = { label = "Start " .. node.role, program = app }
    end
    entries[#entries + 1] = { label = "Scan for ore", program = "apps/scan.lua" }
    if turtle then
      entries[#entries + 1] = { label = "Swarm deploy/reclaim", program = "apps/swarm.lua" }
      entries[#entries + 1] = { label = "Swap modem", program = "apps/equip.lua" }
    end
    entries[#entries + 1] = { label = "Update from GitHub", program = "update.lua" }
    entries[#entries + 1] = { label = "Change role", program = "install.lua" }

    local labels = {}
    for i, entry in ipairs(entries) do
      labels[i] = entry.label
    end
    labels[#labels + 1] = "Exit to shell"

    local title = (node.label or ("id " .. os.getComputerID())) .. "  [" .. node.role .. "]"
    local choice = ui.menu(title, labels)

    if choice == nil or choice > #entries then
      ui.clear()
      print("Type `startup` to come back to this menu.")
      return
    end

    ui.clear()
    -- shell.run rather than dofile: a crash lands back here instead of killing
    -- the menu, and the program gets its own environment.
    shell.run(entries[choice].program)
    print("\nPress any key to return to the menu.")
    os.pullEvent("key")
  end
end

if not app then
  menu()
  return
end

ui.clear()
ui.header(node.label or ("id " .. os.getComputerID()), node.role)
ui.text(2, 3, "Starting in 3s...", ui.theme.fg)
ui.text(2, 5, "Press any key for the menu.", ui.theme.dim)

local timer = os.startTimer(3)
while true do
  local event, id = os.pullEvent()
  if event == "timer" and id == timer then
    ui.clear()
    shell.run(app)
    return
  elseif event == "key" then
    menu()
    return
  end
end
