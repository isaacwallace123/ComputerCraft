--- The fleet: every device, one of them in detail, and orders for all of them.
---
--- This is the Devices page and the Fleet page, which were two pages because
--- one of them could command a single turtle. It cannot any more - see the
--- actions below - and once that went there was nothing left to tell them
--- apart: a roster with a detail panel, and a roster with a detail panel.
---
--- ## The four criteria from docs/ui-design.md section 7
---
---   * **no coordinates** - there is not an `x` or a `y` below.
---   * **no colours** - only tokens, reached through functions that say what a
---     value *means*.
---   * **no redraw calls** - handing `devices:set(...)` a new list is the entire
---     update path. Nothing tells the screen to catch up.
---   * **no stale derived values** - the detail panel, the button states and the
---     summary are all `Computed` over the same list the table reads, so none of
---     them can disagree with it.
---
--- ## Still a view, and only a view
---
--- No file, no radio. State objects and callbacks in, a node tree out - which is
--- why the whole page is rendered into a recording buffer and asserted cell by
--- cell in the spec suite, with no world and no Minecraft. `app.lua` is the file
--- that touches a running fleet.

local theme = require("ui.theme")
local format = require("ui.format")

local T = theme.TOKENS

local devices = {}

---------------------------------------------------------------------------
-- What a device's state looks like
---------------------------------------------------------------------------

local WORKING = {
  mining = true,
  working = true,
  returning = true,
  travelling = true,
  refuelling = true,
}

local IDLE = {
  parked = true,
  ready = true,
  offline = true,
}

--- What a phase means, as a token.
---
--- Centralised here rather than at the call site because "which states are bad"
--- is a fleet policy question, and the answer has already changed once: an
--- unsealed shaft head was added to it in v1.2.7 and every screen that had its
--- own opinion had to be found. See D023 - an exposed shaft is reported ahead of
--- a full depot, because one is inconvenient and the other is a hole somebody
--- falls into.
function devices.phaseTone(device)
  if device == nil then
    return T.mutedFg
  end
  local phase = tostring(device.phase or "")
  if device.alert or device.stuck then
    return T.destructive
  end
  if IDLE[phase] then
    return T.mutedFg
  end
  if WORKING[phase] then
    return T.good
  end
  -- An unknown phase is a warning rather than an error. Modpack updates and
  -- rolling OTA deploys both produce turtles reporting a state this build has
  -- never heard of, and colouring those red would cry wolf on every upgrade.
  return T.warn
end

--- Fuel as a fraction of what this turtle can hold, for the meter.
function devices.fuelFraction(device)
  if device == nil then
    return 0
  end
  local limit = tonumber(device.fuelLimit) or 100000
  if limit <= 0 then
    return 0
  end
  return math.max(0, math.min(1, (tonumber(device.fuel) or 0) / limit))
end

--- Below this, the meter turns red rather than accent.
---
--- A fraction rather than an absolute, because an advanced turtle holds 100,000
--- and a standard one 20,000, and a single threshold would be a crisis on one
--- and a full tank on the other. The exact return-route reserve is D009's job;
--- this is only the colour on a dashboard.
devices.LOW_FUEL = 0.15

function devices.fuelTint(device)
  return devices.fuelFraction(device) < devices.LOW_FUEL and T.destructive or T.accent
end

--- The columns, narrow because this page is half list and half detail.
---
--- The label is the only thing wide enough to matter at a glance; the status is
--- the only thing coloured. Both decisions are the same one: on a page this
--- dense, anything that is always visible has to earn its width.
--- Where a device is, short enough for a column.
---
--- `x y z` with no punctuation, because commas cost three cells across a fleet
--- and buy nothing - the numbers are already separated by being numbers. A
--- device that has never reported a position gets a dash rather than zeros:
--- `0 0 0` is a real place in the world and has already cost this fleet a night.
local function place(device)
  local at = device and device.location
  if type(at) ~= "table" or tonumber(at.x) == nil then
    return "-"
  end
  return ("%d %d %d"):format(at.x, at.y or 0, at.z or 0)
end

local function columns()
  return {
    { Title = "Device", Grow = 1, Key = "label" },
    { Title = "Status", Width = 10, Key = "phase", Tone = devices.phaseTone },

    -- Third column, because "where is it" is the question a fleet page is opened
    -- to answer as often as "what is it doing" - and until now the only way to
    -- get it was to select a row and read a panel.
    {
      Title = "Position",
      Width = 13,
      Value = place,
      Tone = function(device)
        return (device and device.location) and T.mutedFg or T.border
      end,
    },
  }
