--- Logging to a capped file plus an in-memory ring buffer.
---
--- The ring buffer is what the fleet dashboard shows; the file is what you read
--- with `edit .log` after something went wrong while you were asleep. The file
--- is trimmed on open so a turtle running for days cannot fill its disk.

local log = {}

local PATH = ".log"
local MAX_FILE_LINES = 400
local MAX_MEMORY_LINES = 64

local buffer = {}
local echo = false

local function stamp()
  return textutils.formatTime(os.time(), true)
end

--- Keep the log file from growing without bound.
local function trim()
  if not fs.exists(PATH) then
    return
  end
  local handle = fs.open(PATH, "r")
  if not handle then
    return
  end

  local lines = {}
  for line in handle.readLine do
    lines[#lines + 1] = line
  end
  handle.close()

  if #lines <= MAX_FILE_LINES then
    return
  end

  local out = fs.open(PATH, "w")
  if not out then
    return
  end
  for i = #lines - MAX_FILE_LINES + 1, #lines do
    out.writeLine(lines[i])
  end
  out.close()
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

  local handle = fs.open(PATH, "a")
  if handle then
    handle.writeLine(line)
    handle.close()
  end

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

return log
