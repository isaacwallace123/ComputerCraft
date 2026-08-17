--- Validated base-side mine and coordinated-quarry operations.

local coordinator = require("fleet.coordinator")
local minePlan = require("mine.plan")
local mineRegistry = require("mine.registry")

local operations = {}

local DIAMOND_TARGET_Y = -59
local QUICK_CELL_SIZE = 48
local QUICK_MAX_RING = 3
local QUICK_KEEPOUT = 64

local function integer(value)
  value = tonumber(value)
  return value and math.floor(value) or nil
end

local function mineState()
  local state = coordinator.mineState()
  local rows = mineRegistry.summary(state)
  local summary = { opened = 0, active = 0, exhausted = 0, blocks = 0, exposed = 0 }
  local opened = {}
  for _, row in ipairs(rows) do
    if not opened[row.index] then
      opened[row.index] = true
      summary.opened = summary.opened + 1
    end
    if row.holder then
      summary.active = summary.active + 1
    end
    if row.exhausted then
      summary.exhausted = summary.exhausted + 1
    end
    summary.blocks = summary.blocks + (row.blocks or 0)
  end

  -- Sectors whose shaft head is a hole in the ground right now. The one number
  -- on this screen that is a safety figure rather than a productivity one.
  local exposed = mineRegistry.exposed(state)
  summary.exposed = #exposed
  return { plan = state.plan, summary = summary, exposed = exposed }
end

local function placeMine(x, y, z)
  x, y, z = integer(x), integer(y), integer(z)
  if not (x and y and z) then
    return false, "mine coordinates must be numbers"
  end
  if math.abs(x) > 30000000 or math.abs(z) > 30000000 then
    return false, "mine coordinates exceed the world border"
  end
  if y < -63 or y > 310 then
    return false, "surface Y must be between -63 and 310"
  end
  local placed, moved = coordinator.setMine({
    centreX = x,
    centreZ = z,
    surfaceY = y,
    cruiseY = y + 8,
  })
  local message = ("mine at %d,%d,%d; %d sectors"):format(
    placed.centreX,
    placed.surfaceY,
    placed.centreZ,
    minePlan.capacity(placed)
  )
  if moved then
    message = message .. "; old sector progress cleared"
  end
  return true, message, mineState()
end

--- Configure the safe ordinary prospecting grid in one write, then atomically
--- assign Rare to every parked miner. Keeping grid placement and assignment in
--- one operation prevents setup auto-retry from launching a turtle in the brief
--- gap between setting the centre and applying the base keepout.
local function startDiamonds(fields)
  local state = coordinator.mineState()
  local placedNow = false

  if not state.plan.configured then
    local x, y, z = fields.x, fields.y, fields.z
    if x == nil or y == nil or z == nil then
      x, y, z = gps.locate(2, false)
      if not x then
        return false, "GPS unavailable; choose Enter base coordinates", mineState()
      end
    end

    x, y, z = integer(x), integer(y), integer(z)
    if not (x and y and z) then
      return false, "mine coordinates must be numbers", mineState()
    end
    if math.abs(x) > 30000000 or math.abs(z) > 30000000 then
      return false, "mine coordinates exceed the world border", mineState()
    end
    if y < -63 or y > 310 then
      return false, "surface Y must be between -63 and 310", mineState()
    end

    local minRing = minePlan.ringForKeepout({ cellSize = QUICK_CELL_SIZE }, QUICK_KEEPOUT)
    coordinator.setMine({
      centreX = x,
      centreZ = z,
      surfaceY = y,
      cruiseY = y + 8,
      cellSize = QUICK_CELL_SIZE,
      maxRing = QUICK_MAX_RING,
      minRing = minRing,
    })
    state = coordinator.mineState()
    placedNow = true
  end

  local ok, message = coordinator.assignParked("rare", { targetY = DIAMOND_TARGET_Y })
  if not ok then
    local prefix = placedNow and "mine configured; " or ""
    return false, prefix .. message, mineState()
  end

  local prefix = placedNow and "mine configured; " or ""
  return true, prefix .. message .. " at Y " .. DIAMOND_TARGET_Y, mineState()
end

function operations.perform(action, fields)
  fields = type(fields) == "table" and fields or {}
  if action == "mine_state" then
    return true, "mine state refreshed", mineState()
  elseif action == "start_diamonds" then
    return startDiamonds(fields)
  elseif action == "mine_here" then
    local x, y, z = gps.locate(2, false)
    if not x then
      return false, "base GPS unavailable; enter coordinates instead"
    end
    return placeMine(x, y, z)
  elseif action == "mine_at" then
    return placeMine(fields.x, fields.y, fields.z)
  elseif action == "mine_config" then
    local state = coordinator.mineState()
    if not state.plan.configured then
      return false, "place the mine before changing its grid"
    end
    local updates = {}
    if fields.cellSize ~= nil then
      updates.cellSize = integer(fields.cellSize)
      if not updates.cellSize or updates.cellSize < 16 or updates.cellSize > 128 then
        return false, "sector size must be 16..128"
      end
    elseif fields.maxRing ~= nil then
      updates.maxRing = integer(fields.maxRing)
      if not updates.maxRing or updates.maxRing < 1 or updates.maxRing > 8 then
        return false, "ring count must be 1..8"
      end
    elseif fields.keepout ~= nil then
      local keepout = integer(fields.keepout)
      if not keepout or keepout < 0 then
        return false, "keepout must be zero or greater"
      end
      updates.minRing = minePlan.ringForKeepout(state.plan, keepout)
      if updates.minRing > state.plan.maxRing then
        return false, "keepout exceeds the grid; increase ring count first"
      end
    else
      return false, "no mine setting supplied"
    end
    local placed, cleared = coordinator.setMine(updates)
    local message = ("grid: %d-block sectors, %d total, %d-block keepout"):format(
      placed.cellSize,
      minePlan.capacity(placed),
      minePlan.keepout(placed)
    )
    if cleared then
      message = message .. "; old sector progress cleared"
    end
    return true, message, mineState()
  elseif action == "quarry" then
    local x1, z1 = integer(fields.x1), integer(fields.z1)
    local x2, z2 = integer(fields.x2), integer(fields.z2)
    local topY, bottomY = integer(fields.topY), integer(fields.bottomY)
    if not (x1 and z1 and x2 and z2 and topY and bottomY) then
      return false, "quarry needs six numeric bounds"
    end
    topY, bottomY = math.max(topY, bottomY), math.min(topY, bottomY)
    if
      math.abs(x1) > 30000000
      or math.abs(x2) > 30000000
      or math.abs(z1) > 30000000
      or math.abs(z2) > 30000000
    then
      return false, "quarry coordinates exceed the world border"
    end
    if topY > 319 or topY < -63 or bottomY > 318 or bottomY < -64 then
      return false, "quarry Y bounds exceed the build range"
    end
    return coordinator.quarry({
      x1 = x1,
      z1 = z1,
      x2 = x2,
      z2 = z2,
      topY = topY,
      bottomY = bottomY,
    })
  end
  return false, "unknown operation " .. tostring(action)
end

return operations
