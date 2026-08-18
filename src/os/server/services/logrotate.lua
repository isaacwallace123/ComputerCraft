--- Keeping the log from filling the disk, without throwing away the useful half.
---
--- ## The bug this exists to fix
---
--- `core/log.lua` trims on open. A machine that is rebooted daily is fine; a
--- base station is not rebooted, and §2's whole premise is that a server is
--- permanently loaded. So the one machine that runs for weeks is the one machine
--- whose log was never trimmed, and the disk it fills is the disk holding the
--- registry, the mine and the drop-offs.
---
--- ## Rotating, not truncating
---
--- ICOS 1 keeps the last 400 lines and drops the rest. That is the wrong end.
--- When something goes wrong at 3am and is noticed at 9am, the interesting lines
--- are the first ones after it started - the cause - and truncation keeps six
--- hours of consequences and deletes the cause.
---
--- So the current file is moved aside to `.log.1` and a fresh one started. Two
--- files, one generation of history, and the window in which the cause survives
--- is doubled at the cost of one file. `.log.1` is overwritten on the next
--- rotation rather than kept as `.log.2`: unbounded history is the problem this
--- service exists to solve, and solving it by keeping everything would be funny.
---
--- ## It cannot use `core/log.lua`
---
--- Which is the point. A service that logged about rotating the log would write
--- lines to the file it is trying to shrink, and on a full disk the write it
--- makes is the write that fails. It returns what it did and lets the caller
--- decide whether that is worth saying.

local service = require("os.service")

local logrotate = {}

logrotate.PATH = ".log"
logrotate.PREVIOUS = ".log.1"

--- Lines kept before rotating.
---
--- Matched to `core/log.lua`'s own cap so the two do not fight: a service that
--- rotated at 100 while the logger trimmed at 400 would rotate on every pass and
--- fill the disk with the churn it was hired to prevent.
logrotate.MAX_LINES = 400

--- Seconds between checks.
---
--- A minute. The log grows by lines, not megabytes, and the failure it guards
--- against takes days to arrive - so this is the cheapest thing on the machine
--- and should stay that way.
logrotate.EVERY = 60

--- How many lines are in this text.
---
--- Counted rather than measured in bytes, because the cap is expressed in lines
--- and because a log of long lines is not more urgent than a log of short ones -
--- it is the same number of events.
function logrotate.lines(text)
  if type(text) ~= "string" or text == "" then
    return 0
  end
  local count = 0
  for _ in text:gmatch("\n") do
    count = count + 1
  end
  -- A final line with no trailing newline is still a line.
  if text:sub(-1) ~= "\n" then
    count = count + 1
  end
  return count
end

--- Should this be rotated?
---
--- Separated so a spec can ask the question without a filesystem, and so the
--- rule is one function rather than a comparison buried in a loop.
function logrotate.due(text, maxLines)
  return logrotate.lines(text) >= (maxLines or logrotate.MAX_LINES)
end

--- Move the log aside and start a fresh one.
---
--- Returns the number of lines rotated, or 0 for "nothing to do". The order
--- matters: the previous generation is written before the current one is
--- cleared, so a crash between the two leaves two copies of the same lines
--- rather than none. Duplicated history is a nuisance; deleted history is the
--- thing that was worth keeping.
function logrotate.rotate(context, options)
  options = options or {}
  local path = options.path or logrotate.PATH
  local previous = options.previous or logrotate.PREVIOUS

  local text = context.storage.read(path)
  if not logrotate.due(text, options.maxLines) then
    return 0
  end

  local count = logrotate.lines(text)
  if not context.storage.write(previous, text) then
    -- The disk is full or read-only, which is exactly the situation this
    -- service exists for - and exactly the situation in which clearing the
    -- current log would destroy the evidence of it. Leave everything alone.
    return 0
  end
  context.storage.write(path, "")
  return count
end

logrotate.service = service.define({
  id = "logrotate",
  requires = { "storage", "clock" },

  -- Not critical. A server with a large log still answers every turtle; it just
  -- has less room than it should. The failure is slow enough that a person will
  -- see it on the Services page long before it matters.
  critical = false,

  run = function(context)
    while true do
      logrotate.rotate(context)
      context.clock.sleep(context.rotateEvery or logrotate.EVERY)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return logrotate
