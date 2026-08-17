--- ICOS boot entry point.
---
---   splash -> automatic update -> hardware-appropriate shell
---
--- Computers get a full desktop on their own keyboard terminal and a separate
--- display-only dashboard on an attached monitor. Pocket Computers get a
--- touch-first shell, and turtles get a compact launcher. Holding a key during
--- the splash opens system tools instead, so a broken autorun can never trap
--- the machine.

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

-- Early builds offered the stationary base role to Pocket Computers. Migrate
-- those installations to the controller role so they never compete with the
-- real base for the hosted Rednet name.
if caps.kind == "pocket" and node.role == "fleet" then
  node.role = "controller"
  config.save(NODE_PATH, node)
end

local localScreen = term.current()
local screen = localScreen
local monitor, monitorName

-- Turtles and Pockets keep their own screen. A computer discovers and scales
-- its monitor for the display-only dashboard; the monitor remains the boot
-- splash target while the local terminal becomes the full desktop afterward.
if caps.kind ~= "turtle" and caps.kind ~= "pocket" and node.role ~= "gps" then
  monitor, _, _, _, monitorName = display.attach(42, 18)
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

local function runApp(apps, app, target)
  display.on(target or localScreen, function()
    ui.clear()
    apps.run(app)
  end)
end

local function systemMenu(apps, target)
  target = target or localScreen
  while true do
    local tools = apps.available(caps, node, "tools")
    local labels = {}
    for i, app in ipairs(tools) do
      labels[i] = app.name
    end
    labels[#labels + 1] = "Restart ICOS"
    labels[#labels + 1] = "Exit to CraftOS"

    local choice = display.on(target, function()
      return ui.menu((node.label or ("id " .. caps.id)) .. " system", labels)
    end)

    if not choice or choice == #labels then
      display.on(target, function()
        ui.clear()
      end)
      print("Type `startup` to start ICOS again.")
      return
    elseif choice == #labels - 1 then
      display.on(target, boot.reboot)
      return
    else
      runApp(apps, tools[choice], target)
      display.on(target, function()
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
  systemMenu(apps, localScreen)
  return
end

-- GPS hosts are infrastructure appliances, not tiny fleet bases. They run one
-- blocking beacon program on both computers and stationary Chunky Turtles.
if node.role == "gps" then
  runApp(apps, apps.byId("gps-host"), localScreen)
  systemMenu(apps, localScreen)
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

local modemStatus = caps.modem and (caps.wireless and "wireless modem" or "wired modem")
  or "NO MODEM DETECTED"
local homeMessage = ("v%s  role %s  %s"):format(boot.VERSION, node.role or "unset", modemStatus)
local homeWarning = (node.role ~= "fleet" and node.role ~= "controller") or not caps.modem

local function interfaceSession()
  if caps.kind == "pocket" then
    local handheld = require("core.handheld")
    handheld.run(localScreen, apps.available(caps, node, "handheld"), {
      name = boot.NAME,
      homeMessage = homeMessage,
      homeWarning = homeWarning,
    })
  else
    local desktop = require("core.desktop")
    local desktopApps = apps.available(caps, node, "desktop")
    if monitor then
      parallel.waitForAny(function()
        desktop.run(localScreen, desktopApps, {
          name = boot.NAME,
          autoLaunch = false,
          localInput = true,
          homeMessage = homeMessage,
          homeWarning = homeWarning,
        })
      end, function()
        desktop.run(monitor, apps.available(caps, node, "monitor"), {
          name = boot.NAME,
          autoLaunch = "fleet-status",
          localInput = false,
          monitorName = monitorName,
          homeMessage = homeMessage,
          homeWarning = homeWarning,
        })
      end)
    else
      desktop.run(screen, desktopApps, {
        name = boot.NAME,
        autoLaunch = false,
        localInput = true,
        homeMessage = homeMessage,
        homeWarning = homeWarning,
      })
    end
  end
  systemMenu(apps, localScreen)
end

if node.role == "fleet" or node.role == "controller" then
  local service = require("fleet.service")
  local serviceMain = node.role == "fleet" and service.runBase or service.runController
  local function superviseService()
    local log = require("core.log")
    while true do
      local ok, err = pcall(serviceMain)
      if not ok and not tostring(err):find("Terminated", 1, true) then
        log.error("fleet service crashed - " .. tostring(err) .. "; restarting")
      end
      sleep(2)
    end
  end
  parallel.waitForAny(superviseService, interfaceSession)
  if node.role == "fleet" then
    require("core.net").unhostBase()
  end
else
  interfaceSession()
end
