--- What a peripheral is, and whose mod it came from.
---
--- ## Mod detection is a colon
---
--- Minecraft namespaces every registry name as `mod:thing`, and CC passes that
--- through as the peripheral type. So `advancedperipherals:chunk_controller` is
--- a Chunk Controller from Advanced Peripherals, and detecting the mod is
--- reading the part before the colon.
---
--- That is the whole mechanism, and it is worth saying plainly because it sounds
--- like it should be harder. There is no registry to query, no version to
--- negotiate and nothing to install: a base that lists its peripherals already
--- knows which mods are within reach of it.
---
--- Vanilla CC types have **no** namespace - `drive`, `monitor`, `modem`,
--- `speaker` - which is the one case the colon rule does not cover, and is
--- therefore the case the code has to name.
---
--- ## Kinds are about what a thing can do
---
--- A `kind` is this fleet's word for a capability: storage, display, radio,
--- sound, fuel, chunk. Two blocks from different mods that both hold items are
--- the same kind, because the question anything upstream asks is "can I put
--- something in it" and not "who made it".
---
--- Unknown is a kind too, and the common one. A modpack has hundreds of
--- peripherals and this fleet has opinions about six of them; the rest are
--- listed, named, and left alone. Guessing what an unrecognised block does would
--- be worse than saying so.

local kinds = {}

--- Types this fleet recognises, and what it calls them.
---
--- Matched on the type *after* the namespace, so a modded inventory registers as
--- storage without this table naming the mod. The vanilla CC types are here
--- unprefixed because they have no namespace at all.
kinds.KNOWN = {
  drive = "storage",
  inventory = "storage",
  item_storage = "storage",
  monitor = "display",
  modem = "radio",
  speaker = "sound",
  printer = "print",
  computer = "computer",
  turtle = "turtle",

  -- Advanced Peripherals, which this pack ships and the fleet already depends on
  -- for chunk loading and ore scanning. Named by their bare type so a rename of
  -- the mod's namespace does not lose them.
  chunky = "chunk",
  chunk_controller = "chunk",
  geoScanner = "scanner",
  geo_scanner = "scanner",
  inventoryManager = "storage",
  playerDetector = "sensor",
  energyDetector = "power",
}

--- The mod a peripheral type belongs to, or nil for vanilla ComputerCraft.
---
--- Nil rather than `"minecraft"` or `"computercraft"`, because the question this
--- answers is "is this something extra" - and a caller that wants to group by
--- mod wants vanilla in its own group, not in a group named after a guess.
function kinds.modOf(peripheralType)
  if type(peripheralType) ~= "string" then
    return nil
  end
  local namespace = peripheralType:match("^([%w_]+):")
  return namespace
end

--- The bare type, without its namespace.
function kinds.bare(peripheralType)
  if type(peripheralType) ~= "string" then
    return nil
  end
  return peripheralType:match(":(.+)$") or peripheralType
end

--- What this fleet can do with a peripheral, or "unknown".
---
--- Takes the whole type set rather than one type, because a block is often
--- several things and the useful answer is the most specific one. A Create
--- vault reporting both `inventory` and its own type is storage; saying
--- "unknown" because the second type is unrecognised would be reading past the
--- answer.
function kinds.classify(types)
  if type(types) ~= "table" then
    return "unknown"
  end

  local found = nil
  for name in pairs(types) do
    local kind = kinds.KNOWN[kinds.bare(name)] or kinds.KNOWN[name]
    if kind then
      -- `storage` loses to anything more specific. Almost everything with an
      -- inventory also *is* something, and "chest" is the less interesting half
      -- of "furnace that happens to hold items".
      if found == nil or found == "storage" then
        found = kind
      end
    end
  end

  return found or "unknown"
end

--- Group a peripheral list by the mod that provides it.
---
--- Returns a list of `{ mod, items }`, vanilla first and then alphabetical.
--- Vanilla first because it is the group somebody is looking for when something
--- expected is missing - a monitor that is not listed is a wiring problem, and a
--- modded block that is not listed is usually a mod that is not there.
function kinds.byMod(list)
  local groups = {}
  local order = {}

  for _, entry in ipairs(list or {}) do
    local mod = nil
    for name in pairs(entry.types or {}) do
      mod = mod or kinds.modOf(name)
    end
    local key = mod or "computercraft"

    if groups[key] == nil then
      groups[key] = { mod = key, vanilla = mod == nil, items = {} }
      order[#order + 1] = groups[key]
    end

    groups[key].items[#groups[key].items + 1] = {
      name = entry.name,
      kind = kinds.classify(entry.types),
      label = kinds.bare(entry.primary) or entry.name,
    }
  end

  table.sort(order, function(a, b)
    if a.vanilla ~= b.vanilla then
      return a.vanilla
    end
    return a.mod < b.mod
  end)

  for _, group in ipairs(order) do
    table.sort(group.items, function(a, b)
      return a.name < b.name
    end)
  end

  return order
end

--- Every mod within reach of this machine.
---
--- The point of the whole file: a base that lists its peripherals already knows
--- which mods it can talk to, without a registry, a version handshake, or
--- anything installed.
function kinds.mods(list)
  local seen = {}
  local out = {}
  for _, group in ipairs(kinds.byMod(list)) do
    if not group.vanilla and not seen[group.mod] then
      seen[group.mod] = true
      out[#out + 1] = group.mod
    end
  end
  return out
end

return kinds
