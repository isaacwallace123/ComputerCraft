--- Pictures, drawn once, in the only format this screen can show.
---
--- A CC character cell holds one of 32 shapes in two colours. `ui/render/canvas.lua`
--- turns that into a 2x3 pixel grid, so a 51x19 terminal is really 102x57
--- pixels - which is enough for an icon that reads as an object rather than as a
--- letter standing in for one.
---
--- These are 8x6, so each is four cells wide and two tall. That size is not a
--- guess: it is what fits above a label in a desktop tile on a 26-column Pocket
--- Computer, which is the smallest surface any of them has to survive.
---
--- ## Palette indices, not colours
---
--- A pixel is a theme token - `7` is `accent`, `9` is `good` - so every icon
--- follows the palette the rest of the system uses and a light theme recolours
--- them for free. An icon with a literal blue in it would be the one thing on
--- screen that did not.
---
--- The cost is that ores are drawn in the *nearest* token rather than their real
--- Minecraft colour: diamond is `accent` because accent is cyan, gold is `warn`
--- because warn is amber. That is close enough to tell them apart at four cells,
--- which is the whole job.
---
--- ## Why they live here and not beside the app that uses them
---
--- An icon is not owned by a page. The same diamond appears on the mine page, in
--- an ore table and in a scan result, and three copies of it would be three
--- pictures that drift.

local sprite = require("ui.render.sprite")

local icons = {}

---------------------------------------------------------------------------
-- Applications
---------------------------------------------------------------------------

--- The fleet: a turtle, seen from the front.
icons.fleet = sprite.new({
  "..0000..",
  ".000000.",
  ".077770.",
  ".077770.",
  ".000000.",
  "..0..0..",
})

--- One device among many.
icons.devices = sprite.new({
  "0000.000",
  "0..0.0.0",
  "0000.000",
  "........",
  "000.0000",
  "0.0.0..0",
})

--- A job: a pickaxe.
icons.job = sprite.new({
  "....3333",
  "...33..3",
  "..33...3",
  ".33.....",
  "33......",
  "3.......",
})

--- Services: a gear.
icons.services = sprite.new({
  "..3..3..",
  ".333333.",
  "33.33.33",
  "33.33.33",
  ".333333.",
  "..3..3..",
})

--- Logs: lines of record.
icons.logs = sprite.new({
  "3333333.",
  "........",
  "333333..",
  "........",
  "3333333.",
  "3333....",
})

--- Automation: something going round on its own.
icons.automation = sprite.new({
  "..3333..",
  ".3....3.",
  "3......3",
  "3.......",
  ".3....3.",
  "..3333..",
})

--- The mine: a shaft with a ladder in it.
icons.operations = sprite.new({
  "33333333",
  "3......3",
  "3.3333.3",
  "3.3..3.3",
  "3.3..3.3",
  "33333333",
})

--- A console: a prompt.
icons.console = sprite.new({
  "........",
  ".3......",
  "..3.....",
  ".3......",
  "........",
  ".333333.",
})

--- GPS: a beacon putting out rings.
icons.gps = sprite.new({
  "...77...",
  "..7..7..",
  ".7.77.7.",
  ".7.77.7.",
  "..7..7..",
  "...77...",
})

---------------------------------------------------------------------------
-- Ores
---------------------------------------------------------------------------

--- Ore blocks share a shape: stone with specks in it.
---
--- Built from one template rather than drawn six times, because six hand-drawn
--- rocks would be six subtly different rocks - and the thing that has to differ
--- between them is the colour, which is the argument.
local function ore(tint)
  local rows = {
    "44444444",
    "4XX444X4",
    "44XX4XX4",
    "4X444444",
    "44XXX444",
    "44444444",
  }
  local out = {}
  for index, row in ipairs(rows) do
    out[index] = row:gsub("X", tint)
  end
  return sprite.new(out)
end

icons.diamond = ore("7")
icons.emerald = ore("9")
icons.gold = ore("a")
icons.redstone = ore("b")
icons.lapis = ore("1")
icons.iron = ore("3")
icons.coal = ore("0")

--- Which icon a block name should be drawn with.
---
--- Matched on a substring rather than an exact name, for the reason
--- `domain/mine/survey.lua` matches ores that way: an exact list is accurate on
--- the day it is written and silently misses every modded ore added after it.
---
--- Returns nil rather than a default, so a caller can decide whether an unknown
--- ore gets a generic rock or no picture at all. A wrong picture is worse than
--- none - somebody reading a scan would count it as the thing it looks like.
function icons.forBlock(name)
  if type(name) ~= "string" then
    return nil
  end
  name = name:lower()

  for key, picture in pairs({
    diamond = icons.diamond,
    emerald = icons.emerald,
    gold = icons.gold,
    redstone = icons.redstone,
    lapis = icons.lapis,
    iron = icons.iron,
    coal = icons.coal,
  }) do
    if name:find(key, 1, true) then
      return picture
    end
  end

  return nil
end

--- The icon for an app id, or nil.
function icons.forApp(id)
  return icons[id]
end

return icons