end

--- A labelled value, which is most of what a detail panel is.
---
--- Both halves are `Muted` except the value, so a panel of ten of these reads as
--- one block of secondary information with the answers picked out - rather than
--- as ten competing lines, which is what the current page looks like.
local function field(scope, label, value, tone)
  return scope:Row({
    Height = 1,
    Children = {
      scope:Muted({ Text = label, Width = 9 }),
      scope:Text({ Text = value, Grow = 1, Color = tone }),
    },
  })
end

--- Build the page.
---
--- `options.devices` is a state object holding the roster; `options.selected`
--- holds the id of the highlighted device, or nil. Everything else is derived.
---
--- The action callbacks are optional, exactly as in the Fleet view, so that a
--- display-only monitor mounts the same page with none of them and there is no
--- code path that could put a deploy button on a wall. D020's `requiresInput`
--- boundary, expressed as an absent argument rather than as a branch. The
--- settings editor follows the same rule: without `onSetting` or `onJob` there is
--- no editor and no button to reach one.
function devices.build(scope, options)
  local roster = options.devices
  local selected = options.selected
  local offset = options.offset or scope:Value(0)

  --- The selected device, or nil. Every other derived value hangs off this one,
  --- which is what makes it impossible for the detail panel to be showing a
  --- device the list is no longer highlighting.
  local current = scope:Computed(function(use)
    local id = use(selected)
    if id == nil then
      return nil
    end
    for _, device in ipairs(use(roster)) do
      if device.id == id then
        return device
      end
    end
    -- Selected but absent: the device dropped off the roster while its detail
    -- was open. Returning nil rather than the last known record is deliberate -
    -- a panel showing a device that is no longer there, with no indication that
    -- it is stale, is worse than an empty panel.
    return nil
  end)

  local function about(fn, fallback)
    return scope:Computed(function(use)
      local device = use(current)
      if device == nil then
        return fallback or ""
      end
      return fn(device)
    end)
  end

  local picking = scope:Value(false)

  local nothingSelected = scope:Computed(function(use)
    -- Also hidden while the picker is up. They occupy the same column and are
    -- never wanted together: you are either looking at one turtle or choosing
    -- what all of them do.
    return use(current) == nil or use(picking)
  end)

  --- The panel, which is not there when there is nothing to put in it.
  ---
  --- It used to sit empty with "No device selected / pick one from the li" -
  --- twenty-two cells of a fifty-one cell page spent on an instruction, cut off
  --- mid-word, permanently. A panel that appears when you select something says
  --- the same thing by existing.
  local detail = scope:Card({
    Width = 22,
    Padding = 1,
    Gap = 0,
    Hidden = nothingSelected,
    Children = {
      scope:Text({
        Text = about(function(device)
          return device.label or ("computer " .. tostring(device.id))
        end, "No device selected"),
        Color = scope:Computed(function(use)
          return use(nothingSelected) and T.mutedFg or T.foreground
        end),
      }),
      scope:Muted({
        Text = about(function(device)
          return ("id %d"):format(device.id or 0)
        end, "pick one from the list"),
      }),
      scope:Spacer({ Height = 1 }),

      field(
        scope,
        "status",
        about(function(device)
          return tostring(device.phase or "unknown")
        end, "-"),
        scope:Computed(function(use)
          return devices.phaseTone(use(current))
        end)
      ),
      field(
        scope,
        "job",
        about(function(device)
          return tostring(device.job or "none")
        end, "-")
      ),
      field(
        scope,
        "fuel",
        about(function(device)
          return format.count(device.fuel)
        end, "-")
      ),
      field(
        scope,
        "seen",
        about(function(device)
          return format.ago(device.since)
        end, "-")
      ),
      field(
        scope,
        "at",
        about(function(device)
          return place(device)
        end, "-")
      ),
      scope:Spacer({ Height = 1 }),

      scope:Meter({
        Height = 1,
        Value = scope:Computed(function(use)
          return devices.fuelFraction(use(current))
        end),
        Tint = scope:Computed(function(use)
          return devices.fuelTint(use(current))
        end),
      }),
    },
  })

  --- The settings editor: one Stepper per advertised field.
  ---
  --- A fixed pool of rows, bound to whatever the selected device advertises.
  ---
  --- The same reasoning as a table's `Capacity` (D031): build the slots once and
  --- let the bindings decide what is in them, rather than rebuilding the graph
  --- whenever the selection moves.
  ---
  --- This used to build rows from a **static** list, and the list it built them
  --- from was `devices.FIELDS` - the mining defaults - because nothing ever
  --- passed `options.fields`. So a farming turtle showed `vein budget` and
  --- `scan every`: four steppers for settings it does not have, wired to change
  --- settings it does not have, while its plot size was unreachable from the
  --- base. Every turtle advertises `settingFields` in its heartbeat and always
  --- had; the panel simply never looked.
  ---

  local list = scope:Table({
    Rows = roster,
    Selected = selected,
    Offset = offset,
    Identity = function(device)
      return device.id
    end,
    Capacity = options.capacity or 8,
    Grow = 1,
    Columns = columns(),
    -- Selection is the screen's state, not the table's. The table reports which
    -- row was pressed and nothing else, which is why the same table can drive a
    -- detail panel here and drive nothing at all on the Fleet page.
    OnSelect = options.onSelect and function(device)
      options.onSelect(device)
    end or nil,
  })

  --- The buttons, and what they act on.
  ---
  --- The whole fleet, always. There is no per-device Deploy any more and that is
  --- a decision about what this system is rather than a simplification of the
  --- page: turtles are dispatched, fuelled, assigned ground and recalled as a
  --- unit, and a button that moved one of them was a way to put the fleet into a
  --- state the server had no name for.
  ---
  --- The selection still does something - it drives the detail panel - so a row
  --- is a thing you look at rather than a thing you command.
  --- The job picker, which replaces the detail panel while it is open.
  ---
  --- A card in the page rather than a floating window: the framework has no
  --- overlay, and inventing one for a list of six items would be a lot of
  --- machinery for something that fits beside the table. It takes the panel's
  --- place because the two are never wanted at once - you are either looking at
  --- one turtle or choosing what all of them do.
  local jobRows = {}
  for _, entry in ipairs(options.jobs or {}) do
    jobRows[#jobRows + 1] = scope:Text({
      Height = 1,
      Text = format.ellipsis(entry.label or entry.id, 20),
      Color = scope:Computed(function(use)
        return use(options.job) == entry.id and T.accent or T.foreground
      end),
      OnClick = options.onJob and function()
        options.onJob(entry.id)
        picking:set(false)
      end or nil,
    })
  end

  local picker = scope:Card({
    Width = 22,
    Padding = 1,
    Gap = 0,
    Hidden = scope:Computed(function(use)
      return not use(picking)
    end),
    Children = (function()
      local children = {
        scope:Text({ Text = "Put the fleet on" }),
        scope:Spacer({ Height = 1 }),
      }
      for _, row in ipairs(jobRows) do
        children[#children + 1] = row
      end
      return children
    end)(),
  })

  local actions = {}
  local function action(text, variant, handler)
    if not handler then
      return
    end
    actions[#actions + 1] = scope:Button({
      Text = text,
      Variant = variant,
      Disabled = scope:Computed(function(use)
        return #use(roster) == 0
      end),
      OnClick = handler,
    })
  end

  -- Plain words. They were "Deploy all", "Recall all", "Stop all", and the
  -- "all" was doing no work: there is no other kind of deploy on this page, so
  -- it read as a warning about something that is simply how the system works.
  --
  -- The selection is for looking, not for commanding - it drives the panel and
  -- nothing else - so a button cannot mean two things depending on it.
  -- Left of Deploy, because it is the thing you choose before you send them and
  -- reading a row of buttons left to right should follow the order you use them.
  if options.onJob then
    actions[#actions + 1] = scope:Button({
      Text = "Job",
      Variant = "ghost",
      OnClick = function()
        picking:set(not picking:get())
      end,
    })
  end

  action("Deploy", "primary", options.onDeploy)
  action("Recall", nil, options.onRecall)
  action("Stop", "destructive", options.onStop)

  return scope:Page({
    Title = options.title or "Fleet",
    Status = scope:Computed(function(use)
      return ("%d known"):format(#use(roster))
    end),
    Children = {
      scope:Row({
        Grow = 1,
        Gap = 2,
        Children = { list, detail, picker },
      }),
    },
    Actions = actions,
  })
end

return devices
