--- Fuel accounting and economical refuelling.
--- Knows nothing about where the turtle is - see turtle/nav.
---
--- What counts as fuel is a closed list, not a question for the game; see
--- `turtle/fuel/catalog`. Everything treated as fuel is kept through every
--- unload, so a permissive answer here quietly turns into slots full of sticks.

local catalog = require("device.fuel.catalog")
local fuel = {}

-- Runtime values learned by consuming one accepted fuel whose burn time is not
-- in the catalog. Deliberately not persisted: a modpack update may change it.
local measured = {}

--- Fuel as a number. Turtles report the string "unlimited" when fuel is turned
--- off server-side, which would blow up any numeric comparison.
function fuel.level()
  local level = turtle.getFuelLevel()
  if level == "unlimited" then
    return math.huge
  end
  return level
end

function fuel.limit()
  local limit = turtle.getFuelLimit()
  if limit == "unlimited" then
    return math.huge
  end
  return limit
end

--- 0..1, for a progress bar. Unlimited reads as full.
function fuel.fraction()
  local limit = fuel.limit()
  if limit == math.huge or limit == 0 then
    return 1
  end
  return fuel.level() / limit
end

local function withSlot(slot, action)
  local selected = turtle.getSelectedSlot()
  turtle.select(slot)
  local results = table.pack(action())
  turtle.select(selected)
  return table.unpack(results, 1, results.n)
end

function fuel.itemValue(detail)
  if not detail or not catalog.accepts(detail.name) then
    return nil
  end
  return measured[detail.name] or catalog.value(detail.name)
end

--- Is this something the fleet burns?
---
--- Coal and charcoal, loose or in block form, and nothing else. This used to ask
--- the game with `turtle.refuel(0)`, which answers yes for sticks, saplings,
--- planks, and wooden tools. Everything that answers yes is retained at unload,
--- so a turtle that cut through a canopy on the way down carried the resulting
--- litter for the rest of its life in slots meant for ore.
---
--- The second argument is the caller's slot. It is accepted and ignored: the
--- answer no longer depends on asking the game about a particular stack, and
--- keeping the signature means no call site has to change.
function fuel.isFuel(detail, _)
  return detail ~= nil and catalog.accepts(detail.name)
end

--- Fuel still stored as inventory items. An accepted fuel whose burn time this
--- build does not know - a modded charcoal block - is retained and burnable but
--- conservatively contributes zero until one has been measured by refuelling.
function fuel.inventoryPotential()
  local total = 0
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    local value = fuel.itemValue(detail)
    if detail and value then
      total = total + detail.count * value
    end
  end
  return total
end

--- Every move the turtle can fund: tank plus burnable inventory.
function fuel.available()
  local level = fuel.level()
  if level == math.huge then
    return math.huge
  end
  return level + fuel.inventoryPotential()
end

--- One coherent read for dashboards and network telemetry.
---
--- Calling `level`, `available`, and `fraction` separately scans the inventory
--- twice and asks for the tank several times. Status is rendered frequently, so
--- expose all four values from one inventory pass instead.
function fuel.snapshot()
  local level = fuel.level()
  local limit = fuel.limit()
  local reserve = fuel.inventoryPotential()
  return {
    level = level,
    limit = limit,
    reserve = reserve,
    available = level == math.huge and math.huge or level + reserve,
    fraction = (limit == math.huge or limit == 0) and 1 or level / limit,
  }
end

local function candidates()
  local known, unknown = {}, {}
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail then
      local value = fuel.itemValue(detail)
      if value then
        known[#known + 1] = { slot = slot, detail = detail, value = value }
      elseif fuel.isFuel(detail, slot) then
        unknown[#unknown + 1] = { slot = slot, detail = detail }
      end
    end
  end
  table.sort(known, function(a, b)
    return a.value < b.value
  end)
  return known, unknown
end

local function burnOne(candidate)
  local before = fuel.level()
  local ok = withSlot(candidate.slot, function()
    return turtle.refuel(1)
  end)
  if not ok then
    return false
  end

  local after = fuel.level()
  if not candidate.value and after < fuel.limit() and after > before then
    measured[candidate.detail.name] = after - before
  end
  return true
end

--- Burn inventory items until `target` is in the tank. Smaller fuels go first,
--- minimising overshoot while blocks and lava remain compact long-term reserve.
function fuel.refuelTo(target)
  target = math.min(target, fuel.limit())
  if fuel.level() >= target then
    return true
  end

  while fuel.level() < target do
    local known, unknown = candidates()
    local remaining = target - fuel.level()
    local choice = nil

    -- Prefer the largest item which fits exactly inside the requested top-up;
    -- otherwise the smallest item is the least wasteful overshoot.
    for _, candidate in ipairs(known) do
      if candidate.value <= remaining then
        choice = candidate
      elseif not choice then
        choice = candidate
        break
      end
    end

    choice = choice or unknown[1]
    if not choice or not burnOne(choice) then
      return false
    end
  end

  return fuel.level() >= target
end

--- Movement uses one fuel. Load it lazily, preserving everything else aboard.
function fuel.ensureMove()
  return fuel.level() == math.huge or fuel.level() >= 1 or fuel.refuelTo(1)
end

return fuel
