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
local monitor, scale = display.attach(WANT_WIDTH, WANT_HEIGHT)

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

  local home = math.max(1, snap.distanceHome or 0)
  local trips = (snap.fuel or 0) / home
  local tone = ui.theme.good
  if trips < 1.5 then
    tone = ui.theme.bad
  elseif trips < 3 then
    tone = ui.theme.warn
  end

  return { text = util.count(snap.fuel or 0), color = tone }
end

local function drawDashboard()
  local width, height = ui.size()
  local list = nodes()
  local sum = totals(list)

  ui.clear()
  ui.header(
    ("FLEET  %d/%d online  %d parked"):format(sum.online, #list, sum.parked),
    textutils.formatTime(os.time(), true)
  )

  if #list == 0 then
    ui.center(math.floor(height / 2), "No turtles have reported in yet.", ui.theme.dim)
    ui.center(math.floor(height / 2) + 2, "Run `install` on a turtle to add one.", ui.theme.dim)
    ui.footer("Q quit")
    return
  end

  local haul = haulRows(sum.haul)
  local haulHeight = (#haul > 0 and height > 14) and math.min(6, #haul + 2) or 0
  local lastRow = height - haulHeight - 1

  local rows = {}
  for _, node in ipairs(list) do
    local snap = node.snap or {}
    local seconds = age(node)
    rows[#rows + 1] = {
      color = statusColor(node),
      cells = {
        snap.label or ("id " .. tostring(node.id)),
        seconds > OFFLINE_AFTER and "offline" or (snap.phase or "?"),
        { text = positionText(snap), color = ui.theme.fg },
        fuelCell(snap),
        ("%d%%"):format(math.floor((snap.progress or 0) * 100)),
        util.duration(seconds),
      },
    }
  end

  ui.table(2, 3, width - 2, COLUMNS, rows, math.max(1, lastRow - 4))

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

  ui.footer(
    ("dug %s  delivered %s   |  X recall  G deploy  R reset  Q quit"):format(
      util.count(sum.digs),
      util.count(sum.delivered)
    )
  )
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
        roster[key] = { snap = body, lastSeen = os.epoch("utc") }
        saveRoster()
        sound.play("ready")
      elseif kind == "status" then
        local previous = roster[key]
        roster[key] = { snap = body, lastSeen = os.epoch("utc") }

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

local function controls()
  while true do
    local _, key = os.pullEvent("key")

    if key == keys.q then
      return
    elseif key == keys.x then
      -- Broadcast, not addressed: a turtle that never completed a handshake
      -- still hears it.
      net.broadcast("command", { action = "recall" })
      log.warn("RECALL sent to all turtles")
      sound.play("alert")
    elseif key == keys.g then
      net.broadcast("command", { action = "deploy" })
      log.info("DEPLOY sent to all turtles")
      sound.play("ready")
    elseif key == keys.r then
      roster = {}
      saveRoster()
      log.warn("roster cleared")
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

if monitor then
  display.on(monitor, function()
    ui.clear()
    ui.center(3, "fleet offline", ui.theme.dim)
  end)
end

ui.clear()
print("Fleet base stopped.")
