--- Scalable fleet overview and fleet-wide controls.
---
--- This page stays intentionally shallow: it shows every miner, aggregate haul
--- and fleet-wide actions. Selecting a miner opens the Devices app, which owns
--- per-device status and configuration.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("legacy.shell.ui")
local net = require("legacy.net")
local log = require("adapters.cc.logfile")
local util = require("lib.util")
local sound = require("legacy.sound")
local display = require("legacy.shell.display")
local control = require("legacy.fleet.control")
local rosterStore = require("legacy.fleet.roster")

local flags = {}
for _, argument in ipairs({ ... }) do
  flags[argument] = true
end
local embedded = flags["--embedded"] == true
local readonly = flags["--readonly"] == true
local auxiliaryEnabled = flags["--no-aux"] ~= true

local COLUMNS = {
  { title = "NAME", width = 11 },
  { title = "PHASE", width = 9 },
  { title = "POSITION", width = 13 },
  { title = "FUEL", width = 7, align = "right" },
  { title = "DONE", width = 5, align = "right" },
  { title = "SEEN", width = 6, align = "right" },
}

local roster = rosterStore.load()
local scroll = 0
local visibleRows = 1
local clickTargets = {}
local rowTargets = {}
local running = true
local auxiliary, auxiliaryName
local haulPage = 1

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

local function nodes()
  roster = rosterStore.load()
  return rosterStore.sorted(roster)
end

local function totals(list)
  local sum = { online = 0, parked = 0, digs = 0, delivered = 0, haul = {} }
  for _, node in ipairs(list) do
    local snap = node.snap or {}
    if age(node) <= rosterStore.OFFLINE_AFTER then
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
  local point = snap.world or snap
  return ("%d,%d,%d"):format(point.x or 0, point.y or 0, point.z or 0)
end

local function fuelCell(snap)
  if (snap.fuel or 0) < 0 then
    return { text = "unlim", color = ui.theme.dim }
  end

  local needed = math.max(1, (snap.parked and snap.fuelRequired) or snap.distanceHome or 0)
  local trips = (snap.fuel or 0) / needed
  local color = ui.theme.good
  if trips < 1.5 then
    color = ui.theme.bad
  elseif trips < 3 then
    color = ui.theme.warn
  end
  return { text = util.count(snap.fuel or 0), color = color }
end

