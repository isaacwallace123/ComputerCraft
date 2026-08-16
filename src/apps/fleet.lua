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
local config = require("core.config")

local ROSTER_PATH = ".fleet"
local SETTINGS_PATH = ".fleetcfg"

local LATE_AFTER = 10 -- seconds of silence before a row goes yellow
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
  local sum = { online = 0, parked = 0, digs = 0, delivered = 0, moves = 0, haul = {} }

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
    sum.moves = sum.moves + (snap.moves or 0)

    for name, count in pairs(snap.haul or {}) do
      sum.haul[name] = (sum.haul[name] or 0) + count
    end
  end

  return sum
end

--- Fleet haul, most plentiful first.
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

  -- Columns are dropped from the right as the screen narrows, rather than one
  -- all-or-nothing "wide" layout. A 4x3 monitor at text scale 0.5 lands around
  -- 57 columns, which is exactly the sort of width a hardcoded cutoff gets
  -- wrong. Widths are logged at startup so you can see what you actually have.
  local COL = { name = 2, phase = 13, pos = 22, fuel = 36, done = 44, seen = 49 }
  local show = {
    fuel = width >= 43,
    done = width >= 48,
    seen = width >= 55,
    bar = width >= 70,
  }

  -- Reserve the bottom of the screen for the haul panel, but never so much that
  -- the turtle rows get squeezed out on a small monitor.
  local haul = haulRows(sum.haul)
  local haulHeight = (#haul > 0 and height > 14) and math.min(6, #haul + 2) or 0
  local lastRow = height - haulHeight - 1

  ui.text(COL.name, 3, "NAME", ui.theme.dim)
  ui.text(COL.phase, 3, "PHASE", ui.theme.dim)
  ui.text(COL.pos, 3, "POSITION", ui.theme.dim)
  if show.fuel then
    ui.text(COL.fuel, 3, "FUEL", ui.theme.dim)
  end
  if show.done then
    ui.text(COL.done, 3, "DONE", ui.theme.dim)
  end
  if show.seen then
    ui.text(COL.seen, 3, "SEEN", ui.theme.dim)
  end

  local row = 4
  for _, node in ipairs(list) do
    if row >= lastRow then
      break
    end

    local snap = node.snap or {}
    local color = statusColor(node)
    local seconds = age(node)

    ui.text(COL.name, row, util.fit(snap.label or ("id " .. tostring(node.id)), 10), color)
    ui.text(
      COL.phase,
      row,
      util.fit(seconds > OFFLINE_AFTER and "offline" or (snap.phase or "?"), 8),
      color
    )
    ui.text(
      COL.pos,
      row,
      util.fit(
        snap.world and ("%d,%d,%d"):format(snap.world.x, snap.world.y, snap.world.z)
          or ("%d,%d,%d"):format(snap.x or 0, snap.y or 0, snap.z or 0),
        13
      ),
      ui.theme.fg
    )

    if show.fuel then
      if (snap.fuel or 0) < 0 then
        ui.text(COL.fuel, row, "unlim", ui.theme.dim)
      else
        -- Deliberately NOT a fraction of the fuel tank. An advanced turtle holds
        -- 100,000 and a trip costs ~1,000, so that bar reads empty forever and
        -- tells you nothing. What matters is the ratio to the walk home, so show
        -- the real number and colour it by how many return trips it covers.
        local home = math.max(1, snap.distanceHome or 0)
        local trips = (snap.fuel or 0) / home
        local tone = ui.theme.good
        if trips < 1.5 then
          tone = ui.theme.bad
        elseif trips < 3 then
          tone = ui.theme.warn
        end
        ui.text(COL.fuel, row, util.fit(util.count(snap.fuel or 0), 7), tone)
      end
    end
    if show.done then
      ui.text(COL.done, row, ("%3d%%"):format(math.floor((snap.progress or 0) * 100)), ui.theme.fg)
    end
    if show.seen then
      ui.text(COL.seen, row, util.fit(util.duration(seconds), 5), color)
    end
    if show.bar then
      ui.bar(COL.seen + 6, row, width - COL.seen - 6, snap.progress or 0, ui.theme.accent)
    end

    row = row + 1
  end

  -- Haul panel: what the fleet has actually pulled out of the ground.
  if haulHeight > 0 then
    local top = height - haulHeight
    ui.text(2, top, "HAUL", ui.theme.dim)

    local perRow = width >= 60 and 3 or (width >= 40 and 2 or 1)
    local columnWidth = math.floor((width - 2) / perRow)
    local index = 0

    for _, entry in ipairs(haul) do
      local line = top + 1 + math.floor(index / perRow)
      if line >= height then
        break
      end
      local column = 2 + (index % perRow) * columnWidth
      ui.text(
        column,
        line,
        ("%-*s %s"):format(
          columnWidth - 7,
          util.fit(entry.name, columnWidth - 8),
          util.count(entry.count)
        ),
        ui.theme.fg
      )
      index = index + 1
    end
  end

  ui.footer(
    ("dug %s  delivered %s   |  X recall   G deploy   R reset   Q quit"):format(
      util.count(sum.digs),
      util.count(sum.delivered)
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

local function controls()
  while true do
    local _, key = os.pullEvent("key")

    if key == keys.q then
      return
    elseif key == keys.x then
      -- Broadcast, not addressed: a turtle that missed a hello still hears it.
      net.broadcast("command", { action = "recall" })
      log.warn("RECALL sent to all turtles")
    elseif key == keys.g then
      net.broadcast("command", { action = "deploy" })
      log.info("DEPLOY sent to all turtles")
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

-- Log the real character dimensions. Monitor size depends on the block layout
-- AND the text scale, so guessing at it is how dashboards end up clipped.
if monitor then
  local mw, mh = monitor.getSize()
  log.info(("monitor %dx%d chars at scale %s"):format(mw, mh, tostring(settings.textScale)))
  if mw < 43 then
    log.warn("narrow monitor - fuel and progress columns hidden")
  end
else
  log.warn("no monitor attached - drawing on this screen")
end

parallel.waitForAny(listen, redraw, controls)

if monitor then
  local previous = term.redirect(monitor)
  ui.clear()
  ui.center(3, "fleet offline", ui.theme.dim)
  term.redirect(previous)
end

ui.clear()
print("Fleet base stopped.")
