--- The Devices page, rebuilt on the framework.
---
--- This is the acceptance test §14 of docs/ui-framework.md set for the whole
--- project: *"Phase 2 rebuilding Devices specifically is deliberate: it is the
--- densest existing screen, with a list, a detail view, a settings editor, and
--- scrolling. If it does not come out simpler than the current version, the
--- framework is not earning its place and the plan should be revisited."*
---
--- `src/apps/devices.lua` is the version this is written against. Read the two
--- side by side; the comparison is the point, not this file on its own.
---
--- ## The four criteria from docs/ui-design.md §7
---
---   * **no coordinates** — there is not an `x` or a `y` below.
---   * **no colours** — only tokens, reached through functions that say what a
---     value *means*.
---   * **no redraw calls** — handing `devices:set(...)` a new list is the entire
---     update path. Nothing tells the screen to catch up.
---   * **no stale derived values** — the detail panel, the button states and the
---     summary are all `Computed` over the same list the table reads, so none of
---     them can disagree with it.
---
--- ## Still a view, and only a view
---
--- No file, no radio, no `fleet.roster`. State objects and callbacks in, a node
--- tree out — which is why the whole page is rendered into a recording buffer
--- and asserted cell by cell in the spec suite, with no world and no Minecraft.
--- The composition root that wires it to `legacy/fleet/roster.lua` and the desktop is
--- `app.lua`, and that is the file that touches a running fleet.

local catalogue = require("domain.turtle.jobs")
local fleetView = require("apps.fleet.view")
local theme = require("ui.theme")
local format = require("ui.format")

local T = theme.TOKENS

local devices = {}

