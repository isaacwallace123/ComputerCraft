--- Keyboard console shown on the physical computer while the monitor runs the
--- ICOS desktop. It tails the shared log and turns short commands into the
--- same rednet orders used by the Fleet and Devices apps.

local ui = require("core.ui")
local net = require("core.net")
local log = require("core.log")
local config = require("core.config")
local boot = require("core.boot")

local console = {}

local ROSTER_PATH = ".fleet"

local function roster()
  return config.load(ROSTER_PATH, {})
end

local function labelFor(id, node)
  return tostring((node.snap and node.snap.label) or id)
end

local function resolveTarget(word)
  if not word or word == "" or word:lower() == "all" then
    return nil, "all"
  end

  local wanted = word:lower()
  local saved = roster()
  for id, node in pairs(saved) do
    if tostring(id) == word or labelFor(id, node):lower() == wanted then
      return tonumber(id), labelFor(id, node)
    end
  end
  return false, word
end

local function sendAction(action, word)
  local id, label = resolveTarget(word)
  if id == false then
    log.warn("console: unknown device " .. tostring(label))
    return
  end

  local sent
  if id then
    sent = net.send(id, "command", { action = action })
  else
    sent = net.broadcast("command", { action = action })
  end

  local destination = id and label or "all devices"
  if sent then
    log.info(("console: %s -> %s"):format(action, destination))
  else
    log.error("console: command failed - no modem available")
  end
end

local function listDevices()
  local saved = roster()
  local rows = {}
  for id, node in pairs(saved) do
    rows[#rows + 1] = { id = id, node = node }
  end
  table.sort(rows, function(a, b)
    return labelFor(a.id, a.node) < labelFor(b.id, b.node)
  end)

  if #rows == 0 then
    log.warn("console: no paired devices")
    return
  end

  log.info(("console: %d paired device(s)"):format(#rows))
  for _, row in ipairs(rows) do
    local snap = row.node.snap or {}
    log.info(
      ("  #%s %-12s %-8s fuel %s"):format(
        tostring(row.id),
        labelFor(row.id, row.node):sub(1, 12),
        tostring(snap.phase or "unknown"),
        tostring(snap.fuel or "?")
      )
    )
  end
end

local function openDevice(word)
  local id, label = resolveTarget(word)
  if id == false or id == nil then
    log.warn("console: use `open devices <id|name>`")
    return
  end
  os.queueEvent("icos_open_app", "devices", { deviceId = id })
  log.info("console: opened " .. label .. " on monitor")
end

local HELP = "help | status | recall [all|device] | deploy [all|device] | refresh [all|device]"

function console.run(target, opts)
  opts = opts or {}
  local name = opts.name or "ICOS"
  local input = ""
  local history = {}
  local historyIndex = nil
  local running = true

  local function onTarget(fn)
    local previous = term.redirect(target)
    local ok, err = pcall(fn)
    term.redirect(previous)
    if not ok then
      error(err, 0)
    end
  end

  local function draw()
    onTarget(function()
      local width, height = term.getSize()
      ui.clear()
      ui.header(name .. " CONSOLE", "fleet logs + commands")

      local lines = log.readRecent(math.max(1, height - 3))
      for index, line in ipairs(lines) do
        local color = ui.theme.fg
        if line:find("ERROR", 1, true) then
          color = ui.theme.bad
        elseif line:find("WARN", 1, true) then
          color = ui.theme.warn
        end
        ui.text(1, index + 1, ui.pad(line, width), color)
      end

      ui.row(height, ui.theme.headerBg)
      local available = math.max(1, width - 3)
      local shown = input
      if #shown > available then
        shown = shown:sub(#shown - available + 1)
      end
      ui.text(1, height, "> ", ui.theme.accent, ui.theme.headerBg)
      ui.text(3, height, shown, ui.theme.headerFg, ui.theme.headerBg)
      term.setCursorPos(math.min(width, 3 + #shown), height)
      term.setCursorBlink(true)
    end)
  end

  local function runProgram(program, ...)
    local args = { ... }
    onTarget(function()
      term.setCursorBlink(false)
      ui.clear()
      shell.run(program, table.unpack(args))
    end)
  end

  local function execute(line)
    local words = {}
    for word in line:gmatch("%S+") do
      words[#words + 1] = word
    end
    local command = words[1] and words[1]:lower()
    if not command then
      return
    end

    history[#history + 1] = line
    historyIndex = nil

    if command == "help" or command == "?" then
      log.info("console: " .. HELP)
      log.info("console: open devices <device> | clear | update | setup | reboot | exit")
    elseif command == "status" or command == "devices" or command == "list" then
      listDevices()
    elseif command == "recall" or command == "deploy" then
      sendAction(command, words[2])
    elseif command == "refresh" then
      sendAction("status_request", words[2])
    elseif command == "open" and words[2] and words[2]:lower() == "devices" then
      openDevice(words[3])
    elseif command == "clear" then
      log.clear()
    elseif command == "update" then
      runProgram("update.lua")
      log.info("console: update finished")
    elseif command == "setup" then
      runProgram("install.lua")
      log.info("console: setup closed")
    elseif command == "reboot" then
      onTarget(boot.reboot)
    elseif command == "exit" or command == "quit" then
      running = false
    else
      log.warn("console: unknown command `" .. command .. "` - type `help`")
    end
  end

  log.info("physical console ready - type `help`")
  draw()
  local refresh = os.startTimer(1)

  while running do
    local event = { os.pullEventRaw() }
    local kind = event[1]
    if kind == "terminate" then
      running = false
    elseif kind == "char" or kind == "paste" then
      input = input .. event[2]
    elseif kind == "key" then
      if event[2] == keys.backspace then
        input = input:sub(1, -2)
      elseif event[2] == keys.enter then
        local line = input
        input = ""
        execute(line)
      elseif event[2] == keys.up and #history > 0 then
        historyIndex = math.max(1, (historyIndex or (#history + 1)) - 1)
        input = history[historyIndex]
      elseif event[2] == keys.down and historyIndex then
        historyIndex = historyIndex + 1
        if historyIndex > #history then
          historyIndex = nil
          input = ""
        else
          input = history[historyIndex]
        end
      end
    elseif kind == "timer" and event[2] == refresh then
      refresh = os.startTimer(1)
    end

    if
      kind == "icos_log"
      or kind == "term_resize"
      or kind == "timer"
      or kind == "key"
      or kind == "char"
      or kind == "paste"
    then
      draw()
    end
  end

  onTarget(function()
    term.setCursorBlink(false)
    ui.clear()
  end)
end

return console
