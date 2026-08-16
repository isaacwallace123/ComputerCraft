--- Persistent base-fleet log viewer. Pocket controllers display the copy sent
--- by the base service; stationary bases read their authoritative log directly.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local log = require("core.log")
local config = require("core.config")
local control = require("fleet.control")

local controller = config.load(".node", {}).role == "controller"
local scroll = 0
local running = true

local function lines()
  return controller and config.load(".fleet-log", {}) or log.readRecent(80)
end

local function draw()
  local saved = lines()
  local width, height = ui.size()
  local visible = math.max(1, height - 2)
  local maxScroll = math.max(0, #saved - visible)
  scroll = math.max(0, math.min(scroll, maxScroll))
  local first = math.max(1, #saved - visible - scroll + 1)
  local last = math.min(#saved, first + visible - 1)

  ui.clear()
  ui.header("FLEET LOG", controller and "remote" or "base")
  if #saved == 0 then
    ui.text(2, 3, "No fleet events yet.", ui.theme.dim)
  else
    local y = 2
    for index = first, last do
      local line = tostring(saved[index])
      local color = line:find("ERROR", 1, true) and ui.theme.bad
        or (line:find("WARN", 1, true) and ui.theme.warn or ui.theme.fg)
      ui.text(1, y, ui.pad(line, width), color)
      y = y + 1
    end
  end
  ui.footer("up older  down newer  Q")
end

control.requestSync()
draw()
while running do
  local event = { os.pullEvent() }
  if event[1] == "icos_close" then
    running = false
  elseif event[1] == "key" then
    if event[2] == keys.q then
      running = false
    elseif event[2] == keys.up then
      scroll = scroll + 1
    elseif event[2] == keys.down then
      scroll = math.max(0, scroll - 1)
    end
  elseif event[1] == "mouse_scroll" then
    scroll = math.max(0, scroll + event[2])
  elseif event[1] == "mouse_click" and event[4] == select(2, ui.size()) then
    local width = ui.size()
    scroll = math.max(0, scroll + (event[3] <= width / 2 and 1 or -1))
  end
  draw()
end

ui.clear()
