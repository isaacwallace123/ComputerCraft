--- Port: saying what happened, for somebody who was asleep.
---
--- ## Why this is a port at all
---
--- Every service in `os/` deliberately *returns* what it did rather than writing
--- it down, and every one of them says so in a comment: a service that wrote to
--- a log would be a service deciding how a machine reports things, and on a
--- Pocket Computer that log is somewhere else entirely. That was the right call
--- and it left a hole - nothing in ICOS 2 could log, so `logrotate` was rotating
--- a file nobody wrote.
---
--- This is the other end. The composition root takes the facts its services
--- returned and records them, which puts the one decision - *what is worth
--- writing down* - in the file that already knows what kind of machine it is.
---
--- ## Three levels, and no more
---
--- `info`, `warn`, `error`. There is no `debug`, deliberately: a level nobody
--- reads in production is a level that fills the disk being ignored, and this
--- codebase's habit is to explain in a comment rather than at runtime. There is
--- no `fatal` either, because the supervisor is what decides a machine is
--- finished, and a level that claimed to would be a second opinion.
---
--- ## `recent` is not `read`
---
--- The in-memory tail is what a Logs page draws; the file is what somebody opens
--- after the fact. Keeping them separate means a page that scrolls does not
--- re-read a four-hundred-line file on every frame, and it means a machine whose
--- disk is full still has a log on screen - which is exactly when somebody is
--- looking at one.

local contract = require("ports.contract")

local log = {}

log.NAME = "log"

log.METHODS = {
  "info", -- (message) -> nil
  "warn", -- (message) -> nil
  "error", -- (message) -> nil
  "recent", -- (count) -> array of { level, text, at }, oldest first
}

--- The level names, lowercase, matching the method names exactly.
---
--- Stated because it was got wrong once: the CC adapter recovered the level from
--- a formatted line where `adapters/cc/logfile.lua` writes it upper-case, and returned that
--- - so the Logs page compared "WARN" against "warn", found no warnings, and its
--- warnings-only filter showed an empty screen. A port that names its values is
--- a port whose adapters can be checked against something.
log.LEVELS = { info = true, warn = true, error = true }

--- Coerce whatever an adapter recovered into one of the three.
---
--- Anything unrecognised is `info`, including nil. An unparseable line is still
--- a line worth showing, and a level nobody can read is not a reason to hide it -
--- it is usually the note somebody typed into `.log` by hand.
function log.level(value)
  local name = tostring(value or ""):lower()
  return log.LEVELS[name] and name or "info"
end

function log.check(impl)
  return contract.check(log.NAME, log.METHODS, impl)
end

--- A log that remembers nothing.
---
--- Writes succeed and go nowhere, `recent` is empty. What a spec wants, and what
--- a machine should never have: a null log makes every other failure silent,
--- which is why the composition roots build a real one rather than defaulting to
--- this.
function log.null()
  return contract.null(log.METHODS, {
    recent = function()
      return {}
    end,
  })
end

--- A log that keeps its lines in a table, for a spec that wants to read them.
---
--- Not `null`, and not an adapter either - it belongs here because it is the
--- shape of the port rather than a way of talking to CC, and because every spec
--- that wants one would otherwise write the same fifteen lines.
function log.memory(limit)
  limit = limit or 64
  local lines = {}

  local function record(level, message)
    lines[#lines + 1] = { level = level, text = tostring(message) }
    if #lines > limit then
      table.remove(lines, 1)
    end
  end

  return log.check({
    info = function(message)
      record("info", message)
    end,
    warn = function(message)
      record("warn", message)
    end,
    error = function(message)
      record("error", message)
    end,
    recent = function(count)
      local out = {}
      local first = math.max(1, #lines - (count or #lines) + 1)
      for index = first, #lines do
        out[#out + 1] = lines[index]
      end
      return out
    end,
  })
end

return log
