--- Fuel accounting and economical refuelling.
--- Knows nothing about where the turtle is - see turtle/nav.

local catalog = require("turtle.fuel.catalog")
local fuel = {}

-- Runtime values learned by consuming one modded fuel item. They deliberately
-- are not persisted: a modpack update may change an item's burn time.
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
  if not detail then
    return nil
  end
  return measured[detail.name] or catalog.value(detail.name)
end

--- True for vanilla and modded fuel. Passing a slot allows the authoritative
--- turtle.refuel(0) check without consuming the item.
function fuel.isFuel(detail, slot)
  if not detail then
    return false
  end
  if fuel.itemValue(detail) then
    return true
  end
  if not slot then
    return false
  end
  return withSlot(slot, function()
    return turtle.refuel(0)
  end)
end

--- Fuel still stored as inventory items. Unknown modded fuels are retained but
--- conservatively contribute zero until one has been measured by refuelling.
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
