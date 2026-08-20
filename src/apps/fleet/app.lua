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
local reactive = require("ui.state.reactive")
local request = require("os.kernel.request")
local view = require("apps.fleet.view")

local app = {}

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
  if health == "off" then
    -- Switched off on purpose, which is not the same as gone quiet. Saying so
    -- is the whole point of the farewell: a planned shutdown that read
    -- "offline" would raise the same alarm as a turtle that fell in lava, and
    -- an alarm raised for both is an alarm somebody learns to ignore.
    phase = "shut down"
  elseif health == "offline" then
    -- Not the last known phase. "mining" on a device nobody has heard from in
    -- twenty minutes is a claim the server cannot support.
    phase = "offline"
  elseif snap.parked then
    -- Just "parked". The column is twelve cells wide and `parked: setu` is what
    -- `parked: setup` looks like in twelve cells - a word cut in half, on every
    -- row, saying less than the word it was cut from. Why it is parked is a
    -- sentence, and a sentence belongs in the detail panel.
    phase = "parked"
  end

  return {
    id = record.id,
    label = snap.label or ("device-" .. tostring(record.id)),
    phase = phase,
    job = snap.job,

    -- Zero rather than nil when a device has not said. The floor is chosen to be
    -- honest rather than flattering: a meter that defaulted to full would hide
    -- the turtle that is about to strand itself, which is the one thing anybody
    -- checks a fuel column for.
    fuel = tonumber(snap.fuel) or 0,
    fuelLimit = tonumber(snap.fuelLimit),
    since = age,
    online = health == "online",

    -- An order the device has not acknowledged, on a device that has since gone
    -- quiet. Only the base can know this: a turtle cannot report that it has
    -- stopped talking to you, so nothing in the snapshot could ever say it.
    alert = health ~= "online" and record.desired ~= nil and not desired.converged(record),

    -- Kept alongside rather than folded into `phase`, because the table shows
    -- one and the detail panel shows the other, and a page that had to
    -- re-derive convergence from a string would be a page that could disagree
    -- with the server about whether an order had landed.
    -- Why it is parked, for the panel rather than the column.
    parkReason = snap.parkReason or snap.parkKind,

    -- Whether a fleet order means anything to it. See `app.commandable`.
    orders = snap.orders,

    goal = record.desired and record.desired.mode or nil,
    converged = desired.converged(record),
  }
end

--- Every device, quietest first.
---
--- The sort is `registry.byStaleness` rather than a local comparator, so the
--- Fleet page, the console and this one cannot disagree about what "worst first"
--- means - and so §6's rule is stated once.
--- Is this a machine the fleet page is about?
---
--- The roster is every machine that talks to the server, which since clients
--- started introducing themselves includes the screens - and a screen on a page
--- with Deploy and Recall on it is a row somebody will eventually click and
--- expect something from.
---
--- The test is the same one the server uses to decide who gets a goal: a device
--- says whether it takes orders. Absent means yes, because every turtle in the
--- world predates the field.
function app.commandable(row)
  return row.orders ~= false
end

function app.rows(state, now)
  local records = registry.records(state.fleet)
  local rows = {}
  for _, record in ipairs(records) do
    local row = app.row(record, now)
    if app.commandable(row) then
      rows[#rows + 1] = row
    end
  end
  -- By name, and by nothing else.
  --
  -- This used to lead with the stalest device, on the theory that the machine
  -- you have not heard from is the one you want to look at. In a live fleet
  -- that theory is wrong: the key is seconds-since-last-heartbeat, which moves
  -- continuously on every row and flips two rows past each other every time one
  -- of them checks in. With a heartbeat every couple of seconds and eight
  -- machines, the list never stops reordering - under the cursor, between the
  -- reading of a row and the clicking of it. A list you cannot point at is
  -- worse than one that buries the news, and staleness is already shown in the
  -- row itself for anyone looking for it.
  --
  -- A label is stable, it is what the operator calls the machine, and it sorts
  -- miner-4 next to miner-6 where they can be compared. The id is the
  -- tie-break, padded so 7 sorts before 11 rather than after it.
  table.sort(rows, function(a, b)
    local left, right = app.sortKey(a), app.sortKey(b)
    if left ~= right then
      return left < right
    end
    return tostring(a.id) < tostring(b.id)
  end)
  return rows
end

--- What a row sorts under: its label, with any trailing number padded.
---
--- Plain string order puts miner-11 before miner-7, because "1" < "7". Padding
--- the digits fixes that without needing a second comparison rule, and a label
--- with no number in it is unaffected.
function app.sortKey(row)
  local label = tostring((row.snap and row.snap.label) or row.label or row.id)
  return (label:gsub("%d+", function(digits)
    return string.format("%09d", tonumber(digits))
  end)):lower()
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
--- The message that asks the server to want something of the fleet.
---
--- **No `id`.** That absence is the whole design change: a `want` without one
--- is an order for every device the server knows about *and* for every device
--- that registers afterwards, because the server keeps it rather than fanning it
--- out once. See `os/server/services/discovery.lua`.
---
--- Refuses a mode that does not exist rather than sending it, so a typo is
--- caught where it was typed instead of arriving as a refusal somebody has to
--- interpret.
function app.intent(mode)
  if not desired.MODES[mode] then
    return nil
  end
  return { kind = "want", mode = mode }
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
  ---
  --- One message for the whole fleet, not one per device. That is the shape of
  --- the decision as well as a saving: turtles are dispatched, fuelled, assigned
  --- ground and recalled as a unit, so "recall" is a fact about the fleet and
  --- the server is where it belongs. Sending it per device would put the same
  --- fact in ten places and let them disagree - which is what happened, and is
  --- how a fleet ends up half recalled.
  ---
  --- It is also what makes a device that joins later behave: the server holds
  --- the goal, so a turtle that boots after the button was pressed is told what
  --- everybody else was told rather than sitting parked until somebody notices.
  local ask = request.of(context, options.protocol)

  local function want(mode)
    local message = app.intent(mode)
    if message then
      ask(message)
    end
    return message
  end

  local page = {
    devices = rows,
    selected = selected,
    capacity = options.capacity or 8,
    title = "Fleet",

    --- Clicking a row selects it; clicking it again lets it go.
    ---
    --- A list where the only way out of a selection is to pick a different one
    --- is a list you cannot stop looking at. It matters more here than usual,
    --- because the selection decides what the buttons act on: with a row chosen
    --- they move that turtle, and with none they move the fleet.
    onSelect = function(device)
      local id = device and device.id or nil
      selected:set(reactive.peek(selected) == id and nil or id)
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
    page.onDeploy = function()
      return want("deploy")
    end
    page.onRecall = function()
      return want("recall")
    end
    page.onStop = function()
      return want("stop")
    end
  end

  return view.build(scope, page)
end

return app
