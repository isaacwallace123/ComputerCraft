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
ui.header("Geo Scan", "r=" .. radius)

if #rows == 0 then
  ui.text(2, 3, "Nothing but rock within " .. radius .. " blocks.", ui.theme.dim)
  return
end

local _, height = ui.size()
ui.text(2, 3, ("%-20s %5s  %s"):format("ORE", "COUNT", "NEAREST"), ui.theme.dim)

local row = 4
for _, entry in ipairs(rows) do
  if row >= height then
    break
  end
  ui.text(
    2,
    row,
    ("%-20s %5d  %d,%d,%d"):format(util.fit(entry.name, 20), entry.count, entry.x, entry.y, entry.z)
  )
  row = row + 1
end

term.setCursorPos(1, height)
