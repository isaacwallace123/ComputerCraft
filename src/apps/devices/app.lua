--- Devices, wired: the composition root that turns the view into an app.
---
--- `view.lua` is a function from state to a node tree and touches nothing. This
--- is the file that touches a running fleet - it reads the client's mirror,
--- turns records into the rows the view draws, and turns a button press into a
--- goal on the server.
---
--- ## The split is the point
---
--- §4: **services own state, apps read it.** This app holds no roster of its
--- own, opens no radio of its own, and coordinates nothing. It reads
--- `context.state.fleet`, which `os/client/main.lua`'s `sync` service keeps
--- fresh, and it writes by asking the server - never by deciding.
---
--- D018 is the reason. Sector leasing used to live inside the Fleet page, so
--- closing the page stopped two turtles being kept out of the same shaft. An app
--- that is closed, crashed, or was never opened must change nothing about what
--- the fleet is doing, and the only way to guarantee that is for it to own
--- nothing that matters.
---
--- ## Sorted by staleness, which is the whole of §6
---
--- *"Three miners vanished and nothing knew where."* A roster sorted by name
--- buries the one device that has stopped reporting among nine that are fine -
--- the healthy ones need no attention at all. So the quietest device is first,
--- and the row carries how long it has been quiet rather than a green dot that
--- means "was fine at some point".
---
--- ## Actions are goals, not commands
---
--- Deploy does not send "deploy". It asks the server to *want* the device
--- deployed, and `reconcile` keeps saying so until the device agrees. A button
--- press that is dropped by a radio is therefore retried without the person who
--- pressed it having to know, which is the difference §5 exists to make - and
--- the reason the page has no "sent" state to display, because "sent" was never
--- the honest word for it.

local desired = require("domain.fleet.desired")
local registry = require("domain.fleet.registry")
local view = require("apps.devices.view")
local wire = require("domain.protocol.message")

local app = {}

--- The manifest.
---
--- Declared rather than inferred, and `requiresInput` is the load-bearing field:
--- D020 says a display-only surface gets no controls, and this app expresses
--- that by handing the view no callbacks rather than by branching inside it.
--- A monitor on a wall mounts the same page and there is no code path that
--- could put a Deploy button on it.
app.manifest = {
  id = "devices",
  name = "Devices",
  -- `server` for the same reason Fleet carries it: a base with a screen is both
  -- halves of §2's split, and reads its own authoritative state rather than a
  -- mirror of it.
  roles = { "client", "mobile", "server" },
  surfaces = { "desktop", "monitor", "handheld" },
  requiresInput = false,
}

--- Turn one registry record into a row the view can draw.
---
--- The view asks for `label`, `phase`, `fuel`, `job`, `since` and `settings`,
--- and none of those are what a record holds - a record holds a snapshot the
--- device sent and a time the server heard it. Doing the translation here rather
--- than in the view is what lets the view be rendered into a buffer and asserted
--- cell by cell with no fleet anywhere.
---
--- `phase` is where the honesty lives. A device that has gone quiet reports the
--- phase it was in when it went quiet, which is *not* what it is doing now, and
--- showing that unqualified is how a dashboard tells somebody a turtle is mining
--- twenty minutes after it stopped. So an offline device says so instead.
function app.row(record, now)
  local snap = record.snap or {}
  local age = registry.age(record, now)
  local health = registry.health(record, now)

  local phase = snap.phase or snap.status or "idle"
  if health == "offline" then
    -- Not the last known phase. "mining" on a device nobody has heard from in
    -- twenty minutes is a claim the server cannot support.
    phase = "offline"
  elseif snap.parked then
    phase = snap.parkKind and ("parked: " .. snap.parkKind) or "parked"
  end

  return {
    id = record.id,
    label = snap.label or ("device-" .. tostring(record.id)),
    phase = phase,
    job = snap.job,
    fuel = tonumber(snap.fuel),
    fuelLimit = tonumber(snap.fuelLimit),
    settings = snap.settings,

    -- What this device says it can be configured with. Carried through rather
    -- than derived, because which settings a turtle has depends on the job it
    -- is running and the base must not need a copy of that - the same rule that
    -- makes `domain/turtle/jobs.lua` a catalogue of strings.
    settingFields = snap.settingFields,
    since = age,
    online = health == "online",

    -- Kept alongside rather than folded into `phase`, because the table shows
    -- one and the detail panel shows the other, and a page that had to
    -- re-derive convergence from a string would be a page that could disagree
    -- with the server about whether an order had landed.
    goal = record.desired and record.desired.mode or nil,
    converged = desired.converged(record),
  }
