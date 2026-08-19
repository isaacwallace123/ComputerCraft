--- Operations: where the mine is, and starting the fleet on it.
---
--- The twelfth of ICOS 1's thirteen apps. `legacy/apps/operations.lua` was a
--- stack of menus that asked for coordinates one at a time and redrew the whole
--- screen between each; this is one page showing the plan with the numbers
--- editable in place.
---
--- ## Placing the mine is the one thing a fleet cannot start without
---
--- `leases.claim` refuses every request until a plan is configured, so a base
--- with no mine is a base whose turtles all park with "no mine configured". That
--- is the first thing somebody sets up and the thing they set up once, which is
--- why it gets a page rather than being buried in setup.
---
--- ## Changing the grid clears the sector map, and the page says so first
---
--- Sector 7 under a 48-block grid is not the same ground as sector 7 under a
--- 64-block one. The server clears the map when the geometry moves, and this
--- page shows that as a warning *before* the button is pressed rather than as a
--- result afterwards - somebody who has just lost a day of frontier progress is
--- owed the chance not to.
---
--- ## Deploy is per device, not a broadcast
---
--- "Start every parked miner" is a loop over `want`, not a new fleet-wide
--- message. Every device that comes back gets its own goal with its own
--- generation, so `reconcile` retries the three that were out of range without
--- re-sending to the seven that were not - and the Devices page shows exactly
--- which are behind. A broadcast would be one message, no record of who heard
--- it, and no way to tell the difference an hour later.

local desired = require("domain.fleet.desired")
local plan = require("domain.mine.plan")
local registry = require("domain.fleet.registry")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

app.manifest = {
  id = "operations",
  name = "Mine",
  roles = { "client", "mobile" },
  surfaces = { "desktop", "monitor", "handheld" },
  requiresInput = false,
}

--- The numbers a person edits, and what each one costs to get wrong.
---
--- `surfaceY` is the one that matters most and is easiest to mistype: it is the
--- height the turtles cruise at and descend from, so a value ten blocks under
--- the ground means every shaft starts inside rock and every trip home ends in
--- one.
app.FIELDS = {
  { key = "centreX", label = "Centre X", step = 16, min = -30000000, max = 30000000 },
  { key = "centreZ", label = "Centre Z", step = 16, min = -30000000, max = 30000000 },
  { key = "surfaceY", label = "Surface Y", step = 1, min = -63, max = 310 },
  { key = "cellSize", label = "Sector size", step = 8, min = 16, max = 128 },
  { key = "minRing", label = "Inner ring", step = 1, min = 0, max = 11 },
  { key = "maxRing", label = "Outer ring", step = 1, min = 1, max = 12 },
}

--- Which fields, if changed, throw the sector map away.
---
--- All of them. Every one changes what ground a sector index refers to, so
--- there is no "safe" edit here - and a table with one entry per field, all
--- true, is more honest than a comment saying the same thing.
app.REGRIDS = {
  centreX = true,
  centreZ = true,
  surfaceY = true,
  cellSize = true,
  minRing = true,
  maxRing = true,
}

--- Ask the server to change one number.
function app.intent(key, value)
  for _, field in ipairs(app.FIELDS) do
    if field.key == key then
      return { kind = "mineplan", set = { [key] = value } }
    end
  end
  return nil
end

--- Ask to place the mine at a whole position at once.
---
--- Three fields in one message rather than three messages, because a mine that
--- moved its X and then its Z would exist at a corner it was never meant to
--- occupy for as long as the round trip took - and every turtle asking for a
--- sector in between would be given one there.
function app.place(x, y, z)
  x, y, z = tonumber(x), tonumber(y), tonumber(z)
  if x == nil or y == nil or z == nil then
    return nil
  end
  return { kind = "mineplan", set = { centreX = x, surfaceY = y, centreZ = z } }
end

--- What the page says about the mine.
function app.summary(state)
  local mine = state and state.mine
  if mine == nil or mine.plan == nil then
    return "waiting for the server", T.mutedFg
  end
  if not mine.plan.configured then
    return "no mine placed - the fleet cannot deploy", T.warn
  end
  return ("%d sectors"):format(plan.capacity(mine.plan)), T.good
end

--- Every device that could be started right now.
---
--- Parked, online, and a turtle. Offline devices are skipped rather than
--- included-and-retried: a goal set on a device that has been silent for twenty
--- minutes would show as pending forever on the Devices page and tell nobody
--- anything, whereas leaving it alone means the count on this button is the
--- number of turtles that will actually move.
function app.deployable(state, now)
  local out = {}
  for _, record in ipairs(registry.records(state.fleet)) do
    local snap = record.snap or {}
    if snap.parked and registry.health(record, now) == "online" then
      out[#out + 1] = record
    end
  end
  return out
end

function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)

  local mine = scope:Computed(function(use)
    use(tick)
    return context.state and context.state.mine or nil
  end)

  local function send(message)
    if message and context.transport then
      context.transport.broadcast(message, options.protocol or "icos")
    end
    return message
  end

  local rows = {}
  for _, field in ipairs(app.FIELDS) do
    rows[#rows + 1] = scope:Stepper({
      Label = field.label,
      Step = field.step,
      Min = field.min,
      Max = field.max,
      ValueWidth = 9,
      Value = scope:Computed(function(use)
        local current = use(mine)
        return current and current.plan and tonumber(current.plan[field.key]) or 0
      end),
      Disabled = scope:Computed(function(use)
        return use(mine) == nil
      end),
      OnChange = options.readOnly and nil or function(value)
        send(app.intent(field.key, value))
      end,
    })
  end

  -- The warning sits above the buttons rather than beside the fields, because
  -- it is about the *act* of changing one and somebody reads downward.
  rows[#rows + 1] = scope:Spacer({ Height = 1 })
  rows[#rows + 1] = scope:Muted({
    Height = 1,
    Text = "Moving or resizing the mine clears every sector's progress.",
    Color = T.warn,
  })

  local status = scope:Computed(function(use)
    use(tick)
    return (app.summary(context.state))
  end)

  local actions = nil
  if not options.readOnly then
    local ready = scope:Computed(function(use)
      use(tick)
      return #app.deployable(context.state, context.clock.now())
    end)

    actions = {
      scope:Button({
        Text = scope:Computed(function(use)
          return ("Deploy %d"):format(use(ready))
        end),
        Variant = "primary",
        Disabled = scope:Computed(function(use)
          local current = use(mine)
          return use(ready) == 0 or current == nil or not current.plan.configured
        end),
        OnClick = function()
          -- One goal per device. See the header: a broadcast would be one
          -- message with no record of who heard it.
          for _, record in ipairs(app.deployable(context.state, context.clock.now())) do
            send({ kind = "want", id = record.id, mode = "deploy" })
          end
        end,
      }),
      scope:Button({
        Text = "Recall all",
        Variant = "destructive",
        OnClick = function()
          for _, record in ipairs(registry.records(context.state.fleet)) do
            if desired.MODES.recall then
              send({ kind = "want", id = record.id, mode = "recall" })
            end
          end
        end,
      }),
    }
  end

  return scope:Page({
    Title = "Mine",
    Status = status,
    Children = rows,
    Actions = actions,
  })
end

return app
