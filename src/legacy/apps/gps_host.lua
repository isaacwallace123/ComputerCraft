--- Dedicated GPS host role: one coordinate beacon and nothing else.

package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("adapters.cc.config")
local ui = require("legacy.shell.ui")

local host = config.load(".gps", {})
local x = tonumber(host.x)
local y = tonumber(host.y)
local z = tonumber(host.z)

ui.clear()
ui.header("ICOS GPS HOST", "starting")

if not (x and y and z) then
  ui.text(2, 3, "Position is not configured.", ui.theme.bad)
  ui.text(2, 5, "Hold a key during boot, then choose", ui.theme.dim)
  ui.text(2, 6, "Setup / change role.", ui.theme.dim)
  return
end

local modemName = nil
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.hasType(name, "modem") then
    local modem = peripheral.wrap(name)
    if modem and modem.isWireless() then
      modemName = name
      break
    end
  end
end

if not modemName then
  ui.text(2, 3, "No wireless or Ender modem found.", ui.theme.bad)
  ui.text(2, 5, "Attach a modem and reboot.", ui.theme.dim)
  return
end

ui.clear()
ui.header("ICOS GPS HOST", "online")
ui.text(2, 3, ("Position  %d, %d, %d"):format(x, y, z), ui.theme.accent)
ui.text(2, 4, "Modem     " .. modemName, ui.theme.dim)
ui.text(2, 6, "Serving GPS requests.", ui.theme.good)
ui.text(2, 8, "Hold a key during boot for setup/tools.", ui.theme.dim)
term.setCursorPos(1, 10)

local ran = shell.run("gps", "host", tostring(x), tostring(y), tostring(z))
if ran == false then
  printError("GPS host stopped unexpectedly.")
end
