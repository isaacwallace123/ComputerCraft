--- Working out where a turtle is and which way it faces, from the constellation.
---
--- ## GPS gives you three numbers and withholds the fourth
---
--- `gps.locate` answers a position and nothing else, because a stationary turtle
--- looks identical from every direction - there is no signal that differs by
--- which way it is pointing. So a turtle that has only asked GPS knows where it
--- is and cannot get home, which is the same as not knowing.
---
--- The fourth number is recovered by *moving*. Take a fix, move one block
--- forward, take another, and the difference is the direction the turtle was
--- pointing. One block of fuel and about a second, against a person walking to
--- every turtle in the fleet and reading F3.
---
--- ## Which is why this file is arithmetic and nothing else
---
--- No radio, no turtle, no clock. Given two positions it says which way the
--- turtle moved; given one it says whether it is usable. Everything that can go
--- wrong here - a diagonal that should be impossible, a fix that did not move,
--- a constellation that answered with a nil - is a branch a spec can take, and
--- every one of them has happened to somebody's turtle in a world.
---
--- The compass is `os/turtle/device/nav.lua`'s: 0 north (-Z), 1 east (+X),
--- 2 south (+Z), 3 west (-X), which is the order a turtle turns through when it
--- turns right. Stated here because two files disagreeing about it is a fleet
--- that mines confidently in the wrong direction.

local fix = {}

fix.COMPASS = { "north", "east", "south", "west" }

--- Which way a turtle was pointing, given where it was and where it got to.
---
--- Returns 0-3, or nil and a reason. The reasons are all real:
---
---   * it did not move - the block ahead was solid, or the move failed and the
---     caller believed it anyway;
---   * it moved more than one block, or on two axes at once, which means the
---     two fixes are not a single step and something else moved it;
---   * it moved vertically, which `forward` cannot do and which means the fixes
---     came from different moments in a job.
---
--- Every one of those is refused rather than rounded to the nearest direction. A
--- heading is the one number nothing can check afterwards: a turtle with the
--- wrong one drives away from home in a straight line, and the first anybody
--- knows is that it stopped answering.
function fix.headingFrom(before, after)
  if type(before) ~= "table" or type(after) ~= "table" then
    return nil, "no fix"
  end

  local dx = (tonumber(after.x) or 0) - (tonumber(before.x) or 0)
  local dy = (tonumber(after.y) or 0) - (tonumber(before.y) or 0)
  local dz = (tonumber(after.z) or 0) - (tonumber(before.z) or 0)

  if dy ~= 0 then
    return nil, "it changed height between fixes"
  end
  if dx == 0 and dz == 0 then
    return nil, "it did not move"
  end
  if dx ~= 0 and dz ~= 0 then
    return nil, "it moved on two axes"
  end
  if math.abs(dx) > 1 or math.abs(dz) > 1 then
    return nil, "it moved more than one block"
  end

  if dz == -1 then
    return 0, "north"
  end
  if dx == 1 then
    return 1, "east"
  end
  if dz == 1 then
    return 2, "south"
  end
  return 3, "west"
end

--- Is this a fix worth acting on?
---
--- Three numbers, all present and all whole. `gps.locate` answers nil on
--- failure, and CC returns fractional coordinates for a turtle mid-move - a
--- position of 12.5 is a turtle between two blocks, and writing it as an origin
--- would put every relative coordinate in the job half a block out forever.
function fix.usable(position)
  if type(position) ~= "table" then
    return false, "no fix"
  end

  for _, axis in ipairs({ "x", "y", "z" }) do
    local value = tonumber(position[axis])
    if value == nil then
      return false, "the fix is missing " .. axis
    end
    if value % 1 ~= 0 then
      return false, "the fix is between blocks"
    end
  end

  return true
end

--- Round a fix to whole blocks, or nil.
---
--- Separate from `usable`, because a caller that has decided to trust a fix
--- still needs it as integers - and `math.floor` on a negative fraction is the
--- kind of thing that is right in three quadrants and wrong in the fourth.
function fix.blockOf(position)
  if type(position) ~= "table" then
    return nil
  end
  local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
  if x == nil or y == nil or z == nil then
    return nil
  end
  return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

--- The name of a heading, for something a person reads.
function fix.compass(heading)
  local index = tonumber(heading)
  if index == nil then
    return "unknown"
  end
  return fix.COMPASS[(math.floor(index) % 4) + 1]
end

return fix
