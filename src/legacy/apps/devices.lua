--- Paired-device browser and per-turtle remote control.
---
--- The always-on fleet service owns discovery and writes `.fleet`; this app owns the
--- detail/configuration UI so the fleet overview can stay dense and scalable.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("legacy.shell.ui")
local net = require("legacy.net")
local log = require("adapters.cc.logfile")
local util = require("lib.util")
local version = require("lib.version")
local control = require("legacy.fleet.control")
local rosterStore = require("legacy.fleet.roster")

local COLUMNS = {
  { title = "NAME", width = 12 },
  { title = "VERSION", width = 7 },
  { title = "STATE", width = 9 },
  { title = "JOB", width = 9 },
  { title = "FUEL", width = 7, align = "right" },
  { title = "SEEN", width = 6, align = "right" },
}

local view = "list"
local selectedId = nil
local scroll = 0
local settingsScroll = 0
local clickTargets = {}
local rowTargets = {}
local notice = nil
local running = true

local JOB_ORDER = { "quarry", "rare", "fuel", "hollow", "resources" }

local function roster()
  return rosterStore.load()
end

local function age(node)
  return rosterStore.age(node)
end

local function statusColor(node)
  local snap = node.snap or {}
  if age(node) > rosterStore.OFFLINE_AFTER or snap.phase == "stuck" then
    return ui.theme.bad
  elseif age(node) > rosterStore.LATE_AFTER then
    return ui.theme.warn
  elseif snap.phase == "parked" then
    return ui.theme.accent
  end
  return ui.theme.good
end

local function nodes(saved)
  return rosterStore.sorted(saved)
end

local function selectedNode(saved)
  return selectedId and saved[tostring(selectedId)] or nil
end

local function positionText(snap)
  local point = snap.world or snap
  return ("%d,%d,%d"):format(point.x or 0, point.y or 0, point.z or 0)
end

local function versionCell(snap)
  if not snap.version then
    return { text = "unknown", color = ui.theme.dim }
  end
  return {
    text = "v" .. tostring(snap.version),
    color = snap.version == version and ui.theme.good or ui.theme.warn,
  }
end

local function setNotice(message, ok)
  notice = {
    text = tostring(message),
    color = ok == false and ui.theme.bad or ui.theme.good,
    untilAt = os.epoch("utc") + 5000,
  }
end

local function addButton(x, y, label, action, data)
  local text = " " .. label .. " "
  ui.text(x, y, text, ui.theme.bg, ui.theme.headerFg)
  clickTargets[#clickTargets + 1] = {
    from = x,
    to = x + #text - 1,
    y = y,
    action = action,
    data = data,
  }
  return x + #text + 1
end

local function footer(buttons)
  local width, height = ui.size()
  ui.row(height, ui.theme.headerBg)
  local x = 2
  for _, button in ipairs(buttons) do
    if x + #button[1] + 1 <= width then
      x = addButton(x, height, button[1], button[2], button[3])
    end
  end
end

local function drawNotice(width, height)
  if notice and os.epoch("utc") <= notice.untilAt and height > 4 then
    ui.text(2, height - 1, ui.pad(notice.text, width - 3), notice.color)
  end
end

local function sendSelected(action, extra)
  local id = tonumber(selectedId)
  if not id then
    setNotice("No device selected", false)
    return false
  end

  local body = extra or {}
  body.action = action
  if net.send(id, "command", body) then
    log.info(("devices: %s -> #%d"):format(action, id))
    setNotice(action .. " sent", true)
    return true
  end
  log.error("devices: could not send command - no modem")
  setNotice("Command could not be sent", false)
  return false
end

