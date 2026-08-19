--- Logging to a capped file plus an in-memory ring buffer.
---
--- The ring buffer is what the fleet dashboard shows; the file is what you read
--- with `edit .log` after something went wrong while you were asleep.
---
--- ## Trimming on load was not enough, and a base station proved it
---
--- This file used to trim exactly once, at `require` time. A turtle reboots most
--- days and was fine; a base station is never rebooted - that is the whole
--- premise of a server - so the one machine whose log actually grows without
--- bound was the one machine that never trimmed it. It filled its disk, and the
--- write below threw `Out of space` straight through `log.info` into whichever
--- app happened to be logging, which put a stack trace across a running desktop.
---
--- Two things come out of that, and they are separate:
---
---   * **A logger may never take down its caller.** Every path here is now
---     best-effort. A line that cannot be written is dropped, because the
---     alternative - stopping the fleet service to complain about a log - is
---     always worse than losing the sentence.
---   * **Trimming happens on a counter, not on load.** Every `TRIM_EVERY` lines,
---     so a machine that runs for a month trims about as often as one that
---     reboots daily.
---
--- `os/server/services/logrotate.lua` is the ICOS 2 half of the same problem and
--- rotates rather than truncates, which keeps the *cause* of a 3am failure
--- instead of six hours of its consequences. This is the floor underneath it.

local log = {}

local PATH = ".log"
local MAX_FILE_LINES = 400
local MAX_MEMORY_LINES = 64

--- Lines written between trims.
---
--- A quarter of the cap, so a trim reclaims a meaningful amount and the read of
--- the whole file that a trim costs happens once per hundred lines rather than
--- once per line. Deliberately not tied to the cap by arithmetic: the two answer
--- different questions, and somebody raising the cap should not silently make
--- trimming rarer.
local TRIM_EVERY = 100

local buffer = {}
local echo = false
local sinceTrim = 0

local function stamp()
  return textutils.formatTime(os.time(), true)
end

--- Keep the log file from growing without bound.
---
--- Every read and every write is guarded, because this is called from `write`
--- and the whole point of that call site is that it cannot be allowed to raise.
--- A trim that fails leaves the file exactly as it was, which is the safe
--- outcome: too long is a disk problem, and half-written is a lost log.
local function trim()
  sinceTrim = 0

  local ok, lines = pcall(function()
    if not fs.exists(PATH) then
      return nil
    end
    local handle = fs.open(PATH, "r")
    if not handle then
      return nil
    end
    local read = {}
    for line in handle.readLine do
      read[#read + 1] = line
    end
    handle.close()
    return read
  end)

  if not ok or type(lines) ~= "table" or #lines <= MAX_FILE_LINES then
    return
  end

  pcall(function()
    local out = fs.open(PATH, "w")
    if not out then
      return
    end
    -- Truncating to the newest lines can only ever free space, so this is the
    -- one write in this file that is worth attempting on a disk that is already
    -- full - it is the write that unfills it.
    for i = #lines - MAX_FILE_LINES + 1, #lines do
      out.writeLine(lines[i])
    end
    out.close()
  end)
end

trim()

--- Mirror log lines to the terminal as well. Off by default so dashboards are
--- not scribbled over.
function log.echo(enabled)
  echo = enabled and true or false
end

local function write(level, message, color)
  local line = ("[%s] %-5s %s"):format(stamp(), level, message)

  buffer[#buffer + 1] = { text = line, color = color, at = os.epoch("utc") }
  while #buffer > MAX_MEMORY_LINES do
    table.remove(buffer, 1)
  end

  -- Guarded, and the guard is the point.
  --
  -- `fs.open` returning nil is the failure this used to check for and is not the
  -- failure that happens. A full disk surfaces from `writeLine` as a thrown
  -- error - which used to travel out of `log.info` and stop whatever was logging
  -- - and it leaves the handle open on the way past, so every subsequent attempt
  -- leaked one of a small pool. Closing in all cases matters as much as not
  -- raising.
  local handle = fs.open(PATH, "a")
  if handle then
    pcall(handle.writeLine, line)
    pcall(handle.close)
  end

  -- Counted after the write rather than before, so a machine whose disk is
  -- already full still reaches the trim that might unfill it.
  sinceTrim = sinceTrim + 1
  if sinceTrim >= TRIM_EVERY then
    trim()
  end

  -- The physical ICOS console listens for this so new fleet messages appear
  -- immediately instead of waiting for its refresh timer.
  os.queueEvent("icos_log", level, message)

  if echo then
    local previous = term.getTextColor()
    term.setTextColor(color)
    print(line)
    term.setTextColor(previous)
  end
end

function log.info(message)
  write("INFO", message, colors.white)
end

function log.warn(message)
  write("WARN", message, colors.yellow)
end

function log.error(message)
  write("ERROR", message, colors.red)
end

--- Most recent `count` entries, oldest first.
function log.recent(count)
  local out = {}
  for i = math.max(1, #buffer - count + 1), #buffer do
    out[#out + 1] = buffer[i]
  end
  return out
end

--- Most recent persisted lines, oldest first. Unlike `recent`, this survives a
--- reboot and can also see messages written by another running ICOS task.
function log.readRecent(count)
  if not fs.exists(PATH) then
    return {}
  end

  local handle = fs.open(PATH, "r")
  if not handle then
    return {}
  end

  local lines = {}
  for line in handle.readLine do
    lines[#lines + 1] = line
  end
  handle.close()

  local out = {}
  for i = math.max(1, #lines - count + 1), #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

function log.clear()
  local handle = fs.open(PATH, "w")
  if handle then
    handle.close()
  end
  buffer = {}
  sinceTrim = 0
  os.queueEvent("icos_log", "INFO", "log cleared")
end

return log
