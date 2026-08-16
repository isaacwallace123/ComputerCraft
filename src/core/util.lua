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