--- The columns, narrow because this page is half list and half detail.
---
--- The label is the only thing wide enough to matter at a glance; the status is
--- the only thing coloured. Both decisions are the same one: on a page this
--- dense, anything that is always visible has to earn its width.
local function columns()
  return {
    { Title = "Device", Grow = 1, Key = "label" },
    { Title = "Status", Width = 12, Key = "phase", Tone = fleetView.phaseTone },
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

--- The jobs a turtle can be switched to, in the order the picker cycles.
---
--- Derived from `domain/turtle/jobs.lua` rather than listed here. It used to be
--- a copy of `src/apps/devices.lua`'s `JOB_ORDER`, with a comment admitting it
--- was a copy and pointing out that the turtle is the authority when the two
--- diverge - which is true, and is a description of a bug rather than a design.
---
--- The catalogue is data in `domain/` precisely so both ends of the radio read
--- the same list. A picker that offered a job no turtle has is a picker that
--- produces a refusal somebody has to interpret, and it happened every time a
--- job was added and this line was not.
---
--- Catalogue order, which is a deliberate statement about what a person most
--- likely wants and would be thrown away by sorting.
devices.JOBS = (function()
  local ids = {}
  for index, entry in ipairs(catalogue.list()) do
    ids[index] = entry.id
  end
  return ids
end)()

--- The default configuration fields, when a snapshot does not carry its own.
---
--- Real turtles advertise `settingFields` in their heartbeat, because which
--- settings exist depends on the job the turtle is running. This is the fallback
--- for a device that has not reported any yet, and it is deliberately the same
--- shape, so the panel below has one code path rather than two.
--- How many stepper rows the settings panel builds.
---
--- Six, which is the most any job in the catalogue advertises - `quarry`, with
--- two bounds on each of three axes. A job with fewer hides the remainder; a job
--- with more would have its extra settings unreachable from the base, which is
--- worth knowing about rather than growing the pool for, because a page that
--- asks somebody to scroll through nine steppers on a monitor is a page that has
--- stopped being a dashboard.
devices.SETTING_SLOTS = 6

devices.FIELDS = {
  { key = "targetY", label = "target Y", step = 1, min = -63, max = 320 },
  { key = "veinBudget", label = "vein budget", step = 8, min = 0, max = 512 },
  { key = "veinRadius", label = "vein radius", step = 1, min = 0, max = 32 },
  { key = "scanEvery", label = "scan every", step = 10, min = 0, max = 10000 },
}

--- May this device's settings be changed right now?
---
--- The fleet's standing rule, and one of the high-risk invariants in
--- docs/ai-handoff.md: remote configuration and job assignment require a parked
--- turtle. A turtle halfway down a shaft that has its target depth changed
--- underneath it is how a run ends somewhere nobody expected.
---
--- Expressed as a function over a record so the panel *derives* it rather than
--- being told, which means there is no code path that leaves the editor enabled
--- while a turtle is working.
local PARKED = { parked = true, ready = true }

function devices.configurable(device)
  return device ~= nil and PARKED[tostring(device.phase or "")] == true
end

---------------------------------------------------------------------------

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
  -- Which half of the right-hand panel is showing. Screen state, so it defaults
  -- to a `Value` the view owns - but accepted from the caller like `offset`,
  -- because a composition root that restores a page across a reopen needs to be
  -- able to hold it, and a spec needs to be able to start in either half.
  local editing = options.editing or scope:Value(false)

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
    Hidden = scope:Computed(function(use)
      return use(editing)
    end),
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
          return fleetView.phaseTone(use(current))
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
          return fleetView.fuelFraction(use(current))
        end),
        Tint = scope:Computed(function(use)
          return fleetView.fuelTint(use(current))
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
  --- Reading them per device is what makes this panel work for a job that does
  --- not exist yet, which is the same property the job catalogue has and for the
  --- same reason.
  local function fieldAt(slot)
    return scope:Computed(function(use)
      local device = use(current)
      if device == nil then
        return nil
      end
      local advertised = device.settingFields
      if type(advertised) ~= "table" or #advertised == 0 then
        advertised = devices.FIELDS
      end
      return advertised[slot]
    end)
  end

  local fieldRows = {}
  for slot = 1, devices.SETTING_SLOTS do
    local descriptor = fieldAt(slot)

    fieldRows[#fieldRows + 1] = scope:Stepper({
      -- Structural, so a job with four settings does not leave two dead rows
      -- taking up the panel. `Hidden` is a layout property, so the column
      -- closes up rather than showing gaps.
      Hidden = scope:Computed(function(use)
        return use(descriptor) == nil
      end),
      Label = scope:Computed(function(use)
        local setting = use(descriptor)
        return setting and setting.label or ""
      end),
      Step = scope:Computed(function(use)
        local setting = use(descriptor)
        return setting and setting.step or 1
      end),
      Min = scope:Computed(function(use)
        local setting = use(descriptor)
        return setting and setting.min or nil
      end),
      Max = scope:Computed(function(use)
        local setting = use(descriptor)
        return setting and setting.max or nil
      end),
      ValueWidth = 6,
      Value = scope:Computed(function(use)
        local device = use(current)
        local setting = use(descriptor)
        if device == nil or setting == nil then
          return 0
        end
        return tonumber((device.settings or {})[setting.key]) or 0
      end),
      -- D019 and the fleet's own rule: configuration requires a parked turtle.
      -- Derived from the same record the panel is showing, so there is no path
      -- that enables these while a turtle is underground.
      Disabled = scope:Computed(function(use)
        local device = use(current)
        return device == nil or not devices.configurable(device)
      end),
      OnChange = options.onSetting and function(value)
        local device = current:get()
        local setting = descriptor:get()
        if device and setting then
          options.onSetting(device, setting.key, value)
        end
      end or nil,
    })
  end

  --- The editor takes the whole body, and the list steps aside.
  ---
  --- The first attempt put it in the detail panel's 22-cell slot beside the
  --- list. The solver duly shrank the longest field name to five characters -
  --- correctly, since `Grow` now gives space back - and "vein budget" became
  --- "vein ". `src/apps/devices.lua` is a full-width view for the same reason;
  --- a settings editor is a place you go, not a thing you glance at.
  local settings = scope:Column({
    Grow = 1,
    Padding = 1,
    Gap = 0,
    Background = T.card,
    Hidden = scope:Computed(function(use)
      return not use(editing)
    end),
    Children = {
      scope:Text({ Text = "Settings" }),
      scope:Muted({
        Text = scope:Computed(function(use)
          local device = use(current)
          if device == nil then
            return "no device"
          end
          if not devices.configurable(device) then
            return "park it first"
          end
          return device.job or "no job"
        end),
      }),
      scope:Spacer({ Height = 1 }),

      -- The job picker, which in `src/apps/devices.lua` is a separate view
      -- reached by a separate action that cycles on each press. It is a setting
      -- like any other, so here it is one, at the top of the list where it
      -- belongs: every field below it only means anything in the context of the
      -- job that reads them.
      scope:Select({
        Label = "job",
        Options = options.jobs or devices.JOBS,
        ValueWidth = 10,
        Value = about(function(device)
          return device.job
        end, nil),
        Disabled = scope:Computed(function(use)
          local device = use(current)
          return device == nil or not devices.configurable(device)
        end),
        OnChange = options.onJob and function(job)
          local device = current:get()
          if device then
            options.onJob(device, job)
          end
        end or nil,
      }),
      scope:Spacer({ Height = 1 }),

      scope:Column({ Gap = 0, Children = fieldRows }),
    },
  })

  local list = scope:Table({
    Hidden = scope:Computed(function(use)
      return use(editing)
    end),
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

  local actions = {}
  local function action(text, variant, handler)
    if not handler then
      return
    end
    actions[#actions + 1] = scope:Button({
      Text = text,
      Variant = variant,
      Disabled = nothingSelected,
      OnClick = function()
        local device = current:get()
        if device then
          handler(device)
        end
      end,
    })
  end

  action("Deploy", "primary", options.onDeploy)
  action("Recall", nil, options.onRecall)
  action("Stop", "destructive", options.onStop)

  -- The panel switch. Only offered when the screen supplied a way to persist a
  -- change; a display-only surface gets neither the button nor the editor.
  if options.onSetting or options.onJob then
    actions[#actions + 1] = scope:Button({
      Text = scope:Computed(function(use)
        return use(editing) and "Detail" or "Settings"
      end),
      Disabled = nothingSelected,
      OnClick = function()
        editing:set(not editing:get())
      end,
    })
  end

  return scope:Page({
    Title = options.title or "Devices",
    Status = scope:Computed(function(use)
      return ("%d known"):format(#use(roster))
    end),
    Children = {
      scope:Row({
        Grow = 1,
        Gap = 2,
        Children = { list, detail, settings },
      }),
    },
    Actions = actions,
  })
end

return devices
