--- Log port over `adapters/cc/logfile.lua`.
---
--- Thin on purpose. `adapters/cc/logfile.lua` already writes the file `logrotate` rotates,
--- already keeps the in-memory tail the ICOS 1 console draws, and already queues
--- the `icos_log` event that console listens for so new lines appear without
--- waiting on a refresh timer.
---
--- Reimplementing any of that would give ICOS 2 a *second* log - a second file,
--- a second tail, and an ICOS 1 console that goes quiet the moment a machine is
--- upgraded. During a rolling update both operating systems are running
--- somewhere in the fleet, and the one thing a person needs during a rolling
--- update is a log that has everything in it.
---
--- So this adapts rather than replaces, and the level names are translated
--- because the port's are lowercase and `adapters/cc/logfile.lua`'s are not.

local core = require("adapters.cc.logfile")
local log = require("ports.log")

local adapter = {}

--- Build the port.
---
--- `prefix` is prepended to every line, and it is how a reader tells a server's
--- log apart from a turtle's when both end up in front of them. Optional,
--- because the ICOS 1 console has never had one and adding it to lines it
--- already shows would make the same event look like two.
function adapter.new(prefix)
  local function decorate(message)
    if prefix == nil or prefix == "" then
      return tostring(message)
    end
    return ("%s: %s"):format(prefix, message)
  end

  local impl = {}

  function impl.info(message)
    core.info(decorate(message))
  end

  function impl.warn(message)
    core.warn(decorate(message))
  end

  function impl.error(message)
    core.error(decorate(message))
  end

  --- The in-memory tail, not the file.
  ---
  --- A Logs page that re-read four hundred lines off disk on every frame would
  --- be a page that costs a disk read per keypress, on a machine that is also
  --- reconciling ten turtles. The tail is what a screen shows; the file is what
  --- somebody opens with `edit .log` after the fact.
  ---
  --- Normalised into the port's shape rather than passed through, because
  --- `adapters/cc/logfile.lua` stores a pre-formatted line and a CC colour, and a port that
  --- handed a page a colour would be a port making a design decision.
  function impl.recent(count)
    local out = {}
    for index, entry in ipairs(core.recent(count or 32)) do
      out[index] = {
        text = entry.text,
        at = entry.at,
        -- Recovered from the formatted line rather than stored beside it,
        -- because `adapters/cc/logfile.lua` does not keep the level and changing it to
        -- would change a file the live fleet is writing right now.
        --
        -- Normalised through `log.level`, which is the fix for a bug this
        -- adapter had on its first day: `adapters/cc/logfile.lua` writes the level
        -- upper-case, so returning it raw made every page compare "WARN"
        -- against the port's "warn" - and the Logs page's warnings-only filter
        -- showed an empty screen while warnings were arriving.
        level = log.level((entry.text or ""):match("%]%s+(%a+)")),
      }
    end
    return out
  end

  return log.check(impl)
end

return adapter
