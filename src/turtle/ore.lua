--- Deciding what is worth mining, and following a vein once one is found.
---
--- Two different vocabularies are in play and mixing them up is the classic bug
--- here. `turtle.inspect` reports BLOCK names ("minecraft:deepslate_iron_ore"),
--- but the inventory holds DROPS ("minecraft:raw_iron"). So detection matches
--- block names and junk-dropping matches item names, and the two lists look
--- nothing like each other.

local ore = {}

--- Blocks worth stopping for. Matching on substrings rather than an exact list
--- means modded ores in a pack this size are picked up for free.
local ORE_PATTERNS = {
  "_ore",
  "ancient_debris",
}

--- Extra blocks that are not ores but you still want. Create needs a lot of
--- andesite, and it is common at depth.
ore.DEFAULT_EXTRAS = { "andesite" }

--- Build a predicate over BLOCK names.
function ore.matcher(extras)
  extras = extras or ore.DEFAULT_EXTRAS

  return function(name)
    name = tostring(name)
    for _, pattern in ipairs(ORE_PATTERNS) do
      if name:find(pattern, 1, true) then
        return true
      end
    end
    for _, pattern in ipairs(extras) do
      if name:find(pattern, 1, true) then
        return true
      end
    end
    return false
  end
end

--- ITEM names that are never worth hauling 100 blocks home. Anything not listed
--- is kept, so an unrecognised modded drop errs towards being brought back.
ore.JUNK = {
  "cobbled_deepslate",
  "cobblestone",
  "deepslate",
  "blackstone",
  "netherrack",
  "granite",
  "diorite",
  "tuff",
  "calcite",
  "smooth_basalt",
  "basalt",
  "dripstone",
  "rooted_dirt",
  "dirt",
  "gravel",
  "flint",
  "sand",
  "andesite", -- removed from this list when extras include andesite
}

--- Never drop these, whatever else the rules say - they are the fuel.
local FUEL = {
  "minecraft:coal",
  "minecraft:charcoal",
  "minecraft:coal_block",
  "minecraft:lava_bucket",
  "minecraft:blaze_rod",
}

local function isFuel(name)
  for _, fuelName in ipairs(FUEL) do
    if name == fuelName then
      return true
    end
  end
  return false
end

--- Build a predicate over ITEM names: true means "throw this away".
--- Anything in `keep` is removed from the junk list, so asking to keep andesite
--- does the right thing without editing the list itself.
function ore.junkMatcher(keep)
  keep = keep or ore.DEFAULT_EXTRAS

  return function(name)
    name = tostring(name)
    if isFuel(name) then
      return false
    end
    for _, wanted in ipairs(keep) do
      if name:find(wanted, 1, true) then
        return false
      end
    end
    for _, junk in ipairs(ore.JUNK) do
      if name:find(junk, 1, true) then
        return true
      end
    end
    return false
  end
end

--- Follow a vein out from the turtle's current position and come back to it.
---
--- Recursion does the bookkeeping: step into an ore block, explore from there,
--- then step back the way we came. Because every branch unwinds, the turtle is
--- always standing exactly where it started when this returns - which is what
--- lets the caller carry on down a tunnel without re-navigating.
---
--- `budget` caps total blocks so a huge andesite blob cannot swallow the trip.
--- `beforeMove` applies the same recall/fuel/inventory policy as the main path.
function ore.follow(nav, isWanted, budget, record, maxDepth, beforeMove)
  maxDepth = maxDepth or 12
  local total = budget or 64
  local remaining = total
  local stoppedReason = nil
  local stoppedKind = nil
  local explore

  local function consider(inspect, moveIn, moveOut, depth)
    if remaining <= 0 or stoppedReason then
      return
    end

    local ok, data = inspect()
    if not ok or not isWanted(data.name) then
      return
    end

    if beforeMove then
      local allowed, reason, kind = beforeMove()
      if not allowed then
        stoppedReason, stoppedKind = reason, kind
        return
      end
    end

    if moveIn() then
      record(data.name)
      remaining = remaining - 1
      explore(depth + 1)
      local returned, returnError = moveOut()
      if not returned then
        stoppedReason = "could not leave vein: " .. tostring(returnError)
      end
    end
  end

  explore = function(depth)
    if depth > maxDepth or remaining <= 0 or stoppedReason then
      return
    end

    consider(turtle.inspectDown, nav.down, nav.up, depth)
    consider(turtle.inspectUp, nav.up, nav.down, depth)

    -- Four turns brings the turtle back to its original heading.
    for _ = 1, 4 do
      consider(turtle.inspect, nav.forward, nav.back, depth)
      nav.turnRight()
    end
  end

  explore(0)
  return total - remaining, stoppedReason, stoppedKind
end

return ore
