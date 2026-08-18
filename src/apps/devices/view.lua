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
--- The composition root that wires it to `fleet/roster.lua` and the desktop is
--- `app.lua`, and that is the file that touches a running fleet.

local fleetView = require("apps.fleet.view")
local theme = require("ui.theme")
local util = require("ui.util")

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

---------------------------------------------------------------------------

--- Build the page.
---
--- `options.devices` is a state object holding the roster; `options.selected`
--- holds the id of the highlighted device, or nil. Everything else is derived.
---
--- The action callbacks are optional, exactly as in the Fleet view, so that a
--- display-only monitor mounts the same page with none of them and there is no
--- code path that could put a deploy button on a wall. D020's `requiresInput`
--- boundary, expressed as an absent argument rather than as a branch.
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
          return util.count(device.fuel)
        end, "-")
      ),
      field(
        scope,
        "seen",
        about(function(device)
          return util.ago(device.since)
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

  return scope:Page({
    Title = options.title or "Devices",
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