local function addButton(x, y, label, action)
  local text = " " .. label .. " "
  ui.text(x, y, text, ui.theme.bg, ui.theme.headerFg)
  clickTargets[#clickTargets + 1] = { from = x, to = x + #text - 1, y = y, action = action }
  return x + #text + 1
end

local function drawFooter(width, height)
  ui.row(height, ui.theme.headerBg)
  clickTargets = {}
  local x = 2
  local buttons = readonly and {
    { "previous", "up" },
    { "next", "down" },
  } or width < 42 and {
    { "up", "up" },
    { "down", "down" },
    { "actions", "actions" },
  } or {
    { "up", "up" },
    { "down", "down" },
    { "recall all", "recall" },
    { "deploy all", "deploy" },
    { "sync", "refresh" },
  }
  for _, button in ipairs(buttons) do
    if x + #button[1] + 1 <= width then
      x = addButton(x, height, button[1], button[2])
    end
  end
  if readonly then
    local label = "VIEW ONLY"
    ui.text(math.max(x, width - #label), height, label, ui.theme.headerFg, ui.theme.headerBg)
  end
end

local function drawHaul(haul, sum, width, top, height)
  local summary = ("HAUL  dug %s  delivered %s"):format(
    util.count(sum.digs),
    util.count(sum.delivered)
  )
  ui.text(2, top, ui.pad(summary, width - 3), ui.theme.dim)

  local perRow = width >= 60 and 3 or (width >= 40 and 2 or 1)
  local columnWidth = math.floor((width - 2) / perRow)
  local capacity = perRow
  for index = 1, math.min(#haul, capacity) do
    local entry = haul[index]
    local x = 2 + (index - 1) * columnWidth
    local amount = util.count(entry.count)
    local labelWidth = math.max(1, columnWidth - #amount - 2)
    ui.text(x, top + 1, ui.pad(entry.name, labelWidth) .. " " .. amount, ui.theme.fg)
  end
  if #haul > capacity then
    local extra = "+" .. tostring(#haul - capacity) .. " more"
    ui.text(math.max(2, width - #extra), top, extra, ui.theme.accent)
  elseif #haul == 0 and top + 1 < height then
    ui.text(2, top + 1, "No items reported yet", ui.theme.dim)
  end
end

local function ensureAuxiliary()
  if not embedded or not auxiliaryEnabled or not display.primaryName() then
    return
  end

  if auxiliaryName and not display.isAttached(auxiliaryName) then
    log.warn("fleet: auxiliary monitor disconnected")
    auxiliary, auxiliaryName = nil, nil
    haulPage = 1
  end

  if not auxiliary then
    local found, scale, width, height, name = display.secondary(36, 12)
    if found then
      auxiliary, auxiliaryName = found, name
      haulPage = 1
      log.info(
        ("fleet: haul monitor %s %dx%d at scale %s"):format(name, width, height, tostring(scale))
      )
    end
  end
end

local function drawAuxiliary(haul, sum)
  if not auxiliary then
    return
  end

  display.on(auxiliary, function()
    local width, height = ui.size()
    local perRow = width >= 44 and 2 or 1
    local rows = math.max(1, height - 6)
    local capacity = rows * perRow
    local pages = math.max(1, math.ceil(#haul / capacity))
    haulPage = math.max(1, math.min(haulPage, pages))
    local first = (haulPage - 1) * capacity + 1
    local last = math.min(#haul, first + capacity - 1)

    ui.clear()
    ui.header("FLEET HAUL", ("page %d/%d"):format(haulPage, pages))
    ui.text(
      2,
      3,
      ("%s dug  %s delivered  %d item types"):format(
        util.count(sum.digs),
        util.count(sum.delivered),
        #haul
      ),
      ui.theme.dim
    )

    if #haul == 0 then
      ui.center(math.floor(height / 2), "No haul reported yet", ui.theme.dim)
    else
      local columnWidth = math.floor((width - 2) / perRow)
      for index = first, last do
        local slot = index - first
        local x = 2 + (slot % perRow) * columnWidth
        local y = 5 + math.floor(slot / perRow)
        local entry = haul[index]
        local amount = util.count(entry.count)
        local labelWidth = math.max(1, columnWidth - #amount - 2)
        ui.text(x, y, ui.pad(entry.name, labelWidth) .. " " .. amount, ui.theme.fg)
      end
    end

    ui.footer(" touch left: previous      right: next ")
  end)
end

local function draw()
  ensureAuxiliary()
  local width, height = ui.size()
  local list = nodes()
  local sum = totals(list)
  local haul = haulRows(sum.haul)
  local showHaul = not auxiliary and height >= 13
  local haulTop = showHaul and (height - 3) or nil
  visibleRows = math.max(1, (showHaul and haulTop - 4 or height - 4))
  local maxScroll = math.max(0, #list - visibleRows)
  scroll = math.max(0, math.min(scroll, maxScroll))
  local first = #list == 0 and 0 or scroll + 1
  local last = math.min(#list, scroll + visibleRows)

  -- Gathering the numbers is done; painting them is one buffered update, so the
  -- wall never shows the cleared screen on its own.
  ui.frame(function()
    ui.clear()
    local status = width < 42 and ("%d/%d  P%d"):format(sum.online, #list, sum.parked)
      or ("%d/%d online  %d parked  %d-%d"):format(sum.online, #list, sum.parked, first, last)
    ui.header(readonly and "FLEET STATUS" or "FLEET", status)
    rowTargets = {}

    if #list == 0 then
      ui.center(math.floor((height - 1) / 2), "Waiting for miners to report in...", ui.theme.dim)
    else
      local rows = {}
      for index = first, last do
        local node = list[index]
        local snap = node.snap or {}
        rows[#rows + 1] = {
          color = statusColor(node),
          cells = {
            snap.label or ("id " .. tostring(node.id)),
            age(node) > rosterStore.OFFLINE_AFTER and "offline" or (snap.phase or "unknown"),
            { text = positionText(snap), color = ui.theme.fg },
            fuelCell(snap),
            ("%d%%"):format(math.floor((snap.progress or 0) * 100)),
            util.duration(age(node)),
          },
        }
        if not readonly then
          rowTargets[#rowTargets + 1] = { y = 3 + #rows, id = node.id }
        end
      end
      ui.table(2, 3, width - 2, COLUMNS, rows, visibleRows)
    end

    if showHaul then
      drawHaul(haul, sum, width, haulTop, height)
    end
    drawFooter(width, height)
  end)

  -- Outside the frame: the haul wall is a different terminal with its own
  -- buffering, and hiding this page does nothing for it.
  drawAuxiliary(haul, sum)
end

local function redraw()
  while running do
    local ok, err = pcall(draw)
    if not ok then
      log.error("fleet draw failed: " .. tostring(err))
    end
    sleep(1)
  end
end

local function act(action)
  if readonly and action ~= "up" and action ~= "down" then
    return
  end
  if action == "up" then
    scroll = math.max(0, scroll - 1)
  elseif action == "down" then
    scroll = scroll + 1
  elseif action == "recall" then
    net.broadcast("command", { action = "recall" })
    log.warn("fleet: recall sent to all turtles")
    sound.play("alert")
  elseif action == "deploy" then
    net.broadcast("command", { action = "deploy" })
    log.info("fleet: deploy sent to all turtles")
    sound.play("ready")
  elseif action == "refresh" then
    net.broadcast("command", { action = "status_request" })
    control.requestSync()
    log.info("fleet: status refresh requested")
  elseif action == "actions" then
    local choice = ui.menu("FLEET ACTIONS", {
      "Deploy all",
      "Recall all",
      "Refresh status",
      "Cancel",
    })
    if choice == 1 then
      act("deploy")
    elseif choice == 2 then
      act("recall")
    elseif choice == 3 then
      act("refresh")
    end
  end
end

local function controls()
  while running do
    local event = { os.pullEvent() }
    local kind = event[1]
    if kind == "icos_close" then
      running = false
      return
    elseif kind == "icos_forget_device" then
      roster = rosterStore.load()
    elseif kind == "key" and not readonly then
      if event[2] == keys.q then
        running = false
        return
      elseif event[2] == keys.up then
        act("up")
      elseif event[2] == keys.down then
        act("down")
      elseif event[2] == keys.pageUp then
        scroll = math.max(0, scroll - visibleRows)
      elseif event[2] == keys.pageDown then
        scroll = scroll + visibleRows
      elseif event[2] == keys.x then
        act("recall")
      elseif event[2] == keys.g then
        act("deploy")
      elseif event[2] == keys.r then
        act("refresh")
      elseif event[2] == keys.enter then
        act("actions")
      end
    elseif kind == "mouse_scroll" then
      scroll = math.max(0, scroll + event[2])
    elseif kind == "monitor_touch" and event[2] == auxiliaryName and auxiliary then
      local width, height = auxiliary.getSize()
      if event[4] == height then
        if event[3] <= math.floor(width / 2) then
          haulPage = math.max(1, haulPage - 1)
        else
          haulPage = haulPage + 1
        end
      end
    elseif kind == "monitor_resize" and event[2] == auxiliaryName then
      auxiliary, auxiliaryName = nil, nil
    elseif kind == "mouse_click" then
      if not readonly then
        for _, row in ipairs(rowTargets) do
          if event[4] == row.y then
            os.queueEvent("icos_open_app", "devices", { deviceId = row.id })
            break
          end
        end
      end
      for _, target in ipairs(clickTargets) do
        if event[4] == target.y and event[3] >= target.from and event[3] <= target.to then
          act(target.action)
          break
        end
      end
    end
    draw()
  end
end

parallel.waitForAny(redraw, controls)
running = false
if auxiliary and display.isAttached(auxiliaryName) then
  display.on(auxiliary, ui.clear)
end
ui.clear()
