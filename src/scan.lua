--- scan.lua - list nearby ores using an Advanced Peripherals Geo Scanner.
---
--- Works with either the Geo Scanner block (attached to a computer) or the Geo
--- Scanner turtle upgrade. Tells you where the ore actually is so you can point
--- a quarry at ground worth digging instead of guessing.
---
--- Coordinates are relative to the scanner: +x east, +y up, +z south.

local ui = require("lib.ui")

-- Advanced Peripherals renamed this type in 1.21.1; this pack is 1.20.1.
local scanner = peripheral.find("geoScanner") or peripheral.find("geo_scanner")

if not scanner then
  printError("No Geo Scanner found.")
  print("")
  print("Attach a Geo Scanner block to this computer, or use a turtle")
  print("with the Geo Scanner upgrade on its left or right side.")
  return
end

local radius = tonumber(({ ... })[1] or "") or 8

local blocks, err = scanner.scan(radius)
if not blocks then
  printError("Scan failed: " .. tostring(err))
  print("Geo Scanners have a cooldown between scans - wait and retry.")
  return
end

--- Anything worth walking to. Matching on the name covers modded ores too,
--- which is what matters in a pack this size.
local function isInteresting(name)
  return name:find("ore") or name:find("debris") or name:find("raw_")
end

local found = {}

for _, block in ipairs(blocks) do
  if isInteresting(block.name) then
    local entry = found[block.name]
    local distance = math.abs(block.x) + math.abs(block.y) + math.abs(block.z)
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
  entry.name = name:gsub("^.*:", ""):gsub("_", " ")
  rows[#rows + 1] = entry
end
table.sort(rows, function(a, b)
  return a.count > b.count
end)

ui.header("Geo Scan  r=" .. radius)

if #rows == 0 then
  term.setCursorPos(3, 3)
  term.write("Nothing but rock within " .. radius .. " blocks.")
  return
end

term.setCursorPos(2, 3)
term.write(("%-18s %4s  %s"):format("ORE", "N", "NEAREST"))

local line = 4
for _, entry in ipairs(rows) do
  if line >= ui.height then
    break
  end
  term.setCursorPos(2, line)
  term.write(
    ("%-18s %4d  %d,%d,%d"):format(entry.name:sub(1, 18), entry.count, entry.x, entry.y, entry.z)
  )
  line = line + 1
end

term.setCursorPos(1, ui.height)
