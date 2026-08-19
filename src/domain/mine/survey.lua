--- Turning a scanner's block list into something worth reading.
---
--- A Geo Scanner returns every block in a radius - thousands of them, mostly
--- stone. The decisions are which ones matter, how to group them, and what
--- "nearest" means, and all three are arithmetic over a table. So they live here
--- and the command that prints them is fifteen lines.
---
--- ## Matched by name, deliberately
---
--- `ore`, `debris` and `raw_` catch vanilla and effectively every modded ore in
--- a pack this size. A list of exact names would be accurate on the day it was
--- written and would silently miss every ore the pack added after it - and the
--- failure would be invisible, because a scan that finds nothing looks exactly
--- like a scan of ordinary stone.
---
--- The cost of a false positive is one wrong row in a diagnostic. That is the
--- right trade here and is not the trade `domain/farm/crops.lua` makes, where
--- being wrong destroys a field.
---
--- ## Manhattan distance, not Euclidean
---
--- A turtle moves in axis steps, so the distance that matters is the number of
--- moves rather than the length of a straight line. Ranking by Euclidean
--- distance would put a diagonal vein above one that is genuinely closer to dig
--- to, which is the one question somebody scanning is asking.

local survey = {}

--- Is this block worth reporting?
function survey.interesting(name)
  if type(name) ~= "string" then
    return false
  end
  return name:find("ore") ~= nil or name:find("debris") ~= nil or name:find("raw_") ~= nil
end

--- How many moves away a block is.
function survey.distance(block)
  return math.abs(block.x or 0) + math.abs(block.y or 0) + math.abs(block.z or 0)
end

--- Group a scan into one row per ore, commonest first.
---
--- Each row carries the *nearest* example of that ore rather than the first one
--- found, because "there is diamond somewhere in this radius" is not actionable
--- and "there is diamond eleven moves away, down and east" is.
---
--- Commonest first rather than nearest first: a scan is read to decide where to
--- put a quarry, and one block of diamond at range four is worth less than a
--- forty-block iron seam at range twelve.
function survey.summarise(blocks)
  local found = {}

  for _, block in ipairs(blocks or {}) do
    if type(block) == "table" and survey.interesting(block.name) then
      local distance = survey.distance(block)
      local entry = found[block.name]
      if entry == nil then
        found[block.name] = {
          name = block.name,
          count = 1,
          x = block.x,
          y = block.y,
          z = block.z,
          distance = distance,
        }
      else
        entry.count = entry.count + 1
        if distance < entry.distance then
          entry.x, entry.y, entry.z, entry.distance = block.x, block.y, block.z, distance
        end
      end
    end
  end

  local rows = {}
  for _, entry in pairs(found) do
    rows[#rows + 1] = entry
  end

  table.sort(rows, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    -- Stable enough to be worth reading twice. `pairs` order would otherwise
    -- reshuffle equal-count rows between two scans of the same chunk, which
    -- looks like the world changed.
    return a.name < b.name
  end)

  return rows
end

return survey
