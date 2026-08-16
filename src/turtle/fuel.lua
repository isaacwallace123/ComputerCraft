--- Fuel primitives. Knows nothing about where the turtle is - see turtle/nav.

local fuel = {}

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

--- Burn inventory items until we reach `target`, one item at a time so we never
--- torch a stack of 64 coal to top up by 80.
function fuel.refuelTo(target)
  if fuel.level() >= target then
    return true
  end

  local selected = turtle.getSelectedSlot()
  for slot = 1, 16 do
    turtle.select(slot)
    while fuel.level() < target do
      -- refuel(1) returns false as soon as this slot stops being fuel.
      if not turtle.refuel(1) then
        break
      end
    end
    if fuel.level() >= target then
      break
    end
  end
  turtle.select(selected)

  return fuel.level() >= target
end

return fuel
