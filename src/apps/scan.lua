--- List nearby ores using an Advanced Peripherals Geo Scanner.
---
--- Works with the Geo Scanner block on a computer or the Geo Scanner turtle
--- upgrade. Turns blind quarrying into pointing the pit at ground worth digging.
---
--- Coordinates are relative to the scanner: +x east, +y up, +z south.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local util = require("core.util")

-- Advanced Peripherals renamed this type in 1.21.1; this pack is 1.20.1.
local scanner = peripheral.find("geoScanner") or peripheral.find("geo_scanner")

if not scanner then
  printError("No Geo Scanner found.")
  print("")
  print("Attach a Geo Scanner block to this computer, or use a")
  print("turtle with the Geo Scanner upgrade on left or right.")
  return
end

local radius = tonumber(({ ... })[1] or "") or 8

local blocks, err = scanner.scan(radius)
if not blocks then
  printError("Scan failed: " .. tostring(err))
  print("Geo Scanners have a cooldown between scans - wait and retry.")
  return
end

--- Match on the name so modded ores are picked up too, which matters in a pack
--- this size.
local function isInteresting(name)
  return name:find("ore") or name:find("debris") or name:find("raw_")
end

local found = {}

for _, block in ipairs(blocks) do
  if isInteresting(block.name) then
    local distance = math.abs(block.x) + math.abs(block.y) + math.abs(block.z)
    local entry = found[block.name]
    if not entry then
      found[block.name] = { count = 1, x = block.x, y = block.y, z = block.z, distance = distance }
    else
      entry.count = entry.count + 1
      if distance < entry.distance then
        entry.x, entry.y, entry.z, entry.distance = block.x, block.y, block.z, distance
      end
    end
  end
end

local rows = {}
for name, entry in pairs(found) do
  entry.name = util.blockName(name)
  rows[#rows + 1] = entry
end
table.sort(rows, function(a, b)
  return a.count > b.count
end)

ui.clear()
local scroll = 0
local running = true

local function draw()
  local width, height = ui.size()
  local compact = width < 40
  local capacity = math.max(1, math.floor((height - 3) / (compact and 2 or 1)))
  scroll = math.max(0, math.min(scroll, math.max(0, #rows - capacity)))

  ui.clear()
  ui.header("Geo Scan", ("r=%d %d ore"):format(radius, #rows))
  if #rows == 0 then
    ui.text(2, 3, "Nothing but rock nearby.", ui.theme.dim)
  elseif compact then
    for slot = 1, capacity do
      local entry = rows[scroll + slot]
      if not entry then
        break
      end
      local y = 2 + (slot - 1) * 2
      ui.text(2, y, ui.pad(entry.name, width - 9), ui.theme.fg)
      ui.text(math.max(2, width - 6), y, ui.pad(entry.count, 5, "right"), ui.theme.accent)
      ui.text(3, y + 1, ("at %d,%d,%d"):format(entry.x, entry.y, entry.z), ui.theme.dim)
    end
  else
    local tableRows = {}
    for index = scroll + 1, math.min(#rows, scroll + capacity) do
      local entry = rows[index]
      tableRows[#tableRows + 1] = {
        cells = { entry.name, entry.count, ("%d,%d,%d"):format(entry.x, entry.y, entry.z) },
      }
    end
    ui.table(2, 2, width - 2, {
      { title = "ORE", width = 20 },
      { title = "COUNT", width = 5, align = "right" },
      { title = "NEAREST", width = 11 },
    }, tableRows, capacity)
  end
  ui.footer("up/down scroll  Q close")
end

draw()
while running do
  local event = { os.pullEvent() }
  if event[1] == "icos_close" then
    running = false
  elseif event[1] == "key" then
    if event[2] == keys.q then
      running = false
    elseif event[2] == keys.up then
      scroll = math.max(0, scroll - 1)
    elseif event[2] == keys.down then
      scroll = scroll + 1
    end
  elseif event[1] == "mouse_scroll" then
    scroll = math.max(0, scroll + event[2])
  elseif event[1] == "mouse_click" and event[4] == select(2, ui.size()) then
    local width = ui.size()
    scroll = math.max(0, scroll + (event[3] <= width / 2 and -1 or 1))
  end
  draw()
end

ui.clear()
