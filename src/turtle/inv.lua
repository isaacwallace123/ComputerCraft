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

--- Drop everything in front. Returns how many items left the inventory, which
--- is what the dashboard counts as "delivered".
function inv.dropAll()
  local before = inv.itemCount()
  local selected = turtle.getSelectedSlot()

  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      turtle.drop()
    end
  end

  turtle.select(selected)
  return before - inv.itemCount()
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
