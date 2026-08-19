--- What this turtle is doing, and the form that changes it.
---
--- The page `os/turtle/engine.lua` is waiting for. That file is the turtle's
--- entire remaining dependency on ICOS 1, and §14 explains why it could not
--- simply be deleted: what `legacy/miner/context.lua` still does is **draw a
--- status screen and prompt for job setup**, and writing a second one to retire
--- the first would be building the thing twice. This is the first one, on the
--- framework, so the ICOS 1 copy can go rather than be duplicated.
---
--- ## It needs no radio, and that is the whole design
---
--- A turtle's own screen writes the same control flags the runner already reads -
--- `deploy`, `recall`, `configure` - which is exactly what `os/turtle/control.lua`
--- does when an order arrives from the base. So pressing Deploy here and being
--- deployed by the server take the identical path through `Runner:wait`, and
--- there is no second way for a turtle to be started.
---
--- That matters most when it is least convenient: somebody standing in front of
--- a turtle is usually there *because* the radio or the base has stopped working,
--- and a local screen that asked the server for permission would be useless at
--- the exact moment it is needed. D004, expressed as a page.
---
--- ## The form is the declaration, not a copy of it
---
--- Every job already carries `settingFields`, and `setup(ui)` hand-wrote the same
--- fields again as prompts. `domain/turtle/settings.lua` is now the one reader of
--- that declaration, so this page renders whatever the job declares and validates
--- through the same function a remote `configure` goes through. A job that gains
--- a field gains a row here, and nobody edits this file.
---
--- ## Two surfaces, one page
---
--- A turtle's screen is 39x13 with the job's own status above it, so `capacity`
--- is small - but the page also runs on a client, where somebody watching a
--- fleet wants to see what one turtle is doing without walking to it. D020 does
--- the rest: no callbacks on a display-only surface, and therefore no buttons.

local format = require("ui.format")
local settings = require("domain.turtle.settings")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

app.manifest = {
  id = "job",
  name = "Job",

  -- A turtle first, and a client because the same page answers "what is that
  -- turtle doing" from the base. Not a monitor: this is one machine's detail,
  -- and a wall wants the fleet.
  roles = { "turtle", "client", "server" },
  surfaces = { "launcher", "desktop", "handheld" },
  requiresInput = false,
}

---------------------------------------------------------------------------
-- Reading the turtle
---------------------------------------------------------------------------

--- The fields the status half draws, from a snapshot.
---
--- Pure, so the whole of what this page *says* is testable with a table and no
--- turtle. `snapshot` is whatever the composition root's `snapshot()` returned,
--- and every field in it is optional - a turtle mid-reboot and one on an older
--- build both report less than a working one.
---
--- `phase` is where the honesty lives, and it is the same rule the Devices page
--- follows: a parked turtle reports why it parked rather than the phase it was
--- in when it stopped, because "mining" on a machine that is standing still is a
--- claim the screen cannot support.
function app.status(snapshot)
  local snap = snapshot or {}
  local phase = snap.phase or "idle"

  if snap.parked then
    phase = snap.parkKind and ("parked: " .. snap.parkKind) or "parked"
  end

  local fuel = tonumber(snap.fuel)
  local required = tonumber(snap.fuelRequired)

  return {
    label = snap.label or "turtle",
    job = snap.job or "none",
    phase = phase,
    detail = snap.detail or "",
    parked = snap.parked == true,

    -- `-1` is an unlimited-fuel world. Shown as unlimited rather than as a
    -- number, because a meter at -1 would read as empty on the one screen
    -- somebody checks before sending a turtle a long way from home.
    fuel = fuel,
    unlimited = fuel ~= nil and fuel < 0,
    fuelRequired = required,

    -- The fraction a meter draws. Against what the job needs when the turtle is
    -- parked and about to leave, and against the trip home plus a margin while
    -- it is out - two different questions that matter at two different moments.
    fuelFraction = app.fuelFraction(snap),
    progress = math.max(0, math.min(1, tonumber(snap.progress) or 0)),

    x = tonumber(snap.x) or 0,
    y = tonumber(snap.y) or 0,
    z = tonumber(snap.z) or 0,
    world = snap.world,
    distanceHome = tonumber(snap.distanceHome) or 0,
    located = snap.located ~= false,
    chunk = snap.chunk,
    sector = snap.sector,
  }
end

