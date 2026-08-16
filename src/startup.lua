--- Boot entry point.
---
---   splash -> auto-update -> role app
---
--- Holding any key during the splash interrupts all of it and drops you at the
--- menu. That is the escape hatch, and the reason the splash is not skippable
--- to zero: a machine that auto-updates and auto-runs on every boot needs one
--- reliable window where you can get in and stop it.
---
--- Auto-updating here rather than inside the apps means the new code is already
--- on disk before anything loads it, so no reboot loop is needed.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local boot = require("core.boot")
local sound = require("core.sound")
local device = require("core.device")
local config = require("core.config")

local NODE_PATH = ".node"

local APPS = {
  miner = "apps/miner.lua",
  fleet = "apps/fleet.lua",
}

local node = config.load(NODE_PATH, {
  role = nil,
  label = nil,
  job = nil,
  parked = false,
  autoUpdate = true,
})

local caps = device.capabilities()
local interrupted = boot.splash(node.label or device.KINDS[caps.kind])

--- Pull new code before anything loads it. Silent on success unless something
--- actually changed, so a normal boot is not a wall of text.
local function autoUpdate()
  if node.autoUpdate == false or not caps.http or not fs.exists(".update") then
    return
  end

  ui.clear()
  ui.header(boot.NAME, "updating")
  ui.text(2, 3, "Checking for updates...", ui.theme.dim)
  term.setCursorPos(1, 5)

  local ok = pcall(shell.run, "update.lua")
  if not ok then
    ui.text(2, 5, "Update failed - running existing code.", ui.theme.warn)
    sleep(1.5)
  else
    -- update.lua leaves its verification summary on screen. Hold it long enough
    -- to actually be read before the role app paints over it.
    sleep(1.5)
  end
end

local function menu()
  while true do
    local entries = {}
    if node.role and APPS[node.role] then
      entries[#entries + 1] = { label = "Start " .. node.role, program = APPS[node.role] }
    end
    if caps.geoScanner then
      entries[#entries + 1] = { label = "Scan for ore", program = "apps/scan.lua" }
    end
    if caps.kind == "turtle" then
      entries[#entries + 1] = { label = "Set position", program = "apps/where.lua" }
      entries[#entries + 1] = { label = "Swarm deploy/reclaim", program = "apps/swarm.lua" }
      entries[#entries + 1] = { label = "Swap modem", program = "apps/equip.lua" }
    end
    entries[#entries + 1] = { label = "Update now", program = "update.lua" }
    entries[#entries + 1] = { label = "Change role", program = "install.lua" }

    local labels = {}
    for i, entry in ipairs(entries) do
      labels[i] = entry.label
    end
    labels[#labels + 1] = "Reboot"
    labels[#labels + 1] = "Exit to shell"

    local title = (node.label or ("id " .. caps.id)) .. "  [" .. tostring(node.role) .. "]"
    local choice = ui.menu(title, labels)

    if choice == nil or choice > #entries + 1 then
      ui.clear()
      print("Type `startup` to come back to this menu.")
      return
    end

    if choice == #entries + 1 then
      boot.reboot()
      return
    end

    ui.clear()
    -- shell.run rather than dofile: a crash lands back here instead of killing
    -- the menu, and the program gets its own environment.
    shell.run(entries[choice].program)
    sound.blip(14)
    print("\nPress any key to return to the menu.")
    os.pullEvent("key")
  end
end

if interrupted then
  menu()
  return
end

if not node.role then
  shell.run("install.lua")
  return
end

autoUpdate()

local app = APPS[node.role]
if not app then
  menu()
  return
end

ui.clear()
shell.run(app)
