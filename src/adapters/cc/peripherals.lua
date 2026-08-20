--- Peripherals port over CC's `peripheral` API.
---
--- Thin, and defensive in one specific way: **every call is wrapped**.
---
--- Everything else in this system calls methods it knows exist, on ports it
--- checked at construction. This one calls methods on blocks somebody else's mod
--- put in the world, whose names came from `getMethods` and whose behaviour is
--- documented nowhere. A modded peripheral that throws on a getter is not a bug
--- to be fixed here; it is Tuesday.
---
--- So `call` answers `false, reason` and a page that enumerates hardware carries
--- on down the list. The alternative is one badly-behaved block taking out the
--- page that would have shown you which block it was.

local peripherals = require("ports.peripherals")

local adapter = {}

function adapter.new()
  local impl = {}

  --- Everything attached, with its types as a set.
  ---
  --- `peripheral.getType` returns one or more values in CC:Tweaked, because a
  --- block can be several things at once - an inventory *and* a furnace, a
  --- modem *and* wireless. Collapsing that to the first would make every "is
  --- this an inventory" check wrong for exactly the modded blocks worth
  --- detecting.
  function impl.list()
    local found = {}

    for _, name in ipairs(peripheral.getNames()) do
      local types = {}
      local reported = { peripheral.getType(name) }
      for _, kind in ipairs(reported) do
        if type(kind) == "string" then
          types[kind] = true
        end
      end

      found[#found + 1] = {
        name = name,
        types = types,
        -- The first type is what CC considers the block's identity, and it is
        -- the one worth showing when there is room for one word.
        primary = reported[1],
      }
    end

    return found
  end

  --- Call one method, never raising.
  ---
  --- `pcall` rather than a check, because the failures worth surviving are not
  --- knowable in advance: a peripheral removed between `list` and `call`, a
  --- method that exists and throws, a mod that returns something unexpected. All
  --- three look the same to a caller and all three mean "carry on".
  function impl.call(name, method, ...)
    if type(name) ~= "string" or type(method) ~= "string" then
      return false, "bad arguments"
    end
    local results = { pcall(peripheral.call, name, method, ...) }
    if not results[1] then
      return false, tostring(results[2])
    end
    return true, table.unpack(results, 2)
  end

  --- What a peripheral can do, or nil if it is gone.
  function impl.methods(name)
    local ok, names = pcall(peripheral.getMethods, name)
    if not ok or type(names) ~= "table" then
      return nil
    end
    table.sort(names)
    return names
  end

  return peripherals.check(impl)
end

return adapter
