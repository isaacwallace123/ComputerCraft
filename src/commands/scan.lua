--- List nearby ores, using an Advanced Peripherals Geo Scanner.
---
--- §4's second category. `scan` was filed as an app because it scrolled, and it
--- scrolled because ICOS 1's shell had no scrollback - so a page that printed
--- forty rows lost the first thirty. A command prints, and CC's own terminal
--- keeps the rest, which is less code and works on every surface including a
--- turtle's thirteen rows.
---
--- Everything that decides anything is in `domain/mine/survey.lua`: what counts
--- as an ore, what "nearest" means, and how rows are ranked. This finds the
--- peripheral and prints.
---
---     scan          eight blocks
---     scan 16       sixteen
---
--- Coordinates are relative to the scanner: +x east, +y up, +z south.

package.path = "/?.lua;/?/init.lua;" .. package.path

local format = require("ui.format")
local survey = require("domain.mine.survey")
local util = require("lib.util")

-- Advanced Peripherals renamed this type in 1.21.1 and this pack is 1.20.1, so
-- both names are tried rather than the pack version being assumed.
local scanner = peripheral.find("geoScanner") or peripheral.find("geo_scanner")

if not scanner then
  printError("No Geo Scanner found.")
  print("")
  print("Attach a Geo Scanner block to this computer, or use")
  print("a turtle with the Geo Scanner upgrade equipped on")
  print("the left or right side.")
  return
end

local radius = math.floor(tonumber(({ ... })[1] or "") or 8)

local blocks, scanError = scanner.scan(radius)
if not blocks then
  printError("Scan failed: " .. tostring(scanError))
  print("Geo Scanners have a cooldown between scans.")
  print("Wait a few seconds and run it again.")
  return
end

local rows = survey.summarise(blocks)

print(("Geo scan, radius %d - %d ore type%s"):format(radius, #rows, #rows == 1 and "" or "s"))
print("")

if #rows == 0 then
  print("Nothing but rock nearby.")
  return
end

-- Printed rather than drawn, so a wide monitor and a turtle both get something
-- readable and neither needs a layout pass. `format.pad` because Lua's
-- `string.format` has no dynamic width specifier.
local width = term.getSize()
local nameWidth = math.max(10, math.min(22, width - 18))

for _, row in ipairs(rows) do
  print(
    ("%s %s  %d,%d,%d"):format(
      format.pad(util.blockName(row.name), nameWidth),
      format.pad(tostring(row.count), 4, "right"),
      row.x,
      row.y,
      row.z
    )
  )
end
