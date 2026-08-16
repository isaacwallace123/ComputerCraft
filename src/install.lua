--- Give this machine a role.
---
--- Detects what it is and what is plugged into it, then offers only the roles
--- that machine can actually perform - a computer with no modem is never asked
--- whether it wants to be the base station. Roles that will work but are
--- missing something useful are offered with the caveat spelled out.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local net = require("core.net")
local boot = require("core.boot")
local sound = require("core.sound")
local device = require("core.device")
local config = require("core.config")
local version = require("core.version")

local NODE_PATH = ".node"

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
os.pullEvent("key")

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
  suggested = role.key == "fleet" and "base" or (role.key .. "-" .. caps.id)
end

node.label = ui.ask("Name this machine", suggested)
os.setComputerLabel(node.label)

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
      ui.text(2, line + 1, "Run `fleet` on the base computer.", ui.theme.dim)
    end
  end
elseif role.key == "fleet" and not caps.modem then
  ui.text(2, line, "No modem: this base cannot hear turtles.", ui.theme.bad)
end

sound.play("ready")

ui.text(2, line + 3, "Done. Rebooting...", ui.theme.fg)
sleep(1.2)
boot.reboot()
