--- Deciding what is worth mining, and following a vein once one is found.
---
--- Two different vocabularies are in play and mixing them up is the classic bug
--- here. `turtle.inspect` reports BLOCK names ("minecraft:deepslate_iron_ore"),
--- but the inventory holds DROPS ("minecraft:raw_iron"). So detection matches
--- block names and junk-dropping matches item names, and the two lists look
--- nothing like each other.

local catalog = require("turtle.fuel.catalog")

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
  -- Canopy litter. A prospecting turtle descends through whatever is above its
  -- sector, and a tree yields saplings, sticks, and seeds by the stack. None of
  -- it is worth a slot on the way down or a trip home.
  "sapling",
  "_leaves",
  "seeds",
}

--- Items matched whole rather than by substring, because the obvious substring
--- would take something valuable with it: "stick" also matches `sticky_piston`
--- and "apple" also matches `golden_apple`.
ore.JUNK_EXACT = {
  ["minecraft:stick"] = true,
  ["minecraft:apple"] = true,
  ["minecraft:wheat"] = true,
}

local function isFuel(name)
  -- Deliberately the same closed list the fuel accounting uses. A fuel this
  -- fleet does not burn is not protected from the junk policy, and a fuel it
  -- does burn is never dropped whatever else the rules say.
  return catalog.accepts(name)
end

--- ITEM names worth carrying home when the rule is "ores and metals only".
---
--- The opposite policy to `JUNK`, and used by the profiles that go a hundred
--- blocks down for diamonds. A denylist is right when most of what a turtle digs
--- is worth keeping; at Y -59 almost nothing is. A trip spent cutting trunk and
--- ribs fills up with cobble, deepslate, dirt, clay, moss, and whatever tree it
--- came through, and every one of those slots is a slot that ore cannot go in.
---
--- Matching is deliberately generous about form - `_ore`, `raw_`, `ingot`,
--- `nugget`, `gem`, `crystal`, `shard`, `dust` - because that is how modded ores
--- are named, and a pack this size adds far more of them than can be listed.
ore.KEEP = {
  "_ore",
  "raw_",
  "ingot",
  "nugget",
  "_gem",
  "gem_",
  "crystal",
  "shard",
  "_dust",
  "dust_",
  "diamond",
  "emerald",
  "lapis",
  "redstone",
  "quartz",
  "amethyst",
  "netherite",
  "debris",
  "obsidian",
  "echo",
  "gold",
  "iron",
  "copper",
  "tin",
  "lead",
  "silver",
  "nickel",
  "platinum",
  "uranium",
  "zinc",
  "osmium",
  "aluminum",
  "aluminium",
  "certus",
  "fluix",
  "apatite",
  "ruby",
  "sapphire",
  "topaz",
  "peridot",
  "sulfur",
  "niter",
  "saltpeter",
  "totem",
  "disc",
  "heart_of_the_sea",
  "nautilus",
}

--- Build a predicate over ITEM names for a "keep only what is valuable" haul.
---
--- Fuel and anything the job explicitly wants are always kept; everything else
--- has to look like ore, metal, or a gem to earn a slot. This is the reverse of
--- D012's default, and deliberately so: that rule protects unknown modded drops
--- from being binned, which is right for a general-purpose dig and wrong for a
--- turtle whose entire trip is about diamonds.
function ore.strictMatcher(keep)
  keep = keep or {}

  return function(name)
    name = tostring(name)
    if catalog.accepts(name) then
      return false
    end
    for _, wanted in ipairs(keep) do
      if name:find(wanted, 1, true) then
        return false
      end
    end
    for _, valuable in ipairs(ore.KEEP) do
      if name:find(valuable, 1, true) then
        return false
      end
    end
    return true
  end
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
    if ore.JUNK_EXACT[name] then
      return true
    end
    for _, junk in ipairs(ore.JUNK) do
      if name:find(junk, 1, true) then
        return true
      end
    end
    return false
  end
end

ore.DEFAULT_BUDGET = 256
ore.DEFAULT_RADIUS = 24
ore.DEFAULT_GAP_BUDGET = 12

