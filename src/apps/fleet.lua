--- Fleet base station.
---
--- Hosts the rednet protocol so turtles find it by name rather than a hardcoded
--- ID, keeps a roster of everything that has ever reported in, paints a live
--- dashboard, and issues fleet-wide orders.
---
--- The roster is persisted, so after a server restart the dashboard still lists
--- every known turtle - shown offline until it checks back in. That is the
--- point: a turtle that has gone quiet is exactly the one you want to see.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local net = require("core.net")
local log = require("core.log")
local util = require("core.util")
local sound = require("core.sound")
local config = require("core.config")
local display = require("core.display")

local embedded = ({ ... })[1] == "--embedded"

local ROSTER_PATH = ".fleet"

local LATE_AFTER = 10 -- seconds of silence before a row goes yellow
local OFFLINE_AFTER = 60 -- ...and red

-- The layout the dashboard wants. display.attach picks the largest text scale
-- that still gives us this much room, so the wall decides the font size rather
-- than a hardcoded guess.
local WANT_WIDTH, WANT_HEIGHT = 55, 16

local COLUMNS = {
  { title = "NAME", width = 10 },
  { title = "PHASE", width = 8 },
  { title = "POSITION", width = 13 },
  { title = "FUEL", width = 7, align = "right" },
  { title = "DONE", width = 4, align = "right" },
  { title = "SEEN", width = 5, align = "right" },
}

local roster = config.load(ROSTER_PATH, {})
local monitor, scale
if not embedded then
  monitor, scale = display.attach(WANT_WIDTH, WANT_HEIGHT)
end
local clickTargets = {}
local rowTargets = {}
local view = "fleet"
local selectedId = nil
local cursor = 1
local notice = nil

local function saveRoster()
  config.save(ROSTER_PATH, roster)
end

local function age(node)
  return util.since(node.lastSeen)
end

local function statusColor(node)
  local seconds = age(node)
  local phase = node.snap and node.snap.phase

  if seconds > OFFLINE_AFTER then
    return ui.theme.bad
  elseif phase == "stuck" then
    return ui.theme.bad
  elseif seconds > LATE_AFTER then
    return ui.theme.warn
  elseif phase == "parked" then
    return ui.theme.accent
  end
  return ui.theme.good
end