local function drawList(saved)
  local width, height = ui.size()
  local list = nodes(saved)
  local online = 0
  for _, node in ipairs(list) do
    if age(node) <= rosterStore.OFFLINE_AFTER then
      online = online + 1
    end
  end

  local maxRows = math.max(1, height - 5)
  local maxScroll = math.max(0, #list - maxRows)
  scroll = math.max(0, math.min(scroll, maxScroll))
  local first = #list == 0 and 0 or scroll + 1
  local last = math.min(#list, scroll + maxRows)

  ui.clear()
  local status = width < 42 and ("%d/%d"):format(online, #list)
    or ("%d/%d connected  %d-%d"):format(online, #list, first, last)
  ui.header("DEVICES", status)
  clickTargets, rowTargets = {}, {}

  if #list == 0 then
    ui.center(math.floor(height / 2), "No paired devices yet.", ui.theme.dim)
    ui.center(math.floor(height / 2) + 2, "Waiting for fleet service.", ui.theme.dim)
  else
    local rows = {}
    for index = first, last do
      local node = list[index]
      local snap = node.snap or {}
      rows[#rows + 1] = {
        color = statusColor(node),
        cells = {
          snap.label or ("id " .. tostring(node.id)),
          versionCell(snap),
          age(node) > rosterStore.OFFLINE_AFTER and "offline" or (snap.phase or "unknown"),
          snap.job or "none",
          snap.fuel == -1 and "unlim" or util.count(snap.fuel or 0),
          util.duration(age(node)),
        },
      }
      rowTargets[#rowTargets + 1] = { y = 4 + #rows - 1, id = node.id }
    end
    ui.table(2, 3, width - 2, COLUMNS, rows, maxRows)
  end

  drawNotice(width, height)
  footer(width < 42 and {
    { "up", "up" },
    { "down", "down" },
    { "actions", "actions" },
  } or {
    { "up", "up" },
    { "down", "down" },
    { "refresh", "refresh_all" },
    { "update all", "update_all" },
  })
end

local function drawDevice(saved)
  local width, height = ui.size()
  local node = selectedNode(saved)
  if not node then
    view, selectedId = "list", nil
    drawList(saved)
    return
  end

  local snap = node.snap or {}
  local label = snap.label or ("id " .. tostring(selectedId))
  local connected = age(node) <= rosterStore.OFFLINE_AFTER
  ui.clear()
  ui.header(label .. "  #" .. tostring(selectedId), connected and "connected" or "offline")
  clickTargets, rowTargets = {}, {}

  ui.text(2, 3, ("%-10s %s"):format("state", snap.phase or "unknown"), statusColor(node))
  if width >= 46 then
    addButton(width - 19, 3, "update", "update")
    addButton(width - 9, 3, "forget", "forget")
  end
  ui.text(2, 4, ui.pad(snap.detail or "", width - 3), ui.theme.dim)
  ui.text(
    2,
    5,
    ("%-10s v%s"):format("version", tostring(snap.version or "unknown")),
    snap.version == version and ui.theme.good or ui.theme.warn
  )
  ui.text(2, 6, ("%-10s %s"):format("job", snap.job or "none"))
  ui.text(2, 7, ("%-10s %s"):format("position", positionText(snap)))

  local fuel = snap.fuel == -1 and "unlimited" or util.count(snap.fuel or 0)
  if snap.parked and snap.fuelRequired and snap.fuel ~= -1 then
    fuel = fuel .. " / " .. util.count(snap.fuelRequired) .. " needed"
  else
    fuel = fuel .. ("  (%d home)"):format(snap.distanceHome or 0)
  end
  local fuelColor = ui.theme.fg
  if snap.parked and snap.fuelRequired and snap.fuel ~= -1 and snap.fuel < snap.fuelRequired then
    fuelColor = ui.theme.bad
  end
  ui.text(2, 8, ("%-10s %s"):format("fuel", fuel), fuelColor)
  if snap.fuelTank ~= nil and snap.fuelTank >= 0 then
    ui.text(
      2,
      9,
      ("%-10s %s tank + %s carried"):format(
        "breakdown",
        util.count(snap.fuelTank),
        util.count(snap.fuelReserve or 0)
      ),
      ui.theme.dim
    )
  end

  local progress = snap.progress or 0
  ui.text(2, 10, ("%-10s %d%%"):format("progress", math.floor(progress * 100)))
  ui.bar(12, 10, math.max(6, width - 14), progress, ui.theme.accent)
  ui.text(
    2,
    12,
    ("%-10s %s dug  %s delivered"):format(
      "totals",
      util.count(snap.digs or 0),
      util.count(snap.delivered or 0)
    )
  )

  if height > 15 then
    local settings = snap.settings or {}
    local parts = {}
    for index, field in ipairs(snap.settingFields or {}) do
      if index <= 3 then
        parts[#parts + 1] = field.label .. " " .. tostring(settings[field.key] or "?")
      end
    end
    if #parts > 0 then
      ui.text(2, 14, ui.pad(table.concat(parts, "  "), width - 3), ui.theme.dim)
    end
  end

  drawNotice(width, height)
  footer(width < 42 and {
    { "back", "back" },
    { "actions", "actions" },
  } or {
    { "back", "back" },
    { "deploy", "deploy" },
    { "recall", "recall" },
    { "config", "settings" },
    { "job", "job" },
    { "refresh", "refresh" },
  })
end

local function drawSettings(saved)
  local width, height = ui.size()
  local node = selectedNode(saved)
  if not node then
    view = "list"
    drawList(saved)
    return
  end

  local snap = node.snap or {}
  local settings = snap.settings or {}
  local fields = snap.settingFields or {}
  local visible = math.max(1, math.floor((height - 6) / 3))
  settingsScroll = math.max(0, math.min(settingsScroll, math.max(0, #fields - visible)))

  ui.clear()
  ui.header((snap.label or tostring(selectedId)) .. " CONFIG", snap.job or "")
  ui.text(2, 3, "Park the turtle before changing its next run.", ui.theme.dim)
  clickTargets, rowTargets = {}, {}

  for index = settingsScroll + 1, math.min(#fields, settingsScroll + visible) do
    local field = fields[index]
    local y = 5 + (index - settingsScroll - 1) * 3
    local value = tonumber(settings[field.key]) or 0
    local compact = width < 42
    local labelWidth = compact and math.max(6, width - 16) or 12
    local valueX = compact and math.max(9, width - 13) or 16
    local valueWidth = compact and 5 or 7
    ui.text(compact and 2 or 3, y, ui.pad(field.label, labelWidth), ui.theme.fg)
    ui.text(valueX, y, ui.pad(value, valueWidth, "right"), ui.theme.accent)
    local x = compact and math.max(valueX + valueWidth + 1, width - 7) or math.max(25, width - 15)
    x = addButton(x, y, "-", "adjust", { field = field.key, value = value - field.step })
    addButton(x, y, "+", "adjust", { field = field.key, value = value + field.step })
  end

  drawNotice(width, height)
  footer(width < 42 and {
    { "back", "device" },
    { "actions", "actions" },
  } or {
    { "back", "device" },
    { "up", "settings_up" },
    { "down", "settings_down" },
    { "deploy", "deploy" },
  })
end

local function draw()
  local saved = roster()
  if view == "device" then
    drawDevice(saved)
  elseif view == "settings" then
    drawSettings(saved)
  else
    drawList(saved)
  end
end

local act
act = function(action, data)
  if action == "up" then
    scroll = math.max(0, scroll - 1)
  elseif action == "down" then
    scroll = scroll + 1
  elseif action == "back" then
    view, selectedId = "list", nil
  elseif action == "device" then
    view = "device"
  elseif action == "deploy" or action == "recall" or action == "refresh" then
    sendSelected(action == "refresh" and "status_request" or action)
  elseif action == "refresh_all" then
    if net.broadcast("command", { action = "status_request" }) then
      control.requestSync()
      setNotice("Status requested", true)
      log.info("devices: status refresh requested")
    else
      setNotice("No modem available", false)
    end
  elseif action == "update" then
    sendSelected("update")
  elseif action == "update_all" then
    if net.broadcast("command", { action = "update" }) then
      setNotice("Update queued for connected devices", true)
      log.warn("devices: update sent to all connected devices")
    else
      setNotice("No modem available", false)
    end
  elseif action == "settings" then
    settingsScroll = 0
    view = "settings"
  elseif action == "job" then
    local node = selectedNode(roster())
    local current = node and node.snap and node.snap.job
    local nextJob = JOB_ORDER[1]
    for index, name in ipairs(JOB_ORDER) do
      if name == current then
        nextJob = JOB_ORDER[index % #JOB_ORDER + 1]
        break
      end
    end
    if sendSelected("set_job", { job = nextJob }) then
      local saved = roster()
      local savedNode = selectedNode(saved)
      if savedNode and savedNode.snap then
        savedNode.snap.job = nextJob
        rosterStore.save(saved)
      end
      setNotice("Changing job to " .. nextJob, true)
    end
  elseif action == "settings_up" then
    settingsScroll = math.max(0, settingsScroll - 1)
  elseif action == "settings_down" then
    settingsScroll = settingsScroll + 1
  elseif action == "adjust" and data then
    if sendSelected("configure", { settings = { [data.field] = data.value } }) then
      local saved = roster()
      local node = selectedNode(saved)
      if node and node.snap then
        node.snap.settings = node.snap.settings or {}
        node.snap.settings[data.field] = data.value
        rosterStore.save(saved)
      end
    end
  elseif action == "forget" and selectedId then
    local ok, err = control.forget(selectedId)
    selectedId, view = nil, "list"
    setNotice(ok and "Device forgotten" or err, ok)
  elseif action == "actions" then
    local labels, actions
    if view == "list" then
      labels = { "Refresh all", "Update all", "Cancel" }
      actions = { "refresh_all", "update_all" }
    elseif view == "settings" then
      labels = { "Deploy", "Back to device", "Cancel" }
      actions = { "deploy", "device" }
    else
      labels = {
        "Deploy",
        "Recall",
        "Configure",
        "Change job",
        "Refresh",
        "Update",
        "Forget",
        "Cancel",
      }
      actions = { "deploy", "recall", "settings", "job", "refresh", "update", "forget" }
    end
    local choice = ui.menu("DEVICE ACTIONS", labels)
    if choice and actions[choice] then
      act(actions[choice])
    end
  end
end

draw()
local refreshTimer = os.startTimer(1)

while running do
  local event = { os.pullEvent() }
  local kind = event[1]
  if kind == "icos_close" then
    running = false
  elseif kind == "icos_open" and type(event[2]) == "table" and event[2].deviceId then
    selectedId = event[2].deviceId
    view = "device"
    sendSelected("status_request")
  elseif kind == "timer" and event[2] == refreshTimer then
    refreshTimer = os.startTimer(1)
  elseif kind == "mouse_scroll" then
    if view == "list" then
      scroll = math.max(0, scroll + event[2])
    elseif view == "settings" then
      settingsScroll = math.max(0, settingsScroll + event[2])
    end
  elseif kind == "key" then
    if event[2] == keys.q then
      running = false
    elseif view == "list" and event[2] == keys.up then
      act("up")
    elseif view == "list" and event[2] == keys.down then
      act("down")
    elseif view == "settings" and event[2] == keys.up then
      act("settings_up")
    elseif view == "settings" and event[2] == keys.down then
      act("settings_down")
    elseif view ~= "list" and (event[2] == keys.backspace or event[2] == keys.left) then
      act(view == "settings" and "device" or "back")
    elseif event[2] == keys.enter then
      act("actions")
    end
  elseif kind == "mouse_click" then
    if view == "list" then
      for _, row in ipairs(rowTargets) do
        if event[4] == row.y then
          selectedId, view = row.id, "device"
          sendSelected("status_request")
          break
        end
      end
    end
    for _, target in ipairs(clickTargets) do
      if event[4] == target.y and event[3] >= target.from and event[3] <= target.to then
        act(target.action, target.data)
        break
      end
    end
  end
  draw()
end

ui.clear()
