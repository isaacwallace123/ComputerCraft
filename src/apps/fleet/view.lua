--- The Fleet dashboard, rebuilt on the framework.
---
--- This is the acceptance test for phase 2 of docs/ui-framework.md, and it is
--- written to be read against `src/apps/fleet.lua` - the version this replaces -
--- rather than admired on its own. The four criteria from section 7 of
--- docs/ui-design.md are the whole of it:
---
---   * **no coordinates.** There is not an `x` or a `y` anywhere below.
---   * **no colours.** Only tokens, and only through `Tone` functions that say
---     what a value means rather than what it looks like.
---   * **no redraw calls.** Nothing here tells the screen to catch up. Handing
---     `devices:set(...)` a new list is the entire update path.
---   * **no stale derived values.** The online count is a `Computed` over the
---     same list the table reads, so the two cannot disagree.
---
--- ## It is a view, and only a view
---
--- `build` takes state objects and callbacks. It does not open a file, touch
--- rednet, or know that a fleet service exists - which is what lets the whole
--- screen be rendered into a recording buffer and asserted cell by cell, with no
--- world and no Minecraft. The composition root wires this to
--- `legacy/fleet/roster.lua`; a spec wires it to a table.
---
--- That separation is the point of the ports layer arriving first. A dashboard
--- that reached for `fleet.devices()` directly would be untestable for exactly
--- the reason every screen in this repository is untestable today.
---
--- ## Why it lives here and not under `ui/`
---
--- `ui/` is the framework: it knows about cells, layout, and binding, and knows
--- nothing about mining. This file is the opposite - it knows what a stalled
--- turtle is and has no idea how a cell is painted. Putting a view inside the
--- framework would make the framework depend on the domain, which is the exact
--- inversion the layering in docs/icos-2.md section 3 exists to prevent.
---
--- `apps/fleet/view.lua` is where docs/icos-2.md section 4 puts it. The `app.lua`
--- beside it - the composition root that wires this to the fleet service and the
--- desktop - is a later phase, because that one touches a running fleet.

local theme = require("ui.theme")
local format = require("ui.format")

local T = theme.TOKENS

local fleet = {}

--- Phases that are not a problem, so that everything else stands out.
---
--- The list is the honest one: a turtle that is mining, walking home, or
--- emptying its inventory is working. Parked is neither good nor bad - it is
--- waiting for a person - so it reads as muted rather than green, because a wall
--- of green would make the four turtles that are actually fine indistinguishable
--- from the two that are stuck.
local WORKING = {
  mining = true,
  returning = true,
  unloading = true,
  travelling = true,
  descending = true,
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
function fleet.phaseTone(device)
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
function fleet.fuelFraction(device)
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
fleet.LOW_FUEL = 0.15

function fleet.fuelTint(device)
  return fleet.fuelFraction(device) < fleet.LOW_FUEL and T.destructive or T.accent
end

---------------------------------------------------------------------------

--- Build the page.
---
--- `options.devices` is a state object holding the device list; everything the
--- screen shows is derived from it. `options.selected` is the id of the
--- highlighted row, or nil. The three action callbacks are optional so that a
--- display-only monitor can mount the same screen with none of them - which is
--- the `requiresInput` boundary from D020 expressed as an absent argument rather
--- than as a branch inside the view.
function fleet.build(scope, options)
  local devices = options.devices
  local selected = options.selected

  local online = scope:Computed(function(use)
    local count = 0
    for _, device in ipairs(use(devices)) do
      if device.online then
        count = count + 1
      end
    end
    return count
  end)

  local status = scope:Computed(function(use)
    return ("%d of %d online"):format(use(online), #use(devices))
  end)

  local nothingSelected = scope:Computed(function(use)
    return use(selected) == nil
  end)

  local table = scope:Table({
    Rows = devices,
    Selected = selected,
    Identity = function(device)
      return device.id
    end,
    Capacity = options.capacity or 10,
    Grow = 1,
    Columns = {
      { Title = "Device", Width = 12, Key = "label" },
      { Title = "Status", Grow = 1, Key = "phase", Tone = fleet.phaseTone },
      {
        Title = "Fuel",
        Width = 7,
        Align = "right",
        Key = "fuel",
        Format = format.count,
        Tone = function()
          return T.mutedFg
        end,
      },
      -- The meter is a column like any other, so its width is in the same list
      -- as the headings and the two cannot drift apart. It is handed the row's
      -- surface because of the rule in docs/ui-design.md: a `muted` track on a
      -- `muted` selected row is invisible, so anything that recesses has to know
      -- what it is sitting on.
      {
        Title = "",
        Width = 10,
        Render = function(rowScope, row, surface)
          return rowScope:Meter({
            Width = 10,
            Value = rowScope:Computed(function(use)
              return fleet.fuelFraction(row(use))
            end),
            Tint = rowScope:Computed(function(use)
              return fleet.fuelTint(row(use))
            end),
            Track = rowScope:Computed(function(use)
              return use(surface) == T.muted and T.border or T.muted
            end),
          })
        end,
      },
    },
  })

  local actions = {}
  if options.onDeploy then
    actions[#actions + 1] = scope:Button({
      Text = "Deploy all",
      Variant = "primary",
      OnClick = options.onDeploy,
    })
  end
  if options.onRecall then
    actions[#actions + 1] = scope:Button({ Text = "Recall", OnClick = options.onRecall })
  end
  if options.onStop then
    actions[#actions + 1] = scope:Button({
      Text = "Stop",
      Variant = "destructive",
      -- Disabled is derived, never toggled. There is no code path that can leave
      -- this button enabled while nothing is selected, because there is no code
      -- path that sets it at all.
      Disabled = nothingSelected,
      OnClick = options.onStop,
    })
  end

  return scope:Page({
    Title = options.title or "Fleet",
    Status = status,
    Children = { table },
    Actions = actions,
  })
end

return fleet
