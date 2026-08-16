--- ICOS boot entry point.
---
---   splash -> automatic update -> hardware-appropriate shell
---
--- Computers get the monitor desktop. Turtles get a compact launcher, and a
--- single valid app starts immediately. Holding a key during the splash opens
--- system tools instead, so a broken autorun can never trap the machine.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local boot = require("core.boot")
local sound = require("core.sound")
local device = require("core.device")
local config = require("core.config")
local display = require("core.display")

local NODE_PATH = ".node"

local node = config.load(NODE_PATH, {
  role = nil,
  label = nil,
  job = nil,
  parked = false,
  autoUpdate = true,
})

local caps = device.capabilities()
local screen = term.current()
local monitor, monitorScale

-- Turtles keep their own compact screen. Computers promote an attached
-- monitor to the ICOS desktop and choose the largest readable scale that fits.
if caps.kind ~= "turtle" then
  monitor, monitorScale = display.attach(42, 18)
  screen = monitor or screen
end

local function onScreen(fn)
  return display.on(screen, fn)
end

local interrupted = onScreen(function()
  return boot.splash(node.label or device.KINDS[caps.kind])
end)

local function autoUpdate()
  if node.autoUpdate == false or not caps.http or not fs.exists(".update") then
    return
  end

  onScreen(function()
    ui.clear()
    ui.header(boot.NAME, "updating")
    ui.text(2, 3, "Checking for updates...", ui.theme.dim)
    term.setCursorPos(1, 5)

    local called, ran = pcall(shell.run, "update.lua", "--automatic")
    if not called or ran == false then
      ui.text(2, 5, "Update failed - running installed code.", ui.theme.warn)
      sound.play("error")
    end
    sleep(1.2)
  end)
end

local function runApp(apps, app)
  onScreen(function()
    ui.clear()
    apps.run(app)
  end)
end

local function systemMenu(apps)
  while true do
    local tools = apps.available(caps, node, "tools")
    local labels = {}
    for i, app in ipairs(tools) do
      labels[i] = app.name
    end
    labels[#labels + 1] = "Restart ICOS"
    labels[#labels + 1] = "Exit to CraftOS"

    local choice = onScreen(function()
      return ui.menu((node.label or ("id " .. caps.id)) .. " system", labels)
    end)

    if not choice or choice == #labels then
      onScreen(function()
        ui.clear()
      end)
      print("Type `startup` to start ICOS again.")
      return
    elseif choice == #labels - 1 then
      onScreen(boot.reboot)
      return
    else
      runApp(apps, tools[choice])
      onScreen(function()
        sound.blip(14)
        print("\nPress any key to return.")
        os.pullEvent("key")
      end)
      node = config.load(NODE_PATH, node)
      caps = device.capabilities()
    end
  end
end

if not node.role then
  shell.run("install.lua")
  return
end

if not interrupted then
  autoUpdate()
end

-- Load these after updating: applications are the part most likely to have
-- changed, and no reboot is needed just to pick up a new registry entry.
local apps = require("core.apps")

if interrupted then
  systemMenu(apps)
  return
end

if caps.kind == "turtle" then
  local available = apps.available(caps, node, "launcher")

  if #available == 1 then
    runApp(apps, available[1])
    return
  end

  while true do
    local labels = {}
    for i, app in ipairs(available) do
      labels[i] = app.name
    end
    labels[#labels + 1] = "System tools"

    local choice = ui.menu(boot.NAME .. " apps", labels)
    if not choice or choice == #labels then
      systemMenu(apps)
      return
    end
    runApp(apps, available[choice])
  end
end

local desktop = require("core.desktop")
local desktopApps = apps.available(caps, node, "desktop")

if monitor then
  ui.clear()
  ui.header(boot.NAME, "monitor desktop")
  ui.text(2, 3, ("Monitor scale %s"):format(tostring(monitorScale)), ui.theme.good)
  ui.text(2, 5, "Touch the monitor to open apps.", ui.theme.fg)
  ui.text(2, 7, "Hold Ctrl+T here to close ICOS.", ui.theme.dim)
end

desktop.run(screen, desktopApps, {
  name = boot.NAME,
  autoLaunch = false,
})

systemMenu(apps)
