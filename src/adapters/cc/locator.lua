--- Locator port over `gps` and the saved location file.
---
--- `saved` reads a file rather than caching at construction so that a `where`
--- run mid-session is picked up without a reboot. The read is cheap and happens
--- once per route, not once per move.

local config = require("adapters.cc.config")
local locator = require("ports.locator")

local adapter = {}

--- Default location file. Every device declares its position at setup, not just
--- turtles - a server has to know where it is to host GPS at all.
adapter.PATH = ".location"

--- `load` is injectable only so a spec can supply a record without a
--- filesystem; in production it is always `core.config.load`, which brings the
--- `.tmp` recovery that a half-written location file needs.
function adapter.new(path, load)
  path = path or adapter.PATH
  load = load or function(from)
    local record = config.load(from, {})
    return record
  end

  local impl = {}

  --- Ask the constellation. Nil is a normal answer: it needs four loaded hosts
  --- in range, and a turtle at the bottom of a shaft frequently has fewer.
  function impl.gps(timeoutSeconds)
    return gps.locate(timeoutSeconds or 2)
  end

  --- What setup wrote down, including heading.
  ---
  --- GPS cannot supply a facing - a stationary turtle looks the same from every
  --- direction - so this is the only source of one, and dead reckoning between
  --- fixes depends on it. A machine that has not been through setup returns nil
  --- rather than a plausible-looking origin at 0,0,0, which is a real place in
  --- the world and has already cost one fleet a wasted night.
  function impl.saved()
    local record = load(path)
    if type(record) ~= "table" or record.x == nil then
      return nil
    end
    return record
  end

  return locator.check(impl)
end

return adapter