--- How full the fuel meter is.
---
--- Separated because it is the one number here with a rule rather than a value,
--- and because getting it wrong is expensive: a meter that flattered a turtle
--- about to leave is a turtle that strands itself, which is the failure D009
--- exists to prevent.
function app.fuelFraction(snap)
  local fuel = tonumber(snap.fuel)
  if fuel == nil then
    return 0
  end
  if fuel < 0 then
    return 1
  end

  local goal
  if snap.parked and tonumber(snap.fuelRequired) then
    goal = tonumber(snap.fuelRequired)
  else
    goal = (tonumber(snap.distanceHome) or 0) + 64
  end

  return math.max(0, math.min(1, fuel / math.max(1, goal or 1)))
end

--- Is this turtle low on fuel for what it is about to do?
---
--- Only while parked, and only with something to compare against. A turtle
--- already out is past the point where this is actionable, and colouring its
--- meter red would be shouting about something nobody can fix from here.
function app.short(status)
  if not status.parked or status.unlimited then
    return false
  end
  return status.fuelRequired ~= nil and status.fuel ~= nil and status.fuel < status.fuelRequired
end

---------------------------------------------------------------------------
-- Orders
---------------------------------------------------------------------------

--- Raise a control flag, the same way an order from the base does.
---
--- Returns the flag that was raised, or nil when the turtle is in no state for
--- it. The rules are `lifecycle.KEYS`' rules: a running turtle has no deploy
--- because it is already deployed, and a parked one has no recall because it is
--- already home. Neither is a guard bolted on afterwards - the button is simply
--- not built.
function app.order(context, name)
  local flags = context.flags
  if type(flags) ~= "table" then
    return nil
  end
  flags[name] = true
  return name
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

local function statusRows(scope, state)
  local rows = {}

  rows[#rows + 1] = scope:Row({
    Height = 1,
    Children = {
      scope:Muted({ Text = "job", Width = 9 }),
      scope:Text({
        Text = scope:Computed(function(use)
          return use(state.status).job
        end),
      }),
    },
  })

  rows[#rows + 1] = scope:Row({
    Height = 1,
    Children = {
      scope:Muted({ Text = "phase", Width = 9 }),
      scope:Text({
        Text = scope:Computed(function(use)
          return use(state.status).phase
        end),
        Color = T.accent,
      }),
    },
  })

  rows[#rows + 1] = scope:Muted({
    Height = 1,
    Text = scope:Computed(function(use)
      return format.fit(use(state.status).detail, 38)
    end),
  })

  rows[#rows + 1] = scope:Row({
    Height = 1,
    Children = {
      scope:Muted({ Text = "at", Width = 9 }),
      scope:Text({
        Text = scope:Computed(function(use)
          local status = use(state.status)
          return ("%d, %d, %d"):format(status.x, status.y, status.z)
        end),
      }),
    },
  })

  rows[#rows + 1] = scope:Row({
    Height = 1,
    Children = {
      scope:Muted({ Text = "home", Width = 9 }),
      scope:Text({
        Text = scope:Computed(function(use)
          return ("%d blocks"):format(use(state.status).distanceHome)
        end),
      }),
    },
  })

  rows[#rows + 1] = scope:Row({
    Height = 1,
    Children = {
      scope:Muted({ Text = "fuel", Width = 9 }),
      scope:Meter({
        Width = 20,
        Value = scope:Computed(function(use)
          return use(state.status).fuelFraction
        end),
        Color = scope:Computed(function(use)
          return app.short(use(state.status)) and T.destructive or T.foreground
        end),
      }),
    },
  })

  rows[#rows + 1] = scope:Row({
    Height = 1,
    Children = {
      scope:Muted({ Text = "progress", Width = 9 }),
      scope:Meter({
        Width = 20,
        Value = scope:Computed(function(use)
          return use(state.status).progress
        end),
        Color = T.accent,
      }),
    },
  })

  return rows
end

