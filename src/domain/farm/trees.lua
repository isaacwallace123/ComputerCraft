--- What a tree is made of, and where the trees stand.
---
--- The companion to `domain/farm/crops.lua` and deliberately shaped the same
--- way: pure knowledge, asked rather than assumed, so the decisions in a tree
--- farm can be checked without a world.
---
--- ## Tags, not a list of names
---
--- A crop is identified by name because its maturity is a per-block number and
--- there is no tag for "ripe". A log is not: Minecraft has a `minecraft:logs`
--- tag, CC's `turtle.inspect` returns the block's tags, and the documented
--- example on tweaked.cc is literally `tags = { ["minecraft:logs"] = true }`.
---
--- So this asks the tag. That is not a small difference - a name list would need
--- eleven entries for vanilla alone, would miss every modded wood, and would go
--- silently wrong the next time Mojang adds a tree. The tag is maintained by the
--- game.
---
--- ## Saplings are matched by suffix, and that is a considered compromise
---
--- There is a `minecraft:saplings` item tag, but reading item tags costs a
--- `getItemDetail(slot, true)` per slot, which is the expensive form of a call
--- this makes sixteen times per replant. Every vanilla and effectively every
--- modded sapling ends in `_sapling`, so the suffix is cheap and nearly as
--- accurate.
---
--- The cost of being wrong is bounded and visible: a false positive plants
--- something that is not a sapling and fails, a false negative delivers a
--- sapling to the chest instead of keeping it. Neither destroys anything, which
--- is why the cheap test is acceptable here and was not acceptable for maturity.

local trees = {}

trees.LOG_TAG = "minecraft:logs"
trees.LEAF_TAG = "minecraft:leaves"

--- Is this block part of a trunk?
function trees.isLog(block)
  if type(block) ~= "table" or type(block.tags) ~= "table" then
    return false
  end
  return block.tags[trees.LOG_TAG] == true
end

--- Is this block canopy?
---
--- Not dug through on the way up. Leaves decay on their own, and a turtle that
--- cleared them would spend most of a fell on blocks that were about to vanish -
--- and would come home full of leaf blocks instead of wood.
function trees.isLeaves(block)
  if type(block) ~= "table" or type(block.tags) ~= "table" then
    return false
  end
  return block.tags[trees.LEAF_TAG] == true
end

--- Is this item a sapling?
function trees.isSapling(itemName)
  if type(itemName) ~= "string" then
    return false
  end
  return itemName:sub(-8) == "_sapling"
end

--- Where tree `index` stands, and where the turtle stands to reach it.
---
--- Trees sit in a line `distance` blocks in front of home, `spacing` apart. The
--- turtle works from an **aisle** one block short of that line, so it is never
--- standing where a trunk is about to be - a turtle inside the column it is
--- felling is a turtle that has to dig its way out through the tree that fell on
--- it.
---
--- Returns the aisle cell and the facing to look down. Facing 0 is +z, which is
--- straight ahead of home (`os/turtle/device/nav.lua`), so a line of trees ahead
--- is looked at without turning at all.
---
--- Never nil. A negative index is corrupt saved state, and clamping it to the
--- first tree is what `resume` already does - returning nil instead would add a
--- failure path to the run loop for a case that cannot reach it, and a branch
--- that cannot be reached is a branch nobody can be sure is right.
function trees.station(index, spacing, distance)
  index = math.max(0, math.floor(tonumber(index) or 0))
  spacing = math.max(1, math.floor(tonumber(spacing) or 2))
  distance = math.max(1, math.floor(tonumber(distance) or 2))
  return {
    x = index * spacing,
    y = 1,
    z = distance - 1,
    facing = 0,
  }
end

--- The next tree, wrapping.
---
--- Same rule as a crop plot and for the same reason: a tree farm is never
--- finished either, so there is no last tree and the run loop has one branch.
function trees.next(index, count)
  count = math.max(0, math.floor(tonumber(count) or 0))
  if count == 0 then
    return 0
  end
  local moved = (index or 0) + 1
  if moved >= count then
    return 0
  end
  return moved
end

--- A saved index made safe against a row that was shortened while away.
function trees.resume(index, count)
  count = math.max(0, math.floor(tonumber(count) or 0))
  index = math.floor(tonumber(index) or 0)
  if index < 0 or index >= count then
    return 0
  end
  return index
end

--- How much fuel a fell costs, worst case.
---
--- Up the trunk and back down, plus one step in and one out. `maxHeight` is a
--- cap rather than a measurement, because the turtle cannot see the top of a
--- tree from the bottom and a jungle tree is thirty blocks tall - a farm that
--- budgeted for oak would strand itself the first time somebody planted
--- something bigger.
function trees.fellCost(maxHeight)
  return 2 * math.max(1, math.floor(tonumber(maxHeight) or 1)) + 2
end

return trees
