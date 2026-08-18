--- Keyboard console shown on the physical computer while the monitor runs the
--- ICOS desktop. It tails the shared log and turns short commands into the
--- same rednet orders used by the Fleet and Devices apps.

local ui = require("core.ui")
local net = require("core.net")
local log = require("core.log")
local config = require("core.config")
local boot = require("core.boot")
local version = require("core.version")
local device = require("core.device")
local util = require("core.util")
local coordinator = require("fleet.coordinator")
local minePlan = require("domain.mine.plan")
local mineRegistry = require("domain.mine.registry")

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
    return util.naturalLess(labelFor(a.id, a.node), labelFor(b.id, b.node))
  end)

  if #rows == 0 then
    log.warn("console: no paired devices")
    return
  end

  log.info(("console: %d paired device(s)"):format(#rows))
  for _, row in ipairs(rows) do
    local snap = row.node.snap or {}
    log.info(
      ("  #%s %-12s v%-7s %-8s fuel %s"):format(
        tostring(row.id),
        labelFor(row.id, row.node):sub(1, 12),
        tostring(snap.version or "?"),
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

local function showSystem()
  local node = config.load(".node", {})
  local caps = device.capabilities()
  local modem = caps.modem and (caps.wireless and "wireless" or "wired") or "MISSING"
  log.info(("system: ICOS v%s  id #%d  role %s"):format(version, caps.id, node.role or "unset"))
  log.info(("hardware: modem %s  monitor %s"):format(modem, caps.monitor and "yes" or "none"))
  if node.role ~= "fleet" then
    log.warn("system: Fleet apps require role fleet - type `setup`")
  elseif not caps.modem then
    log.warn("system: Fleet is offline - attach a modem")
  end
end

--- Place the shared mine, or report where it already is.
---
--- `mine here` uses the base computer's own position, which is almost always
--- what you want: sectors are laid out around the base, and the turtles fly home
--- to their own chests beside it.
local function mineCommand(words)
  local action = words[2] and words[2]:lower()

  if action == "here" or action == "at" then
    local x, y, z
    if action == "at" then
      x, y, z = tonumber(words[3]), tonumber(words[4]), tonumber(words[5])
      if not (x and y and z) then
        log.warn("console: mine at <x> <y> <z>")
        return
      end
    else
      x, y, z = gps.locate(2, false)
      if not x then
        log.warn("console: no GPS - use `mine at <x> <y> <z>`")
        return
      end
    end

    if y < -63 or y > 310 then
      log.warn("console: mine surface must be Y -63..310 so cruise lanes fit")
      return
    end

    local placed, moved = coordinator.setMine({
      centreX = math.floor(x),
      centreZ = math.floor(z),
      surfaceY = math.floor(y),
      cruiseY = math.floor(y) + 8,
    })
    log.info(
      ("console: mine centred on %d,%d surface Y %d, %d sectors of %d blocks"):format(
        placed.centreX,
        placed.centreZ,
        placed.surfaceY,
        minePlan.capacity(placed),
        placed.cellSize
      )
    )
    if moved then
      log.warn("console: sector progress cleared - the grid moved")
    end
    return
  end

  if action == "size" or action == "rings" or action == "keepout" then
    local value = tonumber(words[3])
    if not value then
      log.warn("console: mine size <blocks> | mine rings <1-8> | mine keepout <blocks>")
      return
    end
    value = math.floor(value)

    local state = coordinator.mineState()
    if not state.plan.configured then
      log.warn("console: place the mine first with `mine here` or `mine at <x> <y> <z>`")
      return
    end

    local fields
    if action == "size" then
      fields = { cellSize = value }
    elseif action == "rings" then
      fields = { maxRing = value }
    else
      -- A keep-out radius in blocks is really a minimum ring. Rounded up, since
      -- asking for 100 blocks of clearance and getting 96 is the wrong way to
      -- miss.
      fields = { minRing = minePlan.ringForKeepout(state.plan, value) }
    end

    local placed, cleared = coordinator.setMine(fields)
    log.info(
      ("console: sectors %d blocks across, %d available, digging starts %d blocks out"):format(
        placed.cellSize,
        minePlan.capacity(placed),
        minePlan.keepout(placed)
      )
    )
    if cleared then
      log.warn("console: sector progress cleared - the grid moved")
    end
    return
  end

  local state = coordinator.mineState()
  if not state.plan.configured then
    log.warn("console: no mine yet - run `mine here` on the base")
    return
  end

  log.info(
    ("mine: centre %d,%d  surface Y %d  cruise Y %d"):format(
      state.plan.centreX,
      state.plan.centreZ,
      state.plan.surfaceY,
      state.plan.cruiseY
    )
  )
  log.info(
    ("mine: %d sectors of %d blocks, digging starts %d blocks out"):format(
      minePlan.capacity(state.plan),
      state.plan.cellSize,
      minePlan.keepout(state.plan)
    )
  )

  local rows = mineRegistry.summary(state)
  if #rows == 0 then
    log.info("mine: no sectors opened yet")
    return
  end
  for _, row in ipairs(rows) do
    log.info(
      ("  sector %-3d %-14s shaft %6d,%-6d %3d/%-3d %s"):format(
        row.index,
        row.workKey or "unknown",
        row.shaftX or 0,
        row.shaftZ or 0,
        row.frontier,
        row.length,
        row.exhausted and "worked out" or (row.holder and ("held by #" .. row.holder) or "free")
      )
    )
  end
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
      ui.header(name .. " v" .. version .. " CONSOLE", "fleet logs + commands")

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
      log.info("console: about | open devices <device> | clear | update | setup | reboot | exit")
      log.info("console: quarry <x1> <z1> <x2> <z2> <topY> <bottomY>")
      log.info("console: mine | mine here | mine at <x> <y> <z>")
      log.info("console: mine size <n> | mine rings <n> | mine keepout <blocks>")
    elseif command == "about" or command == "system" then
      showSystem()
    elseif command == "status" or command == "devices" or command == "list" then
      listDevices()
    elseif command == "recall" or command == "deploy" then
      sendAction(command, words[2])
    elseif command == "refresh" then
      sendAction("status_request", words[2])
    elseif command == "quarry" then
      local x1, z1 = tonumber(words[2]), tonumber(words[3])
      local x2, z2 = tonumber(words[4]), tonumber(words[5])
      local topY, bottomY = tonumber(words[6]), tonumber(words[7])
      if not (x1 and z1 and x2 and z2 and topY and bottomY) then
        log.warn("console: quarry <x1> <z1> <x2> <z2> <topY> <bottomY>")
      else
        local ok, message = coordinator.quarry({
          x1 = math.floor(x1),
          z1 = math.floor(z1),
          x2 = math.floor(x2),
          z2 = math.floor(z2),
          topY = math.floor(math.max(topY, bottomY)),
          bottomY = math.floor(math.min(topY, bottomY)),
        })
        if ok then
          log.info("console: " .. message)
        else
          log.error("console: " .. message)
        end
      end
    elseif command == "mine" then
      mineCommand(words)
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

  showSystem()
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
