--- Surface access control for the shared mine's sector shafts.
---
--- A sector shaft is a one-block vertical hole from the ground down to the
--- mining depth. Reusing one hole per sector instead of one per cycle bounded
--- how many exist, but a bounded number of hundred-block drops in the ground is
--- still a set of death traps. Four holes a player can fall into is not four
--- times safer than forty; it is the same accident, waiting in four places.
---
--- So a shaft is open only while a turtle is physically inside it. On the way
--- down the turtle steps below the ground and immediately places a block over
--- its head; the whole underground trip then happens beneath a sealed surface.
--- On the way back it breaks that block from underneath, climbs through, and
--- puts it back from above before flying home.
---
--- Everything here is verified rather than assumed. A placement counts only once
--- the block is afterwards observed in position, and cap material is chosen from
--- a conservative allow list so a turtle never bricks up its own diamonds - or
--- drops sand into the hole it just made and reopens it.

local fuel = require("os.turtle.device.fuel")
local inv = require("os.turtle.device.inv")
local nav = require("os.turtle.device.nav")

local access = {}

--- Inventory slot held back for cap material.
---
--- A fixed slot rather than "whatever is aboard" because cap material and
--- tunnel waste are the same blocks: cobblestone is both the cheapest cap and
--- the first thing the junk policy throws away. Reserving one slot lets junk
--- dropping stay exactly as aggressive as it was everywhere else.
access.SLOT = 16

--- How many times one descent may spend four turns testing for a shaft wall.
--- Bounded because a cliff face beside the column would otherwise pay for the
--- test on every level of the descent.
access.PROBE_LIMIT = 16

--- How far the recorded surface may be from the plan's surface Y before an
--- upward probe refuses to believe it found the shaft head. Terrain at a distant
--- sector genuinely differs from the base's; a cave ceiling eighty blocks down
--- does not.
access.HEAD_TOLERANCE = 16

--- Persisted transition names. The cap is broken and replaced in two steps that
--- cannot be atomic, so the state names the transition rather than only its
--- endpoints. `legacy` is a job that was already underground before shafts were
--- capped and whose head position was therefore never recorded.
access.STATES = {
  unknown = true,
  legacy = true,
  sealed = true,
  opening = true,
  below = true,
  reopening = true,
  resealing = true,
}

local AIR = {
  ["minecraft:air"] = true,
  ["minecraft:cave_air"] = true,
  ["minecraft:void_air"] = true,
}

--- Names that have to be matched exactly. In 1.20.1 `minecraft:grass` is the
--- tuft and `minecraft:grass_block` is the ground it grows out of; a substring
--- test cannot separate them without throwing away the ground as well, and
--- capping on top of a tuft leaves the cap standing a block proud of the floor.
local SOFT_NAMES = {
  ["minecraft:grass"] = true,
  ["minecraft:short_grass"] = true,
  ["minecraft:tall_grass"] = true,
}

--- Blocks that exist but must never be trusted as ground or as a cap. Leaves are
--- the obvious one - a canopy is not a floor - and snow layers, crops, carpets,
--- and panes are the same mistake in a different shape.
local SOFT = {
  "leaves",
  "_log",
  "_wood",
  "_stem",
  "_hyphae",
  "_sapling",
  "vine",
  "bamboo",
  "cactus",
  "sugar_cane",
  "kelp",
  "seagrass",
  "coral",
  "_grass",
  "fern",
  "flower",
  "_carpet",
  "snow",
  "mushroom",
  "torch",
  "_sign",
  "_rail",
  "fire",
  "cobweb",
  "lily_pad",
  "_bush",
  "wheat",
  "_crop",
  "sculk_vein",
  "glow_lichen",
  "hanging_roots",
  "spore_blossom",
  "azalea",
  "_button",
  "_pressure_plate",
  "ladder",
  "scaffolding",
  "_door",
  "_pane",
  "_fence",
  "_gate",
  "chain",
  "lantern",
  "candle",
  "amethyst_cluster",
  "pointed_dripstone",
  "banner",
  "sea_pickle",
  "dead_bush",
  "cocoa",
  "berry",
  "nether_wart",
  "_head",
  "tripwire",
  "lever",
  "repeater",
  "comparator",
  "redstone_wire",
  "dripleaf",
  "pink_petals",
  "_pot",
}

