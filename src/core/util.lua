--- Small formatting and maths helpers with no dependencies.

local util = {}

--- "1h 04m", "9s" - compact enough for a dashboard column.
function util.duration(seconds)
  seconds = math.floor(seconds or 0)
  if seconds < 60 then
    return seconds .. "s"
  end
  if seconds < 3600 then
    return ("%dm %02ds"):format(seconds / 60, seconds % 60)
  end
  return ("%dh %02dm"):format(seconds / 3600, (seconds % 3600) / 60)
end

--- 1234567 -> "1.2M". Keeps dashboard columns narrow.
function util.count(n)
  n = n or 0
  if n >= 1000000 then
    return ("%.1fM"):format(n / 1000000)
  end
  if n >= 10000 then
    return ("%.0fk"):format(n / 1000)
  end
  if n >= 1000 then
    return ("%.1fk"):format(n / 1000)
  end
  return tostring(math.floor(n))
end

--- "minecraft:deepslate_iron_ore" -> "deepslate iron ore"
function util.blockName(name)
  return (tostring(name):gsub("^.*:", ""):gsub("_", " "))
end

function util.clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

--- Read the first three signed integers from a coordinate string.
---
--- Do not parse this as `number + non-digits + number`: a greedy non-digit
--- separator also consumes the minus sign belonging to the next coordinate.
--- Tokenising each signed number independently preserves negative Y/Z values
--- in common inputs such as `42 79 -1080` and `42 / 79 / -1080`.
function util.coordinates(text)
  local values = {}
  for token in tostring(text or ""):gmatch("[+-]?%d+") do
    values[#values + 1] = tonumber(token)
    if #values == 3 then
      return values[1], values[2], values[3]
    end
  end
  return nil
end

--- Compare two labels the way a person reads them.
---
--- A plain string comparison puts `miner-10` between `miner-1` and `miner-2`,
--- because it compares "1" against "2" one character at a time and never gets to
--- the "0". On a ten-turtle fleet that makes the dashboard genuinely hard to
--- read, and it gets worse as the fleet grows.
---
--- Each string is walked as alternating runs of digits and non-digits: digit
--- runs compare as numbers, everything else compares as text. Leading zeros
--- therefore do not change the order, and two labels that differ only by them
--- fall back to a raw comparison so the result stays deterministic - `table.sort`
--- is not stable, and a comparator that calls two different strings equal can
--- reorder rows between refreshes for no visible reason.
function util.naturalLess(a, b)
  a, b = tostring(a or ""), tostring(b or "")
  if a == b then
    return false
  end

  local at, bt = 1, 1
  while true do
    local aDigits = a:match("^%d+", at)
    local bDigits = b:match("^%d+", bt)

    if aDigits and bDigits then
      local aNumber, bNumber = tonumber(aDigits), tonumber(bDigits)
      if aNumber ~= bNumber then
        return aNumber < bNumber
      end
      at, bt = at + #aDigits, bt + #bDigits
    else
      local aChar, bChar = a:sub(at, at), b:sub(bt, bt)
      if aChar == "" or bChar == "" then
        if aChar == bChar then
          return a < b -- same apart from leading zeros
        end
        return aChar == "" -- the shorter one comes first
      end
      if aChar ~= bChar then
        return aChar < bChar
      end
      at, bt = at + 1, bt + 1
    end
  end
end

--- Seconds since a millisecond epoch stamp, floored at zero.
function util.since(epochMillis)
  if not epochMillis then
    return math.huge
  end
  return math.max(0, (os.epoch("utc") - epochMillis) / 1000)
end

--- Truncate to `width`, no ellipsis - dashboard columns are tight.
function util.fit(text, width)
  text = tostring(text or "")
  if #text <= width then
    return text
  end
  return text:sub(1, width)
end

return util
