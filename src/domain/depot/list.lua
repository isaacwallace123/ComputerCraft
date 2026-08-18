--- The drop-off list: a mutable, ordered set of places to put things.
---
--- Phase 4 of docs/icos-2.md, and the answer to §1's third failure:
--- *"Everything must come home to one chest — the depot is a convention
--- (`below home`), not data."*
---
--- ## Order is meaningful
---
--- This is a list, not a set. §7: *"Ordering matters — it is the tie-break when
--- two are equally close."* Two depots the same distance from a turtle is not a
--- rare case, it is what happens when somebody builds a matched pair either side
--- of a base, and a fleet that picked between them by table iteration order would
--- deliver to a different one every trip for no reason anybody could see.
---
--- ## An empty list must behave exactly like today
---
--- D008 is not repealed by this. Every mining depot is below home, and that
--- stays the fallback *and* the default: an empty list means "unload below
--- home", which is what a fleet that never opens this screen keeps doing
--- forever. `select.lua` is where that is enforced; this file only has to make
--- an empty list representable and cheap.
---
--- ## Pure, with the clock injected
---
--- Same rule as the rest of `domain/`. `now` is a parameter.

local list = {}

--- What a depot accepts, by default.
---
--- `*` rather than an empty list, because "accepts nothing" and "accepts
--- everything" are both plausible readings of an empty table and the wrong guess
--- silently strands a fleet's haul. An explicit wildcard has one meaning.
list.ANY = "*"

--- How long a `full` report is believed.
---
--- A depot is reported full by a turtle that tried to use it, and nothing ever
--- reports it empty again - a person walks over and takes the diamonds out, and
--- tells nobody. A flag with no expiry would therefore remove a depot from
--- service permanently on the strength of one bad trip.
---
--- Twenty minutes is long enough that a fleet does not batter a genuinely full
--- chest, and short enough that emptying one by hand puts it back in rotation
--- before anybody wonders why it is being ignored.
list.FULL_FOR = 20 * 60

function list.empty()
  return { depots = {} }
end

local function slug(label, index)
  local text = tostring(label or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if text == "" then
    text = "depot"
  end
  return text .. "-" .. tostring(index)
end

--- Add a drop-off. Returns the stored record.
---
--- `position` is absolute world coordinates, because a drop-off is a place in
--- the world and every turtle that uses it has a different idea of where its own
--- home is. This is the same requirement the coordinated quarry already has, and
--- the reason `where` became a universal setup step in §10.
function list.add(state, depot)
  if type(depot) ~= "table" or type(depot.position) ~= "table" then
    error("depot: needs a position", 2)
  end
  local x, y, z = tonumber(depot.position.x), tonumber(depot.position.y), tonumber(depot.position.z)
  if x == nil or y == nil or z == nil then
    error("depot: position needs x, y and z", 2)
  end

  local record = {
    id = depot.id or slug(depot.label, #state.depots + 1),
    label = depot.label or ("Depot " .. tostring(#state.depots + 1)),
    position = { x = math.floor(x), y = math.floor(y), z = math.floor(z) },
    accepts = depot.accepts or { list.ANY },
    enabled = depot.enabled ~= false,
    full = false,
    fullAt = nil,
  }
  state.depots[#state.depots + 1] = record
  return record
end

function list.get(state, id)
  for _, depot in ipairs(state.depots) do
    if depot.id == id then
      return depot
    end
  end
  return nil
end

function list.remove(state, id)
  for index, depot in ipairs(state.depots) do
    if depot.id == id then
      table.remove(state.depots, index)
      return depot
    end
  end
  return nil
end

--- Move a depot up or down the order. Clamped rather than wrapped: a person
--- holding the up key on the first entry means "keep it first", not "send it to
--- the bottom".
function list.move(state, id, delta)
  for index, depot in ipairs(state.depots) do
    if depot.id == id then
      local wanted = math.max(1, math.min(#state.depots, index + delta))
      if wanted == index then
        return false
      end
      table.remove(state.depots, index)
      table.insert(state.depots, wanted, depot)
      return true
    end
  end
  return false
end

function list.enable(state, id, enabled)
  local depot = list.get(state, id)
  if depot == nil then
    return nil
  end
  depot.enabled = enabled ~= false
  return depot
end

--- Record that a turtle found this depot full.
function list.reportFull(state, id, now, full)
  local depot = list.get(state, id)
  if depot == nil then
    return nil
  end
  if full == false then
    depot.full, depot.fullAt = false, nil
    return depot
  end
  depot.full, depot.fullAt = true, now
  return depot
end

--- Is this depot believed full *right now*?
---
--- The expiry lives here rather than in the stored flag so that a persisted
--- record does not need rewriting on a timer, and so a server restart does not
--- resurrect a stale report as a fresh one.
function list.isFull(depot, now, window)
  if not depot.full then
    return false
  end
  if depot.fullAt == nil then
    return true
  end
  return (now - depot.fullAt) / 1000 <= (window or list.FULL_FOR)
end

--- Does this depot take that item?
---
--- Patterns are plain substrings of the item name, matching the conventions
--- already in `os/turtle/device/ore.lua`: `_ore` catches every modded ore, `raw_` the
--- drops, `ingot` the smelted results. Not Lua patterns - a person typing
--- `raw_` into a text field should not have to know that `-` means something.
function list.accepts(depot, item)
  if item == nil then
    return true
  end
  local name = tostring(item):lower()
  for _, rule in ipairs(depot.accepts or {}) do
    if rule == list.ANY then
      return true
    end
    if name:find(tostring(rule):lower(), 1, true) then
      return true
    end
  end
  return false
end

--- The depots a turtle could actually use, in list order.
function list.usable(state, now, item, window)
  local usable = {}
  for _, depot in ipairs(state.depots) do
    if depot.enabled and not list.isFull(depot, now, window) and list.accepts(depot, item) then
      usable[#usable + 1] = depot
    end
  end
  return usable
end

return list
