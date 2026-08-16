--- Optional Advanced Peripherals Geo Scanner adapter.

local nav = require("turtle.nav")

local geo = {}

local function scanner()
  return peripheral.find("geoScanner") or peripheral.find("geo_scanner")
end

function geo.available()
  return scanner() ~= nil
end

local function insideRadius(a, b, c, radius)
  return math.abs(a) <= radius and math.abs(b) <= radius and math.abs(c) <= radius
end

local function relativeTarget(block, radius)
  if block.f ~= nil and block.r ~= nil and block.u ~= nil then
    if not insideRadius(block.f, block.r, block.u, radius) then
      return nil
    end
    return nav.scannerTarget(block.f, block.r, block.u)
  end
  if block.x ~= nil and block.y ~= nil and block.z ~= nil then
    -- Current Geo Scanner APIs report offsets. Reject anything outside the
    -- requested scan cube so an incompatible peripheral cannot send a turtle
    -- towards an absolute world coordinate by mistake.
    if not insideRadius(block.x, block.y, block.z, radius) then
      return nil
    end
    local offset = nav.worldOffsetToRelative(block.x, block.y, block.z)
    if not offset then
      return nil
    end
    local x, y, z = nav.position()
    return { x = x + offset.x, y = y + offset.y, z = z + offset.z }
  end
  return nil
end

function geo.targets(isWanted, radius, limit)
  local device = scanner()
  if not device then
    return nil, "no geo scanner"
  end

  local scan = device.scan or device.scanBlocks
  if not scan then
    return nil, "unsupported geo scanner"
  end
  local ok, blocks, reason = pcall(scan, radius)
  if not ok then
    return nil, tostring(blocks)
  end
  if type(blocks) ~= "table" then
    return nil, tostring(reason or "scan unavailable")
  end

  local found = {}
  local hereX, hereY, hereZ = nav.position()
  for _, block in ipairs(blocks) do
    if isWanted(block.name) then
      local target = relativeTarget(block, radius)
      if target then
        target.name = block.name
        target.distance = math.abs(target.x - hereX)
          + math.abs(target.y - hereY)
          + math.abs(target.z - hereZ)
        found[#found + 1] = target
      end
    end
  end
  table.sort(found, function(a, b)
    return a.distance < b.distance
  end)
  while #found > (limit or 12) do
    table.remove(found)
  end
  return found
end

return geo
