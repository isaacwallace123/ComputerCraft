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
local function columns()
  return {
    { Title = "Device", Grow = 1, Key = "label" },
    { Title = "Status", Width = 12, Key = "phase", Tone = devices.phaseTone },
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

  local nothingSelected = scope:Computed(function(use)
    return use(current) == nil
  end)

  local detail = scope:Card({
    Width = 22,
    Padding = 1,
    Gap = 0,
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

  action("Deploy all", "primary", options.onDeploy)
  action("Recall all", nil, options.onRecall)
  action("Stop all", "destructive", options.onStop)

  return scope:Page({
    Title = options.title or "Fleet",
    Status = scope:Computed(function(use)
      return ("%d known"):format(#use(roster))
    end),
    Children = {
      scope:Row({
        Grow = 1,
        Gap = 2,
        Children = { list, detail },
      }),
    },
    Actions = actions,
  })
end

return devices
