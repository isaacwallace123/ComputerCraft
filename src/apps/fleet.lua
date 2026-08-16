--- Fleet base station.
---
--- Hosts the rednet protocol so turtles can find it by name rather than by a
--- hardcoded ID, keeps a roster of everything that has ever reported in, and
--- paints a live dashboard onto an attached monitor.
---
--- The roster is persisted, so after a server restart the dashboard still lists
--- every known turtle - shown as offline until it checks back in. That is the
--- point: a turtle that has gone quiet is exactly the one you want to see.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local net = require("core.net")
local log = require("core.log")
local util = require("core.util")
local config = require("core.config")

local ROSTER_PATH = ".fleet"
local SETTINGS_PATH = ".fleetcfg"

local LATE_AFTER = 10 -- seconds without a heartbeat before a row goes yellow
local OFFLINE_AFTER = 60 -- ...and red

local settings = config.load(SETTINGS_PATH, { textScale = 0.5 })
local roster = config.load(ROSTER_PATH, {})

local monitor = peripheral.find("monitor")

if monitor then
  monitor.setTextScale(settings.textScale)
end

local function saveRoster()
  config.save(ROSTER_PATH, roster)
end

--- Seconds since a node last spoke.
local function age(node)
  return util.since(node.lastSeen)
end

local function statusColor(node)
  local seconds = age(node)
  if seconds > OFFLINE_AFTER then
    return ui.theme.bad
  elseif seconds > LATE_AFTER then
    return ui.theme.warn
  elseif node.snap and node.snap.phase == "stuck" then
    return ui.theme.bad
  elseif node.snap and node.snap.phase == "done" then
    return ui.theme.accent
  end
  return ui.theme.good
end

--- Roster as a stable, sorted list - pairs() order would make rows jump about.
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
  local sum = { online = 0, digs = 0, delivered = 0, moves = 0 }
  for _, node in ipairs(list) do
    if age(node) <= OFFLINE_AFTER then
      sum.online = sum.online + 1
    end
    local snap = node.snap or {}
    sum.digs = sum.digs + (snap.digs or 0)
    sum.delivered = sum.delivered + (snap.delivered or 0)
    sum.moves = sum.moves + (snap.moves or 0)
  end
  return sum
end

--- Paint the dashboard onto whatever terminal is currently redirected.
local function drawDashboard()
  local width, height = ui.size()
  local list = nodes()
  local sum = totals(list)

  ui.clear()
  ui.header(
    ("FLEET  %d/%d online"):format(sum.online, #list),
    textutils.formatTime(os.time(), true)
  )

  if #list == 0 then
    ui.center(math.floor(height / 2), "No turtles have reported in yet.", ui.theme.dim)
    ui.center(math.floor(height / 2) + 2, "Run `install` on a turtle to add one.", ui.theme.dim)
    ui.footer("Q to quit")
    return
  end

  -- Column layout, trimmed to whatever the monitor can actually fit.
  local wide = width >= 62
  ui.text(2, 3, "NAME", ui.theme.dim)
  ui.text(14, 3, "PHASE", ui.theme.dim)
  ui.text(25, 3, "POSITION", ui.theme.dim)
  if wide then
    ui.text(40, 3, "FUEL", ui.theme.dim)
    ui.text(50, 3, "JOB", ui.theme.dim)
    ui.text(width - 5, 3, "SEEN", ui.theme.dim)
  end

  local row = 4
  for _, node in ipairs(list) do
    if row >= height - 2 then
      break
    end

    local snap = node.snap or {}
    local color = statusColor(node)
    local seconds = age(node)

    ui.text(2, row, util.fit(snap.label or ("id " .. tostring(node.id)), 11), color)
    ui.text(
      14,
      row,
      util.fit(seconds > OFFLINE_AFTER and "offline" or (snap.phase or "?"), 10),
      color
    )
    ui.text(
      25,
      row,
      util.fit(
        snap.world and ("%d,%d,%d"):format(snap.world.x, snap.world.y, snap.world.z)
          or ("%d,%d,%d"):format(snap.x or 0, snap.y or 0, snap.z or 0),
        14
      ),
      ui.theme.fg
    )

    if wide then
      if (snap.fuel or 0) < 0 then
        ui.text(40, row, "unlim", ui.theme.dim)
      else
        ui.bar(40, row, 8, snap.fuelFraction or 0)
      end
      ui.text(50, row, ("%d/%d"):format(snap.layer or 0, snap.layers or 0), ui.theme.fg)
      ui.bar(56, row, math.max(4, width - 63), snap.progress or 0, ui.theme.accent)
      ui.text(width - 5, row, util.fit(util.duration(seconds), 5), color)
    end

    row = row + 1
  end

  ui.footer(
    ("mined %s   delivered %s   moves %s"):format(
      util.count(sum.digs),
      util.count(sum.delivered),
      util.count(sum.moves)
    )
  )
end

--- Draw to the monitor if there is one, otherwise to the computer screen.
local function render()
  if monitor then
    local previous = term.redirect(monitor)
    drawDashboard()
    term.redirect(previous)

    -- The computer's own screen carries the log, which is more useful there.
    ui.clear()
    ui.header("Fleet base " .. os.getComputerID(), net.isOpen() and "online" or "NO MODEM")
    local _, height = ui.size()
    local lines = log.recent(height - 4)
    for i, entry in ipairs(lines) do
      ui.text(2, 2 + i, util.fit(entry.text, ui.size() - 2), entry.color)
    end
    ui.footer("Q to quit")
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
        log.info(("%s joined"):format(body and body.label or key))
        roster[key] = { snap = body, lastSeen = os.epoch("utc") }
        saveRoster()
      elseif kind == "status" then
        local previous = roster[key]
        roster[key] = { snap = body, lastSeen = os.epoch("utc") }

        -- Only log transitions, or the log becomes a wall of heartbeats.
        local wasPhase = previous and previous.snap and previous.snap.phase
        if body and body.phase ~= wasPhase then
          local line = ("%s: %s"):format(body.label or key, body.phase)
          if body.phase == "stuck" then
            log.error(line .. " - " .. tostring(body.detail))
          else
            log.info(line)
          end
        end
        saveRoster()
      elseif kind == "bye" then
        log.warn(((body and body.label) or key) .. " signed off")
        if roster[key] then
          roster[key].lastSeen = os.epoch("utc")
        end
      end
    end
  end
end

--- Redraw on a timer as well as on traffic, so the "seen" column keeps ticking
--- upward when a turtle goes quiet.
local function redraw()
  while true do
    render()
    sleep(1)
  end
end

local function keys_()
  while true do
    local _, key = os.pullEvent("key")
    if key == keys.q then
      return
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
  print("")
  print("Ender modems are strongly preferred - a plain wireless")
  print("modem only reaches 64 blocks, and your turtles will be")
  print("underground and out of range almost immediately.")
  return
end

log.info("base station online, hosting '" .. net.HOSTNAME .. "'")
if not net.isWireless() then
  log.warn("wired modem - turtles will not reach this")
end

parallel.waitForAny(listen, redraw, keys_)

if monitor then
  local previous = term.redirect(monitor)
  ui.clear()
  ui.center(3, "fleet offline", ui.theme.dim)
  term.redirect(previous)
end

ui.clear()
print("Fleet base stopped.")