--- Items that must never be spent as a cap, checked before the allow list.
--- Gravity blocks are here for a structural reason rather than a value one: sand
--- placed over a shaft falls straight down it and reopens the hole.
local NOT_FILLER = {
  "_ore",
  "raw_",
  "ingot",
  "nugget",
  "diamond",
  "emerald",
  "gold",
  "iron",
  "copper",
  "coal",
  "lapis",
  "quartz",
  "redstone",
  "glowstone",
  "amethyst",
  "netherite",
  "debris",
  "bucket",
  "shulker",
  "computercraft",
  "chest",
  "barrel",
  "turtle",
  "pickaxe",
  "shovel",
  "sword",
  "_axe",
  "_hoe",
  "modem",
  "disk",
  "echo_shard",
  "sand",
  "gravel",
  "concrete_powder",
  "anvil",
  "dragon_egg",
  "spawner",
  "egg",
  "_seeds",
  "sapling",
  "leaves",
  "ice",
  "obsidian",
  "book",
  "map",
  "totem",
}

--- Ordinary worthless stone and dirt, which is what a cap should be made of.
local FILLER = {
  "cobblestone",
  "deepslate",
  "stone",
  "tuff",
  "calcite",
  "granite",
  "diorite",
  "andesite",
  "basalt",
  "blackstone",
  "netherrack",
  "dirt",
  "grass_block",
  "podzol",
  "mycelium",
  "mud",
  "terracotta",
  "moss_block",
  "dripstone_block",
}

local function matches(name, patterns)
  for _, pattern in ipairs(patterns) do
    if name:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

--- Turn an inspect result into one of air/liquid/protected/soft/solid.
---
--- Only `solid` may be treated as ground or as a finished cap. The split matters
--- because each other answer needs a different response: a liquid cannot be
--- capped at all, a protected block must not be touched, and a soft block is
--- something to dig through and keep looking.
function access.classify(ok, data)
  if not ok or type(data) ~= "table" then
    return "air", "minecraft:air"
  end

  local name = tostring(data.name)
  if AIR[name] then
    return "air", name
  end
  if name:find("water", 1, true) or name:find("lava", 1, true) then
    return "liquid", name
  end
  if name:find("bubble_column", 1, true) then
    return "liquid", name
  end
  if
    name:find("computercraft:", 1, true)
    or name:find("chest", 1, true)
    or name:find("barrel", 1, true)
  then
    return "protected", name
  end
  if SOFT_NAMES[name] or matches(name, SOFT) then
    return "soft", name
  end
  return "solid", name
end

function access.above()
  return access.classify(turtle.inspectUp())
end

function access.below()
  return access.classify(turtle.inspectDown())
end

function access.ahead()
  return access.classify(turtle.inspect())
end

--- Is the turtle standing in a one-block column with solid walls on all sides?
---
--- This is how a shaft dug by an older build is recognised. Such a shaft never
--- reports ground downwards - the hole runs all the way to the mining depth -
--- but it does report walls, and the level at which the column becomes enclosed
--- is exactly the old shaft head.
---
--- Always performs the full four turns so the turtle ends on its original
--- facing regardless of the answer.
function access.enclosed()
  local walled = true
  for _ = 1, 4 do
    if access.ahead() ~= "solid" then
      walled = false
    end
    nav.turnRight()
  end
  return walled
end

--- May this item be spent as a cap?
---
--- `isWanted` is the job's own ore matcher. Passing it means a profile that
--- collects andesite never walls a shaft up with andesite, without this module
--- needing to know which profile is running.
function access.isFiller(detail, slot, isWanted)
  if not detail then
    return false
  end
  local name = tostring(detail.name)
  if matches(name, NOT_FILLER) then
    return false
  end
  if not matches(name, FILLER) then
    return false
  end
  if isWanted and isWanted(name) then
    return false
  end
  if fuel.isFuel(detail, slot) then
    return false
  end
  return true
end

local function firstEmptySlot()
  for slot = 1, 16 do
    if slot ~= access.SLOT and turtle.getItemCount(slot) == 0 then
      return slot
    end
  end
  return nil
end

