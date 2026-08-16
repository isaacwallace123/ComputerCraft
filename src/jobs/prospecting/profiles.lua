--- Ore-selection profiles for focused prospecting jobs.

local profiles = {}

local COMMON = { "iron", "copper", "zinc", "andesite" }
local FUEL = { "coal_ore" }

local function contains(name, patterns)
  name = tostring(name)
  for _, pattern in ipairs(patterns) do
    if name:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function isOre(name)
  return tostring(name):find("_ore", 1, true) ~= nil
    or tostring(name):find("ancient_debris", 1, true) ~= nil
end

function profiles.matcher(profile, extraPatterns)
  extraPatterns = extraPatterns or {}
  return function(name)
    if contains(name, extraPatterns) then
      return true
    end
    if profile == "fuel" then
      return contains(name, FUEL)
    elseif profile == "resources" then
      return contains(name, COMMON)
    elseif profile == "rare" then
      return isOre(name) and not contains(name, COMMON) and not contains(name, FUEL)
    end
    return isOre(name)
  end
end

return profiles
