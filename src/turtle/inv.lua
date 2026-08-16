--- Inventory helpers.

local inv = {}

function inv.freeSlots()
  local free = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then
      free = free + 1
    end
  end
  return free
end

function inv.isFull()
  return inv.freeSlots() == 0
end

function inv.itemCount()
  local total = 0
  for slot = 1, 16 do
    total = total + turtle.getItemCount(slot)
  end
  return total
end

--- Drop everything, by default in front. Pass `turtle.dropDown` to empty into a
--- chest underneath instead - which is facing-independent, and so the only
--- reliable option for a turtle that was placed by another turtle.
--- Returns how many items left the inventory: the dashboard's "delivered".
function inv.dropAll(dropFn)
  dropFn = dropFn or turtle.drop
  local before = inv.itemCount()
  local selected = turtle.getSelectedSlot()

  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      dropFn()
    end
  end

  turtle.select(selected)
  return before - inv.itemCount()
end

--- Throw away everything `isJunk` says is worthless, in place.
---
--- This is what makes long-range mining viable at all: a round trip from
--- diamond level a hundred blocks out costs ~250 moves each way, so a turtle
--- that came home every time it filled up with deepslate would spend its whole
--- fuel budget commuting. Returns how many items were dropped.
function inv.dropJunk(isJunk)
  local dropped = 0
  local selected = turtle.getSelectedSlot()

  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail and isJunk(detail.name) then
      turtle.select(slot)
      local count = turtle.getItemCount(slot)
      turtle.drop()
      dropped = dropped + (count - turtle.getItemCount(slot))
    end
  end

  turtle.select(selected)
  return dropped
end

--- Registry names to counts, for a "what did it actually find" readout.
function inv.summary()
  local counts = {}
  for slot = 1, 16 do
    local detail = turtle.getItemDetail(slot)
    if detail then
      counts[detail.name] = (counts[detail.name] or 0) + detail.count
    end
  end
  return counts
end

return inv