--- One editable setting: a label, the value, and two nudges.
---
--- The buttons clamp through `settings.nudge`, so a control can never produce a
--- value its own validator would refuse - it simply stops at the end of the
--- range rather than offering something that is then rejected.
local function settingRow(scope, state, field, readOnly)
  local children = {
    scope:Muted({ Text = field.label, Width = 12 }),
    scope:Text({
      Width = 11,
      Text = scope:Computed(function(use)
        return tostring(use(state.values)[field.key])
      end),
    }),
  }

  if not readOnly then
    local function nudge(direction)
      return function()
        local next_ = {}
        for key, value in pairs(state.values:get()) do
          next_[key] = value
        end
        next_[field.key] = settings.nudge(field, next_[field.key], direction)
        state.values:set(next_)
      end
    end

    children[#children + 1] = scope:Button({ Text = "-", Size = "sm", OnClick = nudge(-1) })
    children[#children + 1] = scope:Spacer({ Width = 1 })
    children[#children + 1] = scope:Button({ Text = "+", Size = "sm", OnClick = nudge(1) })
  end

  return scope:Row({ Height = 1, Children = children })
end

--- Mount the page.
---
--- `options.module` is the job module, injected so a spec can drive the form with
--- a table instead of a mining job that reaches for `turtle`. On a real machine
--- it is resolved from the catalogue entry the composition root already picked.
function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)
  local readOnly = options.readOnly == true

  local module = options.module
  if module == nil and context.job and context.job.module then
    -- Required lazily and never on a spec's path: a job module reads `turtle`
    -- while loading, so requiring it at file scope would make this page
    -- unloadable anywhere except on a turtle.
    local ok, resolved = pcall(require, context.job.module)
    module = ok and resolved or nil
  end

  local fields = (module and module.settingFields) or {}
  local job = module and module.load and module.load() or {}

  local state = {
    editing = scope:Value(false),
    notice = scope:Value(""),
    values = scope:Value((function()
      local initial = {}
      for _, row in ipairs(settings.rows(fields, job)) do
        initial[row.key] = row.value
      end
      return initial
    end)()),
    status = scope:Computed(function(use)
      -- `tick` is what makes the numbers move. Without it the page would only
      -- recompute when somebody pressed something, and a status screen that
      -- froze while the turtle worked would be worse than none.
      use(tick)
      return app.status(context.snapshot and context.snapshot() or {})
    end),
  }

  local function save()
    if module == nil or module.configure == nil then
      state.notice:set("this job has no settings")
      return
    end
    local ok, why = module.configure(job, state.values:get())
    state.notice:set(ok and "saved" or tostring(why))
    if ok then
      state.editing:set(false)
    end
  end

  local children = {}
  for _, row in ipairs(statusRows(scope, state)) do
    children[#children + 1] = row
  end

  if #fields > 0 then
    children[#children + 1] = scope:Separator({})
    for _, field in ipairs(fields) do
      children[#children + 1] = scope:Row({
        Height = 1,
        Visible = scope:Computed(function(use)
          return use(state.editing)
        end),
        Children = { settingRow(scope, state, field, readOnly) },
      })
    end
  end

  children[#children + 1] = scope:Muted({
    Height = 1,
    Text = scope:Computed(function(use)
      return use(state.notice)
    end),
  })

  -- D020, as a block rather than as `readOnly and nil or {...}`. That idiom
  -- always yields the table - `true and nil` is nil and `nil or {...}` is the
  -- table - so the guard did nothing wherever it was written (D045).
  local actions = nil
  if not readOnly then
    actions = {
      scope:Button({
        Text = scope:Computed(function(use)
          return use(state.status).parked and "Deploy" or "Recall"
        end),
        Variant = "primary",
        OnClick = function()
          local parked = state.status:get().parked
          app.order(context, parked and "deploy" or "recall")
          state.notice:set(parked and "deploying" or "coming home")
        end,
      }),
      scope:Button({
        Text = scope:Computed(function(use)
          return use(state.editing) and "Save" or "Settings"
        end),
        -- Only while parked. Changing a job's settings underneath a turtle that
        -- is somewhere in the world with an open shaft behind it is the thing
        -- `control.apply` refuses for the base, and the local screen must not be
        -- a way around that rule.
        Disabled = scope:Computed(function(use)
          return not use(state.status).parked or #fields == 0
        end),
        OnClick = function()
          if state.editing:get() then
            save()
          else
            state.editing:set(true)
            state.notice:set("")
          end
        end,
      }),
    }
  end

  return scope:Page({
    Title = scope:Computed(function(use)
      return use(state.status).label
    end),
    Status = scope:Computed(function(use)
      local status = use(state.status)
      if not status.located then
        return "no world position - run locate"
      end
      return status.job
    end),
    Children = children,
    Actions = actions,
  })
end

return app