--- Follow a vein out from the turtle's current position and come back to it.
---
--- Recursion does the bookkeeping: step into an ore block, explore from there,
--- then step back the way we came. Because every branch unwinds, the turtle is
--- always standing exactly where it started when this returns - which is what
--- lets the caller carry on down a tunnel without re-navigating. That property
--- is the reason this stays depth-first: a breadth-first flood fill visits cells
--- in a nicer order but has to walk back and forth across the vein to do it, and
--- on a turtle every one of those steps is a fuel unit and a tick.
---
--- Two limits replaced the old depth cap, because a depth cap is the wrong shape:
--- it stops 12 steps along a vein that may be 60 blocks long, in the one
--- direction the recursion happened to try first.
---
---   * `budget` caps blocks mined, so a huge blob cannot swallow the whole trip.
---     Hitting it sets `truncated`, which tells the caller the vein is still
---     there and worth coming back for.
---   * `radius` caps how far from the entry point the turtle may wander, which is
---     what actually keeps it near its tunnel.
---
--- `gapBudget` buys the other half of the problem. Large 1.18 ore veins are
--- deliberately noisy: clusters sit one block apart, joined diagonally or not at
--- all. A strict six-face fill takes one cluster and walks away from the rest of
--- the vein, which looks exactly like a turtle giving up on obvious ore. Probing
--- one block through solid stone reconnects them.
---
--- `beforeMove` applies the same recall/fuel/inventory policy as the main path.
function ore.follow(nav, isWanted, record, options)
  options = options or {}
  local total = options.budget or ore.DEFAULT_BUDGET
  local radius = options.radius or ore.DEFAULT_RADIUS
  local beforeMove = options.beforeMove
  local remaining = total
  local gapsLeft = options.gapBudget or ore.DEFAULT_GAP_BUDGET
  local stoppedReason, stoppedKind = nil, nil
  local truncated = false
  local resume = nil
  local originX, originY, originZ = nav.position()
  local explore

  local function rememberHere()
    local world = nav.worldPosition and nav.worldPosition()
    if world then
      -- World coordinates survive a legitimate `where` recalibration between
      -- trips; a relative coordinate would point somewhere else after rehoming.
      resume = { x = world.x, y = world.y, z = world.z, world = true }
    else
      local x, y, z = nav.position()
      resume = { x = x, y = y, z = z, world = false }
    end
  end

  local DELTA = {
    [0] = { x = 0, z = 1 },
    [1] = { x = 1, z = 0 },
    [2] = { x = 0, z = -1 },
    [3] = { x = -1, z = 0 },
  }

  local function candidateInRange(dx, dy, dz)
    local x, y, z = nav.position()
    return math.max(
      math.abs(x + dx - originX),
      math.abs(y + dy - originY),
      math.abs(z + dz - originZ)
    ) <= radius
  end

  local function forwardOffset()
    local _, _, _, facing = nav.position()
    return DELTA[facing].x, 0, DELTA[facing].z
  end

  local function allowed()
    if not beforeMove then
      return true
    end
    local ok, reason, kind = beforeMove()
    if not ok then
      stoppedReason, stoppedKind = reason, kind
    end
    return ok
  end

  --- Step into a wanted block, work outward from it, and come back.
  local function consider(inspect, moveIn, moveOut, offset, childMayBridge)
    if stoppedReason then
      return
    end

    local ok, data = inspect()
    if not ok or not isWanted(data.name) then
      return
    end

    -- Ore we can see but have no budget left to take. Worth saying so: the
    -- caller queues the spot for the next cycle instead of losing it.
    if remaining <= 0 then
      truncated = true
      rememberHere()
      return
    end

    local dx, dy, dz = offset()
    if not candidateInRange(dx, dy, dz) then
      return
    end
    if not allowed() then
      -- We are beside known ore but must stop before entering it. Persist this
      -- reachable cell so the next trip can revisit the unfinished branch.
      rememberHere()
      return
    end

    local moved, moveError, moveKind = moveIn()
    if not moved then
      if nav.ROUTE_AROUND[moveKind or ""] and moveKind ~= "peer" then
        -- Something we must not break is between us and this block. Leave it
        -- and keep working the rest of the vein.
        return
      end
      stoppedReason = "could not enter vein: " .. tostring(moveError)
      stoppedKind = moveKind
      rememberHere()
      return
    end

    record(data.name)
    remaining = remaining - 1
    -- The block we just entered is known ore. Gap probing may start here when
    -- the caller reached it directly from the tunnel or another ore block, but
    -- remains disabled for a cluster reached through a gap. That keeps a probe
    -- exactly one waste block deep instead of chaining across the rock.
    explore(childMayBridge, childMayBridge)

    local returned, returnError = moveOut()
    if not returned then
      stoppedReason = "could not leave vein: " .. tostring(returnError)
    end
  end

  --- Step through one block of waste to see whether the vein continues beyond.
  --- Only ever one block deep, and never chained, so this cannot turn into the
  --- turtle tunnelling through bedrock looking for hope.
  local function bridge(inspect, detect, moveIn, moveOut, offset)
    if stoppedReason or gapsLeft <= 0 or remaining <= 0 then
      return
    end
    if not detect() then
      return -- air, or already probed and found empty
    end

    local ok, data = inspect()
    if not ok or isWanted(data.name) then
      return -- handled by consider
    end

    local name = tostring(data.name)
    if name:find("lava") or name:find("computercraft:") or name:find("chest") then
      return
    end

    local dx, dy, dz = offset()
    if not candidateInRange(dx, dy, dz) then
      return
    end
    if not allowed() then
      rememberHere()
      return
    end

    gapsLeft = gapsLeft - 1
    local moved, moveError, moveKind = moveIn()
    if not moved then
      if moveKind == "peer" then
        stoppedReason = "fleet traffic blocked vein gap: " .. tostring(moveError)
        stoppedKind = moveKind
        rememberHere()
      end
      return
    end

    explore(false, false)

    local returned, returnError = moveOut()
    if not returned then
      stoppedReason = "could not leave vein: " .. tostring(returnError)
    end
  end

  --- One full six-face sweep. Ore first across every face, then - only if this
  --- cell is part of the vein proper - a second sweep that probes the gaps.
  explore = function(mayBridge, childMayBridge)
    if stoppedReason then
      return
    end

    -- When the last permitted block is mined, inspect once more before
    -- unwinding. Without this, reaching exactly zero at a leaf looks identical
    -- to finishing the vein and `truncated` is never set.
    if remaining <= 0 then
      local function wanted(inspect)
        local ok, data = inspect()
        return ok and isWanted(data.name)
      end
      local foundHere = wanted(turtle.inspectDown) or wanted(turtle.inspectUp)
      for _ = 1, 4 do
        foundHere = wanted(turtle.inspect) or foundHere
        nav.turnRight()
      end
      if foundHere then
        truncated = true
        rememberHere()
      end
      return
    end

    local down = function()
      return 0, -1, 0
    end
    local up = function()
      return 0, 1, 0
    end

    consider(turtle.inspectDown, nav.down, nav.up, down, childMayBridge)
    consider(turtle.inspectUp, nav.up, nav.down, up, childMayBridge)

    -- Four turns brings the turtle back to its original heading.
    for _ = 1, 4 do
      consider(turtle.inspect, nav.forward, nav.back, forwardOffset, childMayBridge)
      nav.turnRight()
    end

    if not mayBridge then
      return
    end

    bridge(turtle.inspectDown, turtle.detectDown, nav.down, nav.up, down)
    bridge(turtle.inspectUp, turtle.detectUp, nav.up, nav.down, up)
    for _ = 1, 4 do
      bridge(turtle.inspect, turtle.detect, nav.forward, nav.back, forwardOffset)
      nav.turnRight()
    end
  end

  -- The starting cell is ordinary tunnel, not part of a vein. Inspect it for
  -- adjacent ore, but never spend gap probes around empty trunk/rib cells. Once
  -- a real ore block is entered, `childMayBridge` enables the one-block probes.
  explore(false, true)
  return total - remaining, stoppedReason, stoppedKind, truncated, resume
end

return ore
