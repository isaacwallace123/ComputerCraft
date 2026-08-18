--- Emptying a haul into whatever containers are actually at home.
---
--- The convention is one chest directly below the home block, and that stays the
--- convention: it is orientation-independent, which matters because a turtle
--- placed by another turtle faces an unpredictable direction. But one chest also
--- means one full chest ends an unattended run, and "depot full" parking the
--- whole fleet is the single most common way a night of mining stops early.
---
--- So below is tried first and the neighbours afterwards. Nothing is ever
--- dropped in a direction with no container in it: `turtle.drop` into open air
--- scatters the haul on the floor and reports success, which would turn a full
--- chest into a lost load.

local inv = require("device.inv")

local depot = {}

--- Block names that accept items. Deliberately a substring list so modded
--- barrels, crates, and drawers work without being enumerated.
local CONTAINERS = {
  "chest",
  "barrel",
  "shulker_box",
  "drawer",
  "crate",
  "_box",
  "hopper",
  "storage",
}

function depot.isContainer(name)
  name = tostring(name or "")
  for _, pattern in ipairs(CONTAINERS) do
    if name:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function container(inspect)
  local ok, data = inspect()
  return ok and type(data) == "table" and depot.isContainer(data.name)
end

--- Ordered so the chest below home is always emptied into first.
---
--- Built on call rather than at load: this module is required from shared code
--- that also runs on computers, where the `turtle` API does not exist.
local function sides()
  return {
    { inspect = turtle.inspectDown, drop = turtle.dropDown, name = "below" },
    { inspect = turtle.inspect, drop = turtle.drop, name = "in front" },
    { inspect = turtle.inspectUp, drop = turtle.dropUp, name = "above" },
  }
end

--- Empty everything `keep` does not accept into adjacent containers.
---
--- Returns how many items were delivered, how many could not be placed, and
--- which sides were used. A non-zero remainder is the real "depot full": every
--- container the turtle can reach without moving is out of space.
function depot.unload(keep)
  local delivered = 0
  local used = {}

  local function outstanding()
    return inv.itemCount(function(detail, slot)
      return not keep(detail, slot)
    end)
  end

  for _, side in ipairs(sides()) do
    if outstanding() > 0 and container(side.inspect) then
      local moved = inv.dropAllExcept(keep, side.drop)
      if moved > 0 then
        delivered = delivered + moved
        used[#used + 1] = side.name
      end
    end
  end

  return delivered, outstanding(), used
end

return depot