--- Make sure the reserved slot holds cap material.
---
--- Restores the previously selected slot on every path: a job that was part-way
--- through its own inventory work must not find the selection moved underneath
--- it.
function access.reserve(isWanted)
  local selected = turtle.getSelectedSlot()
  local function done(ok, err)
    turtle.select(selected)
    return ok, err
  end

  local held = turtle.getItemDetail(access.SLOT)
  if held and access.isFiller(held, access.SLOT, isWanted) then
    return done(true)
  end

  local source = nil
  for slot = 1, 16 do
    if slot ~= access.SLOT then
      local detail = turtle.getItemDetail(slot)
      if detail and access.isFiller(detail, slot, isWanted) then
        source = slot
        break
      end
    end
  end
  if not source then
    return done(false, "no safe filler block aboard")
  end

  if held then
    -- Something else is sitting in the reserved slot. Move it aside rather than
    -- destroying it; it may be the haul this whole trip was for.
    local free = firstEmptySlot()
    if not free then
      return done(false, "no free slot to clear the cap slot")
    end
    turtle.select(access.SLOT)
    turtle.transferTo(free)
    if turtle.getItemCount(access.SLOT) > 0 then
      return done(false, "could not clear the cap slot")
    end
  end

  turtle.select(source)
  if not turtle.transferTo(access.SLOT) then
    return done(false, "could not move filler into the cap slot")
  end
  if turtle.getItemCount(access.SLOT) == 0 then
    return done(false, "could not move filler into the cap slot")
  end
  return done(true)
end

--- Last resort: take a block out of the wall to use as a cap.
---
--- Only meaningful below the surface, where every side of the shaft is rock.
--- Widens the shaft by one block at that level, which is harmless because the
--- level is underground and about to be sealed over.
function access.harvest(isWanted)
  if inv.freeSlots() == 0 then
    return false, "inventory is full, no room for a cap block"
  end

  local took = false
  for _ = 1, 4 do
    if not took and access.ahead() == "solid" then
      took = turtle.dig() == true
    end
    nav.turnRight()
  end
  if not took then
    return false, "nothing safe to mine for a cap block"
  end
  return access.reserve(isWanted)
end

--- Place a cap and report success only once the block is observed in position.
local function placeVerified(inspect, dig, place)
  local kind = access.classify(inspect())
  if kind == "solid" then
    return true -- already sealed by an earlier attempt or a previous cycle
  end
  if kind == "protected" then
    return false, "a protected block occupies the cap position"
  end
  if kind ~= "air" then
    -- Leaves, snow, or water in the cap position. None of them is a floor, and
    -- none of them accepts a block placed into it, so clear it first.
    dig()
  end

  local selected = turtle.getSelectedSlot()
  turtle.select(access.SLOT)
  local placed = place()
  turtle.select(selected)
  if not placed then
    return false, "placement was refused"
  end
  if access.classify(inspect()) ~= "solid" then
    return false, "the cap did not stay in place"
  end
  return true
end

function access.capUp()
  return placeVerified(turtle.inspectUp, turtle.digUp, turtle.placeUp)
end

function access.capDown()
  return placeVerified(turtle.inspectDown, turtle.digDown, turtle.placeDown)
end

--- Take the cap out from underneath, so the turtle can climb through it.
---
--- Retries because gravel or sand resting on the cap falls into the gap as soon
--- as it is opened, which looks identical to a dig that did nothing.
function access.clearUp()
  for _ = 1, 8 do
    local kind, name = access.above()
    if kind == "air" then
      return true
    end
    if kind == "protected" then
      return false, ("a protected block (%s) is above the shaft cap"):format(name)
    end
    if kind == "liquid" then
      return false, ("%s is standing above the shaft cap"):format(name)
    end
    if not turtle.digUp() then
      return false, "could not clear the shaft cap"
    end
  end
  return false, "the shaft cap position keeps refilling"
end

--- Read a persisted access record, tolerating one written by an older build.
function access.normalise(value)
  if type(value) ~= "table" then
    return { state = "unknown" }
  end

  local state = access.STATES[value.state] and value.state or "unknown"
  local y = tonumber(value.y)
  y = y and math.floor(y) or nil
  if not y and state ~= "unknown" and state ~= "legacy" then
    -- A transition recorded without its coordinate cannot be acted on. Treat it
    -- the same as a job from before caps existed: find the head on the way out.
    state = "legacy"
  end
  return { state = state, y = y }
end

return access