end

--- Every device, quietest first.
---
--- The sort is `registry.byStaleness` rather than a local comparator, so the
--- Fleet page, the console and this one cannot disagree about what "worst first"
--- means - and so §6's rule is stated once.
function app.rows(state, now)
  local records = registry.records(state.fleet)
  local rows = {}
  for index, record in ipairs(records) do
    rows[index] = app.row(record, now)
  end
  table.sort(rows, function(a, b)
    if a.since ~= b.since then
      return a.since > b.since
    end
    return tostring(a.id) < tostring(b.id)
  end)
  return rows
end

--- Ask the server to want something.
---
--- Returns the message rather than sending it, for the same reason every service
--- separates its decision from its loop: a spec drives this with a table, and
--- the one line that touches a radio is in `mount` where it can be read at a
--- glance.
---
--- `nil` for no device, which happens when somebody presses Deploy with nothing
--- selected. Silently doing nothing is right here: the alternative is an error
--- dialog for a mis-click.
function app.intent(device, mode, options)
  if device == nil or not desired.MODES[mode] then
    return nil
  end
  return {
    kind = "want",
    id = device.id,
    mode = mode,
    job = options and options.job,
    settings = options and options.settings,
  }
end

--- Wire the view to a client context.
---
--- `context` is what `os/client/main.lua` built: ports, and a mirror that `sync`
--- keeps fresh. `scope` is the UI scope the host mounted.
---
--- The roster is a `Computed` over the mirror rather than a `Value` this app
--- updates, which is what makes it impossible for the page to be showing a fleet
--- the client no longer believes in. Nothing here calls redraw; handing the
--- state a new list is the entire update path.
function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)

  local rows = scope:Computed(function(use)
    -- `tick` is the dependency that makes ages advance. Without it the list
    -- would only recompute when a device appeared or vanished, and a page whose
    -- whole point is showing how long something has been quiet would show the
    -- same number forever.
    use(tick)
    return app.rows(context.state, context.clock.now())
  end)

  local selected = options.selected or scope:Value(nil)

  --- Sending is the only thing in this file that talks to anything.
  local function want(device, mode, extra)
    local message = app.intent(device, mode, extra)
    if message and context.transport then
      context.transport.broadcast(wire.stamp(message), options.protocol or wire.NAME)
    end
    return message
  end

  local page = {
    devices = rows,
    selected = selected,
    capacity = options.capacity or 8,
    title = "Devices",

    onSelect = function(device)
      selected:set(device and device.id or nil)
    end,
  }

  -- Absent on a display-only surface, which is D020 expressed as an argument
  -- that is not passed rather than as a branch inside the view.
  --
  -- Written as a block rather than `readOnly and nil or fn` on each line, and
  -- that is not style. **`x and nil or y` always evaluates to `y`** - `and`
  -- yields nil, and `nil or y` is y - so the guard did nothing and every
  -- callback was passed on every surface. D020 calls this a safety boundary and
  -- it had been open since the page was written; this shape cannot be wrong,
  -- because there is nothing to get subtly right.
  if not options.readOnly then
    page.onDeploy = function(device)
      return want(device, "deploy")
    end
    page.onRecall = function(device)
      return want(device, "recall")
    end
    page.onStop = function(device)
      return want(device, "stop")
    end
    page.onJob = function(device, job)
      return want(device, "deploy", { job = job })
    end
    page.onSetting = function(device, key, value)
      local settings = {}
      for name, existing in pairs(device.settings or {}) do
        settings[name] = existing
      end
      settings[key] = value
      return want(device, "deploy", { job = device.job, settings = settings })
    end
  end

  return view.build(scope, page)
end

return app
