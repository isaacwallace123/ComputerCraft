--- Fleet, wired: the composition root that turns the view into an app.
---
--- `view.lua` has existed since phase 2 of the UI framework and **nothing has
--- ever mounted it** - its own header says the `app.lua` beside it is "a later
--- phase, because that one touches a running fleet". This is that file. It is
--- late enough that the thing it was waiting for already exists: the client's
--- mirror, the desired-state path, and a shell that hosts pages.
---
--- ## Fleet and Devices are not the same page
---
--- They read the same registry and they answer different questions, which is why
--- both exist rather than one with a toggle.
---
--- **Devices** is "what is each machine doing, and what should it be doing" -
--- sorted by staleness so the one that stopped reporting is first, with
--- per-device actions. It is the page you open when something is wrong.
---
--- **Fleet** is "is the fleet working" - sorted by label so the same turtle is
--- in the same row every time you glance at it, with fuel meters and
--- fleet-wide actions. It is the page you leave open on a monitor.
---
--- That difference decides the sort order, and the sort order is the whole
--- distinction. A dashboard somebody watches must be stable: rows that reorder
--- themselves as turtles go quiet make a wall display unreadable, which is the
--- opposite of what §6 asks of the Devices page.
---
--- ## It owns nothing, like every app
---
--- D018: sector leasing once lived inside the ICOS 1 Fleet page, so closing the
--- dashboard stopped two turtles being kept out of the same shaft. This app
--- reads `context.state.fleet` and asks the server for goals. Closing it changes
--- nothing about what the fleet is doing.

local desired = require("domain.fleet.desired")
local registry = require("domain.fleet.registry")
local request = require("os.kernel.request")
local view = require("apps.fleet.view")

local app = {}

--- Turn one registry record into a row the view can draw.
---
--- The snapshot is the device's own account of itself and every field in it is
--- optional - a turtle mid-reboot, one on an older build, and one that has never
--- been given a job all report less than a working one. So every read has a
--- floor, and the floor is chosen to be honest rather than flattering: no fuel
--- reading is `0`, which shows an empty meter, because a meter that defaulted to
--- full would hide the one turtle that is about to strand itself.
function app.row(record, now)
  local snap = record.snap or {}
  local health = registry.health(record, now)

  return {
    id = record.id,
    label = snap.label or ("#" .. tostring(record.id)),

    -- Offline overrides whatever the device last claimed to be doing. A turtle
    -- that says "mining" and has not been heard from in five minutes is not
    -- mining, and showing its last word as though it were current is how three
    -- missing miners looked like three busy ones.
    phase = health == "offline" and "offline" or (snap.phase or "unknown"),

    fuel = tonumber(snap.fuel) or 0,
    fuelLimit = tonumber(snap.fuelLimit) or nil,

    online = health ~= "offline",

    -- What turns a row red. `stuck` is the device's own word for it; `alert` is
    -- this app's, for a device that has an order it has not applied and has
    -- stopped talking - which the device itself cannot report, because it is the
    -- not-talking that is the problem.
    stuck = snap.phase == "stuck",
    alert = desired.status(record, now) == "unreachable",
  }
end

--- Every device, in a stable order.
---
--- By label, not by staleness. Devices sorts by staleness because it is the page
--- you open when something is wrong; this is the page you leave open, and a list
--- that reorders itself while somebody is looking at it is a list nobody can
--- read at a glance. `naturalLess` so that `miner-10` comes after `miner-9`.
function app.rows(state, now)
  local rows = {}
  for _, record in ipairs(registry.records(state.fleet)) do
    rows[#rows + 1] = app.row(record, now)
  end
  table.sort(rows, function(a, b)
    return require("lib.util").naturalLess(tostring(a.label), tostring(b.label))
  end)
  return rows
end

--- The message that asks the server to want something of a device.
---
--- Identical in shape to the Devices app's, because it is the same request. An
--- app never sends an order to a device: it asks the server to hold a goal, and
--- `reconcile` carries it - so a press dropped by a radio is retried by
--- machinery that already exists.
function app.intent(id, mode)
  if id == nil or not desired.MODES[mode] then
    return nil
  end
  return { kind = "want", id = id, mode = mode }
end

--- Mount the page.
---
--- `options.readOnly` is how a monitor gets the same screen with no actions:
--- the callbacks are simply not passed, and the view builds no buttons for
--- callbacks it does not have.
function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)

  local devices = scope:Computed(function(use)
    -- `tick` is what makes ages advance. Without it the list would recompute
    -- only when a device appeared or vanished, and a page whose whole job is
    -- showing how long something has been quiet would show the same number
    -- forever.
    use(tick)
    return app.rows(context.state, context.clock.now())
  end)

  local selected = options.selected or scope:Value(nil)

  -- Through the context rather than the transport, because on the base station
  -- itself a broadcast reaches nobody: rednet does not loop back, so these
  -- buttons worked from any other computer and did nothing on the machine that
  -- owns the fleet. See `os/kernel/request.lua`.
  local ask = request.of(context, options.protocol)

  local function want(id, mode)
    local message = app.intent(id, mode)
    if message then
      ask(message)
    end
    return message
  end

  --- Ask for something of every device on the page.
  ---
  --- One message each rather than a broadcast the server fans out, because the
  --- server's job is to hold goals and a "want this of everybody" message would
  --- be a second way to set them - one that a device joining a second later
  --- would miss, and that nothing would retry.
  local function wantAll(mode)
    local sent = 0
    for _, row in ipairs(app.rows(context.state, context.clock.now())) do
      if want(row.id, mode) then
        sent = sent + 1
      end
    end
    return sent
  end

  local page = {
    devices = devices,
    selected = selected,
    capacity = options.capacity or 10,
    title = "Fleet",

    onSelect = function(device)
      selected:set(device and device.id or nil)
    end,
  }

  -- A block, not `readOnly and nil or fn`. That idiom always yields the
  -- function - `true and nil` is nil and `nil or fn` is fn - so the guard did
  -- nothing wherever it was written. This is the page most likely to be left on
  -- a monitor, which makes it the one where that mattered most.
  if not options.readOnly then
    page.onDeploy = function()
      return wantAll("deploy")
    end
    page.onRecall = function()
      return wantAll("recall")
    end
    -- Stop is per-device and the view disables it with nothing selected, which
    -- is derived rather than toggled - there is no code path that leaves it
    -- enabled with no target.
    page.onStop = function()
      return want(require("ui.state.reactive").peek(selected), "stop")
    end
  end

  return view.build(scope, page)
end

return app
