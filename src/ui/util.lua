--- Small text helpers every component needs.
---
--- `pad` exists for the reason `core/ui.lua` grew its own: Lua's `string.format`
--- has no `*` dynamic-width specifier, and it caps a literal width at two digits
--- besides - so `("%-164s"):format(x)` is not a typo that a linter catches, it is
--- a runtime error on a wide monitor. Anywhere a width is computed rather than
--- literal, this is the only correct way to reach it.

local util = {}

--- Truncate and pad `text` to exactly `width` cells.
---
--- Exactly, in both directions. A component that returns a string shorter than
--- its box leaves whatever was underneath it showing through, and one that
--- returns a longer string paints over its neighbour - both of which look like
--- layout bugs and are not.
function util.pad(text, width, align)
  text = tostring(text == nil and "" or text)
  if width <= 0 then
    return ""
  end
  if #text > width then
    return text:sub(1, width)
  end

  local slack = width - #text
  if align == "right" then
    return string.rep(" ", slack) .. text
  end
  if align == "center" then
    local left = math.floor(slack / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", slack - left)
  end
  return text .. string.rep(" ", slack)
end

--- Shorten with an ellipsis, for text that has to fit but wants to be readable.
---
--- Uses ".." rather than a single "…" character: the CC font has no ellipsis
--- glyph, and a codepoint outside the font renders as a question mark box, which
--- is worse than two full stops.
function util.ellipsis(text, width)
  text = tostring(text == nil and "" or text)
  if width <= 0 then
    return ""
  end
  if #text <= width then
    return text
  end
  if width <= 2 then
    return text:sub(1, width)
  end
  return text:sub(1, width - 2) .. ".."
end

--- Fuel and block counts, which are the numbers this fleet actually shows.
--- 51000 in a seven-cell column is "51.0k"; the exact figure is never the point
--- and the column is never wide enough for it.
function util.count(value)
  value = tonumber(value) or 0
  if value >= 1000000 then
    return ("%.1fM"):format(value / 1000000)
  end
  if value >= 1000 then
    return ("%.1fk"):format(value / 1000)
  end
  return tostring(math.floor(value))
end

--- Seconds since something, as a short human string. `nil` is "never", which is
--- a real answer for a device that has not reported since the server started.
function util.ago(seconds)
  if seconds == nil then
    return "never"
  end
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then
    return seconds .. "s"
  end
  if seconds < 3600 then
    return math.floor(seconds / 60) .. "m"
  end
  if seconds < 86400 then
    return math.floor(seconds / 3600) .. "h"
  end
  return math.floor(seconds / 86400) .. "d"
end

return util
