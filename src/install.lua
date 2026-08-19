--- Give this machine a role.
---
--- Detects what it is and what is plugged into it, then offers only the roles
--- that machine can actually perform - a computer with no modem is never asked
--- whether it wants to be the base station. Roles that will work but are
--- missing something useful are offered with the caveat spelled out.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("legacy.shell.ui")
local net = require("legacy.net")
local boot = require("legacy.boot")
local sound = require("adapters.cc.sound")
local device = require("legacy.device")
local config = require("adapters.cc.config")
local util = require("lib.util")
local version = require("lib.version")

local NODE_PATH = ".node"
local GPS_PATH = ".gps"

local node = config.load(NODE_PATH, {
  role = nil,
  label = nil,
  job = nil,
  parked = false,
  autoUpdate = true,
})

local caps = device.capabilities()

ui.clear()
ui.header(boot.NAME .. " setup")
local line = 3
for _, text in ipairs(device.describe(caps)) do
  ui.text(2, line, text, ui.theme.dim)
  line = line + 1
end
ui.text(2, line + 1, "Press any key to choose a role.", ui.theme.fg)
while true do
  local event = { os.pullEvent() }
  if event[1] == "key" or event[1] == "mouse_click" then
    break
  end
end

local roles = device.roles(caps)
local labels = {}
for i, role in ipairs(roles) do
  labels[i] = role.label
end

local picked = ui.menu("What is this machine for?", labels)
if not picked then
  ui.clear()
  print("Cancelled.")
  return
end

local role = roles[picked]
node.role = role.key

ui.clear()
ui.header(role.label)
ui.text(2, 3, role.detail or "", ui.theme.dim)

local warning = role.warn and role.warn(caps)
if warning then
  ui.text(2, 5, "Note: " .. warning, ui.theme.warn)
end

term.setCursorPos(1, warning and 7 or 5)

local suggested = node.label
if not suggested then
  suggested = role.key == "fleet" and "base"
    or (role.key == "controller" and "handheld" or (role.key .. "-" .. caps.id))
end

node.label = ui.ask("Name this machine", suggested)
os.setComputerLabel(node.label)

if role.key == "gps" then
  local saved = config.load(GPS_PATH, {})
  local default = nil
  if saved.x ~= nil and saved.y ~= nil and saved.z ~= nil then
    default = ("%d %d %d"):format(saved.x, saved.y, saved.z)
  end

  while true do
    ui.clear()
    ui.header("GPS HOST POSITION")
    ui.text(2, 3, "Use F3 Targeted Block on this machine.", ui.theme.dim)
    ui.text(2, 4, "Enter the COMPUTER/TURTLE block, not modem.", ui.theme.dim)
    term.setCursorPos(1, 6)
    local answer = ui.ask("Position as x y z", default)
    local x, y, z = util.coordinates(answer)
    if
      x
      and y
      and z
      and math.abs(x) <= 30000000
      and math.abs(z) <= 30000000
      and y >= -64
      and y <= 319
    then
      local confirmed = ui.menu("CONFIRM GPS POSITION", { "Save this position", "Re-enter" }, {
        ("X %d"):format(x),
        ("Y %d"):format(y),
        ("Z %d"):format(z),
      })
      if confirmed == 1 then
        config.save(GPS_PATH, { x = x, y = y, z = z })
        break
      end
      default = ("%d %d %d"):format(x, y, z)
    else
      printError("Enter three valid Minecraft block coordinates.")
      sleep(1.2)
    end
  end
end

node.autoUpdate = ui.menu("Auto-update on every boot?", { "Yes (recommended)", "No" }) ~= 2
config.save(NODE_PATH, node)

ui.clear()
ui.header(node.label, role.key)
line = 3

if role.key == "miner" then
  if not net.open() then
    ui.text(2, line, "No modem: it will mine, but nothing tracks it.", ui.theme.warn)
  else
    ui.text(2, line, "Looking for the base station...", ui.theme.dim)
    local baseId = net.findBase()
    if baseId then
      ui.text(2, line, ("Registered with base station %d."):format(baseId), ui.theme.good)
      net.broadcast(
        "hello",
        { label = node.label, role = "miner", phase = "installed", version = version }
      )
    else
      ui.text(2, line, "No base station yet - it will keep looking.", ui.theme.dim)
      ui.text(2, line + 1, "Start ICOS on the fleet base.", ui.theme.dim)
    end
  end
elseif role.key == "fleet" and not caps.modem then
  ui.text(2, line, "No modem: this base cannot hear turtles.", ui.theme.bad)
elseif role.key == "controller" then
  local baseId = net.findBase()
  ui.text(
    2,
    line,
    baseId and ("Connected to fleet base " .. tostring(baseId) .. ".")
      or "Base not found yet - it will keep looking.",
    baseId and ui.theme.good or ui.theme.dim
  )
elseif role.key == "gps" then
  local host = config.load(GPS_PATH, {})
  ui.text(
    2,
    line,
    ("GPS host configured at %d, %d, %d."):format(host.x, host.y, host.z),
    ui.theme.good
  )
end

sound.play("ready")

ui.text(2, line + 3, "Done. Rebooting...", ui.theme.fg)
sleep(1.2)
boot.reboot()