--- Roster as a stable sorted list - pairs() order would make rows jump about.
local function nodes()
  local list = {}
  for id, node in pairs(roster) do
    node.id = tonumber(id) or id
    list[#list + 1] = node
  end
  table.sort(list, function(a, b)
    return tostring(a.snap and a.snap.label or a.id) < tostring(b.snap and b.snap.label or b.id)
  end)
  return list
end

local function totals(list)
  local sum = { online = 0, parked = 0, digs = 0, delivered = 0, haul = {} }

  for _, node in ipairs(list) do
    local snap = node.snap or {}
    if age(node) <= OFFLINE_AFTER then
      sum.online = sum.online + 1
      if snap.phase == "parked" then
        sum.parked = sum.parked + 1
      end
    end

    sum.digs = sum.digs + (snap.digs or 0)
    sum.delivered = sum.delivered + (snap.delivered or 0)

    for name, count in pairs(snap.haul or {}) do
      sum.haul[name] = (sum.haul[name] or 0) + count
    end
  end

  return sum
end

local function haulRows(haul)
  local rows = {}
  for name, count in pairs(haul) do
    rows[#rows + 1] = { name = util.blockName(name), count = count }
  end
  table.sort(rows, function(a, b)
    return a.count > b.count
  end)
  return rows
end

local function positionText(snap)
  if snap.world then
    return ("%d,%d,%d"):format(snap.world.x, snap.world.y, snap.world.z)
  end
  return ("%d,%d,%d"):format(snap.x or 0, snap.y or 0, snap.z or 0)
end

--- Fuel is shown against the walk home, not against the tank. An advanced
--- turtle holds 100,000 and a trip costs about 1,000, so a percentage-of-tank
--- bar reads empty forever and answers nothing.
local function fuelCell(snap)
  if (snap.fuel or 0) < 0 then
    return { text = "unlim", color = ui.theme.dim }
  end

  local parkedGoal = snap.parked and snap.fuelRequired
  local home = math.max(1, parkedGoal or snap.distanceHome or 0)
  local trips = (snap.fuel or 0) / home
  local tone = ui.theme.good
  if parkedGoal then
    tone = trips >= 1 and ui.theme.good or ui.theme.bad
  else
    if trips < 1.5 then
      tone = ui.theme.bad
    elseif trips < 3 then
      tone = ui.theme.warn
    end
  end

  return { text = util.count(snap.fuel or 0), color = tone }
end

local function selectedNode()
  return selectedId and roster[tostring(selectedId)] or nil
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

local function buttonBar(buttons)
  local width, height = ui.size()
  ui.row(height, ui.theme.headerBg)
  clickTargets = {}
  local x = 2
  for _, button in ipairs(buttons) do
    local needed = #button[1] + 2
    if x + needed - 1 <= width then
      x = addButton(x, height, button[1], button[2], button[3])
    end
  end
end

local function drawNotice(width, height)
  if notice and os.epoch("utc") <= notice.untilAt and height > 4 then
    ui.text(2, height - 1, ui.pad(notice.text, width - 3), notice.color)
  end
end

local function drawDevice()
  local width, height = ui.size()
  local node = selectedNode()
  if not node then
    view, selectedId = "fleet", nil
    return
  end

  local snap = node.snap or {}
  local online = age(node) <= OFFLINE_AFTER
  local label = snap.label or ("id " .. tostring(selectedId))
  ui.clear()
  ui.header(label .. "  #" .. tostring(selectedId), online and "connected" or "offline")

  ui.text(2, 3, ("%-10s %s"):format("state", snap.phase or "unknown"), statusColor(node))
  ui.text(2, 4, ui.pad(snap.detail or "", width - 3), ui.theme.dim)
  ui.text(2, 6, ("%-10s %s"):format("job", snap.job or "none"))
  ui.text(2, 7, ("%-10s %s"):format("position", positionText(snap)))
  local fuelText = snap.fuel == -1 and "unlimited" or util.count(snap.fuel or 0)
  if snap.parked and snap.fuelRequired and snap.fuel ~= -1 then
    fuelText = fuelText .. " / " .. util.count(snap.fuelRequired) .. " needed"
  else
    fuelText = fuelText .. ("  (%d home)"):format(snap.distanceHome or 0)
  end
  local fuelColor = ui.theme.fg
  if snap.parked and snap.fuelRequired and snap.fuel ~= -1 and snap.fuel < snap.fuelRequired then
    fuelColor = ui.theme.bad
  end
  ui.text(2, 8, ("%-10s %s"):format("fuel", fuelText), fuelColor)

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
    local summary
    if snap.job == "expedition" then
      summary = ("distance %s  Y %s  tunnel %s"):format(
        tostring(settings.distance or "?"),
        tostring(settings.targetY or "?"),
        tostring(settings.tunnelLength or "?")
      )
    elseif snap.job == "quarry" then
      summary = ("%sx%s  depth %s"):format(
        tostring(settings.width or "?"),
        tostring(settings.length or "?"),
        tostring(settings.depth or "?")
      )
    end
    if summary then
      ui.text(2, 14, ui.pad("settings   " .. summary, width - 3), ui.theme.dim)
    end
  end

  drawNotice(width, height)
  buttonBar({
    { "back", "back" },
    { "deploy", "deploy_one" },
    { "recall", "recall_one" },
    { "config", "settings" },
    { "job", "job" },
  })
  addButton(math.max(2, width - 9), 3, "forget", "forget")
end

local function drawSettings()
  local width, height = ui.size()
  local node = selectedNode()
  if not node then
    view, selectedId = "fleet", nil
    return
  end

  local snap = node.snap or {}
  local settings = snap.settings or {}
  local fields
  if snap.job == "expedition" then
    fields = {
      { "Distance", "distance", 10 },
      { "Target Y", "targetY", 1 },
      { "Tunnel", "tunnelLength", 8 },
    }
  else
    fields = {
      { "Width", "width", 1 },
      { "Length", "length", 1 },
      { "Depth", "depth", 4 },
    }
  end

  ui.clear()
  ui.header((snap.label or tostring(selectedId)) .. " settings", snap.job or "")
  ui.text(2, 3, "Changes are saved now and used on the next deploy.", ui.theme.dim)
  clickTargets = {}

  for index, field in ipairs(fields) do
    local y = 5 + (index - 1) * 3
    local value = tonumber(settings[field[2]]) or 0
    ui.text(3, y, ui.pad(field[1], 12), ui.theme.fg)
    ui.text(16, y, ui.pad(value, 7, "right"), ui.theme.accent)
    local x = math.max(25, width - 15)
    x = addButton(x, y, "-", "adjust", { field = field[2], value = value - field[3] })
    addButton(x, y, "+", "adjust", { field = field[2], value = value + field[3] })
  end

  drawNotice(width, height)
  local existing = clickTargets
  buttonBar({ { "back", "device" }, { "deploy", "deploy_one" }, { "refresh", "refresh" } })
  for _, target in ipairs(existing) do
    clickTargets[#clickTargets + 1] = target
  end
end

local function drawDashboard()
  if view == "device" then
    drawDevice()
    return
  elseif view == "settings" then
    drawSettings()
    return
  end

  local width, height = ui.size()
  local list = nodes()
  local sum = totals(list)
  cursor = math.max(1, math.min(cursor, math.max(1, #list)))
  rowTargets = {}

  ui.clear()
  ui.header(
    ("DEVICES  %d/%d online  %d parked"):format(sum.online, #list, sum.parked),
    textutils.formatTime(os.time(), true)
  )

  if #list == 0 then
    ui.center(math.floor(height / 2), "No turtles have reported in yet.", ui.theme.dim)
    ui.center(math.floor(height / 2) + 2, "Run `install` on a turtle to add one.", ui.theme.dim)
    buttonBar({ { "refresh", "refresh_all" }, { "quit", "quit" } })
    return
  end

  local haul = haulRows(sum.haul)
  local haulHeight = (#haul > 0 and height > 14) and math.min(6, #haul + 2) or 0
  local lastRow = height - haulHeight - 1

  local rows = {}
  local maxRows = math.max(1, lastRow - 4)
  for index, node in ipairs(list) do
    local snap = node.snap or {}
    local seconds = age(node)
    local name = snap.label or ("id " .. tostring(node.id))
    if index == cursor then
      name = ">" .. name
    end
    rows[#rows + 1] = {
      color = statusColor(node),
      cells = {
        name,
        seconds > OFFLINE_AFTER and "offline" or (snap.phase or "?"),
        { text = positionText(snap), color = ui.theme.fg },
        fuelCell(snap),
        ("%d%%"):format(math.floor((snap.progress or 0) * 100)),
        util.duration(seconds),
      },
    }
    if index <= maxRows then
      rowTargets[#rowTargets + 1] = { y = 3 + index, id = node.id, index = index }
    end
  end

  ui.table(2, 3, width - 2, COLUMNS, rows, maxRows)

  if haulHeight > 0 then
    local top = height - haulHeight
    ui.text(2, top, "HAUL", ui.theme.dim)

    local perRow = width >= 60 and 3 or (width >= 40 and 2 or 1)
    local columnWidth = math.floor((width - 2) / perRow)

    for index, entry in ipairs(haul) do
      local slot = index - 1
      local line = top + 1 + math.floor(slot / perRow)
      if line >= height then
        break
      end
      local column = 2 + (slot % perRow) * columnWidth
      local amount = util.count(entry.count)
      ui.text(column, line, ui.pad(entry.name, columnWidth - #amount - 2) .. amount, ui.theme.fg)
    end
  end

  local footer = ("dug %s  delivered %s"):format(util.count(sum.digs), util.count(sum.delivered))
  ui.footer(footer)

  clickTargets = {}
  local buttons = {
    { " recall ", "recall_all" },
    { " deploy ", "deploy_all" },
    { " reset ", "reset" },
  }
  local buttonWidth = 0
  for _, button in ipairs(buttons) do
    buttonWidth = buttonWidth + #button[1] + 1
  end
  local x = math.max(#footer + 3, width - buttonWidth)
  for _, button in ipairs(buttons) do
    if x + #button[1] - 1 <= width then
      ui.text(x, height, button[1], ui.theme.bg, ui.theme.headerFg)
      clickTargets[#clickTargets + 1] = {
        from = x,
        to = x + #button[1] - 1,
        y = height,
        action = button[2],
      }
      x = x + #button[1] + 1
    end
  end
end

--- Draw to the monitor if there is one, otherwise to this screen.
local function render()
  if monitor then
    display.on(monitor, drawDashboard)

    ui.clear()
    ui.header("Fleet base " .. os.getComputerID(), net.isOpen() and "online" or "NO MODEM")
    local width, height = ui.size()
    for i, entry in ipairs(log.recent(height - 4)) do
      ui.text(2, 2 + i, util.fit(entry.text, width - 2), entry.color)
    end
    ui.footer("X recall  G deploy  Q quit")
  else
    drawDashboard()
  end
end

local function listen()
  while true do
    local sender, kind, body = net.receive(1)

    if sender and kind then
      local key = tostring(sender)

      if kind == "hello" then
        log.info(((body and body.label) or key) .. " joined")
        roster[key] = {
          snap = body,
          lastSeen = os.epoch("utc"),
          pairedAt = roster[key] and roster[key].pairedAt or os.epoch("utc"),
        }
        saveRoster()
        sound.play("ready")
      elseif kind == "status" then
        local previous = roster[key]
        roster[key] = {
          snap = body,
          lastSeen = os.epoch("utc"),
          pairedAt = previous and previous.pairedAt or os.epoch("utc"),
        }

        -- Only log transitions, or the log becomes a wall of heartbeats.
        local wasPhase = previous and previous.snap and previous.snap.phase
        if body and body.phase ~= wasPhase then
          local line = ("%s: %s"):format(body.label or key, body.phase)
          if body.phase == "stuck" then
            log.error(line .. " - " .. tostring(body.detail))
            sound.play("alert")
          else
            log.info(line)
          end
        end
        saveRoster()
      elseif kind == "command_result" and type(body) == "table" then
        local previous = roster[key] or {}
        if type(body.snapshot) == "table" then
          previous.snap = body.snapshot
        end
        previous.lastSeen = os.epoch("utc")
        previous.pairedAt = previous.pairedAt or os.epoch("utc")
        roster[key] = previous
        setNotice(body.message or body.action or "command acknowledged", body.ok ~= false)
        saveRoster()
      end
    end
  end
end

--- Redraw on a timer as well as on traffic, so "seen" keeps ticking upward when
--- a turtle goes quiet.
local function redraw()
  while true do
    -- A drawing bug must never take the base station down with it. Without this
    -- an error in render() kills the coroutine, parallel unwinds, and the
    -- monitor freezes on its last good frame - which looks exactly like the
    -- whole fleet having stopped, when the turtles are still mining.
    local ok, err = pcall(render)
    if not ok then
      log.error("draw failed: " .. tostring(err))
      sleep(2)
    end
    sleep(1)
  end
end

local function sendSelected(action, extra)
  local id = tonumber(selectedId)
  if not id or not selectedNode() then
    setNotice("No turtle selected", false)
    return false
  end

  local body = extra or {}
  body.action = action
  if net.send(id, "command", body) then
    setNotice(action .. " sent", true)
    return true
  end
  setNotice("Could not reach turtle " .. id, false)
  return false
end

local function act(action, data)
  if action == "recall_all" then
    net.broadcast("command", { action = "recall" })
    log.warn("RECALL sent to all turtles")
    setNotice("Recall sent to the fleet", true)
    sound.play("alert")
  elseif action == "deploy_all" then
    net.broadcast("command", { action = "deploy" })
    log.info("DEPLOY sent to all turtles")
    setNotice("Deploy sent to the fleet", true)
    sound.play("ready")
  elseif action == "reset" then
    roster = {}
    selectedId, view = nil, "fleet"
    saveRoster()
    log.warn("roster cleared")
  elseif action == "back" then
    view = "fleet"
  elseif action == "device" then
    view = "device"
  elseif action == "deploy_one" then
    sendSelected("deploy")
  elseif action == "recall_one" then
    sendSelected("recall")
  elseif action == "settings" then
    view = "settings"
  elseif action == "refresh" then
    sendSelected("status_request")
  elseif action == "refresh_all" then
    net.broadcast("command", { action = "status_request" })
    setNotice("Status requested", true)
  elseif action == "job" then
    local node = selectedNode()
    local current = node and node.snap and node.snap.job
    local nextJob = current == "quarry" and "expedition" or "quarry"
    sendSelected("set_job", { job = nextJob })
  elseif action == "adjust" and data then
    sendSelected("configure", { settings = { [data.field] = data.value } })
  elseif action == "forget" then
    if selectedId then
      roster[tostring(selectedId)] = nil
      saveRoster()
    end
    selectedId, view = nil, "fleet"
  elseif action == "quit" then
    return "quit"
  end
end

local function controls()
  while true do
    local event = { os.pullEvent() }
    local kind = event[1]

    if kind == "icos_close" then
      return
    elseif kind == "key" then
      local key = event[2]
      if key == keys.q then
        return
      elseif view == "fleet" then
        local list = nodes()
        if key == keys.up then
          cursor = math.max(1, cursor - 1)
        elseif key == keys.down then
          cursor = math.min(#list, cursor + 1)
        elseif key == keys.enter and list[cursor] then
          selectedId, view = list[cursor].id, "device"
          sendSelected("status_request")
        elseif key == keys.x then
          act("recall_all")
        elseif key == keys.g then
          act("deploy_all")
        elseif key == keys.r then
          act("refresh_all")
        end
      elseif key == keys.backspace or key == keys.b or key == keys.left then
        act(view == "settings" and "device" or "back")
      elseif key == keys.d then
        act("deploy_one")
      elseif key == keys.x then
        act("recall_one")
      elseif key == keys.c then
        act("settings")
      elseif key == keys.j then
        act("job")
      elseif key == keys.r then
        act("refresh")
      elseif key == keys.f then
        act("forget")
      end
    elseif kind == "mouse_click" then
      if view == "fleet" then
        for _, row in ipairs(rowTargets) do
          if event[4] == row.y then
            selectedId, cursor, view = row.id, row.index, "device"
            sendSelected("status_request")
            break
          end
        end
      end
      for _, target in ipairs(clickTargets) do
        if event[4] == target.y and event[3] >= target.from and event[3] <= target.to then
          if act(target.action, target.data) == "quit" then
            return
          end
          break
        end
      end
    end
  end
end

if not net.hostAsBase() then
  ui.clear()
  printError("No modem attached.")
  print("")
  print("The base station needs a modem to hear from turtles.")
  print("Attach a wireless or ender modem to this computer.")
  return
end

log.info("base station online, hosting '" .. net.HOSTNAME .. "'")
if not net.isWireless() then
  log.warn("wired modem - turtles will not reach this")
end

if monitor then
  local mw, mh = monitor.getSize()
  log.info(("monitor %dx%d at scale %s"):format(mw, mh, tostring(scale)))
  if mw < WANT_WIDTH then
    log.warn("monitor is narrow - some columns are hidden")
  end
else
  log.warn("no monitor - drawing on this screen")
end

parallel.waitForAny(listen, redraw, controls)
net.unhostBase()

if monitor then
  display.on(monitor, function()
    ui.clear()
    ui.center(3, "fleet offline", ui.theme.dim)
  end)
end

ui.clear()
print("Fleet base stopped.")
