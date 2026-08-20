--- Depots: where the fleet unloads, in the order it should try them.
---
--- ## The list had no way in
---
--- `domain/depot/list.lua` has had priorities, full-detection and item filters
--- since ICOS 1, and no page ever drew it. Every base ran with zero declared
--- drop-offs, which made the whole mechanism dead code wearing the shape of a
--- feature. This is the missing half.
---
--- ## Order is priority, and that is the point of having several
---
--- A single chest fills. When it does, a turtle holding a full inventory has
--- nowhere to put it, and the correct behaviour - stop and wait - looks exactly
--- like a turtle that has crashed. `list.usable` walks this list in order and
--- returns the first that is enabled, not full, and accepts what is being
--- carried, so a fleet routes around a full chest without anybody noticing.
---
--- Which chest should be tried first is a fact about the room somebody built,
--- so it is theirs to set: the arrows move a depot up and down the order.
---
--- ## Adding starts from where the base is
---
--- The steppers open on the server's own position rather than on zero, because
--- a depot is nearly always a chest a few blocks from the computer - so the edit
--- is three small nudges rather than typing six digits. `0, 0, 0` as a starting
--- point is a place in the world, and a turtle sent there flies the length of
--- the map to discover somebody left a field blank.

local request = require("os.kernel.request")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

--- The fields somebody edits to place a new depot.
app.FIELDS = {
  { key = "x", label = "World X", step = 1 },
  { key = "y", label = "World Y", step = 1 },
  { key = "z", label = "World Z", step = 1 },
}

--- One row per declared drop-off.
---
--- `order` is shown because priority is the whole reason the list is a list, and
--- a page that displayed a set would be hiding the one property that decides
--- which chest a turtle walks to.
function app.rows(state)
  local out = {}
  for index, depot in ipairs((state and state.depots and state.depots.depots) or {}) do
    local at = depot.position or {}
    out[#out + 1] = {
      id = depot.id,
      order = index,
      label = depot.label or depot.id,
      place = ("%d %d %d"):format(at.x or 0, at.y or 0, at.z or 0),

      -- Three states, not two. "Full" is a chest that is there and working and
      -- has no room; "off" is one somebody switched out of the rotation. A page
      -- that showed both as unavailable would hide which of them is a problem.
      state = (not depot.enabled) and "off" or (depot.full and "full" or "ready"),
      enabled = depot.enabled ~= false,
    }
  end
  return out
end

function app.summary(rows)
  if #rows == 0 then
    return "no depots - turtles have nowhere to unload", T.warn
  end

  local ready = 0
  for _, row in ipairs(rows) do
    if row.state == "ready" then
      ready = ready + 1
    end
  end

  if ready == 0 then
    return ("%d declared, none available"):format(#rows), T.destructive
  end
  return ("%d declared, %d ready"):format(#rows, ready), T.good
end

function app.tone(row)
  if row == nil or row.state == "ready" then
    return T.good
  end
  return row.state == "full" and T.warn or T.mutedFg
end

function app.columns()
  return {
    {
      Title = "#",
      Width = 2,
      Key = "order",
      Tone = function()
        return T.mutedFg
      end,
    },
    { Title = "Depot", Grow = 1, Key = "label" },
    {
      Title = "Position",
      Width = 13,
      Key = "place",
      Tone = function()
        return T.mutedFg
      end,
    },
    { Title = "State", Width = 6, Key = "state", Tone = app.tone },
  }
end

--- Where the steppers start from: the base's own position, or zero.
function app.here(context)
  local at = context.locator and context.locator.saved()
  if type(at) ~= "table" or tonumber(at.x) == nil then
    return { x = 0, y = 64, z = 0 }
  end
  return { x = math.floor(at.x), y = math.floor(at.y or 64), z = math.floor(at.z) }
end

function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)
  local ask = request.of(context, options.protocol)

  local rows = scope:Computed(function(use)
    use(tick)
    return app.rows(context.state)
  end)

  local status = scope:Computed(function(use)
    return (app.summary(use(rows)))
  end)

  local selected = options.selected or scope:Value(nil)

  local start = app.here(context)
  local draft = {
    x = scope:Value(start.x),
    y = scope:Value(start.y),
    z = scope:Value(start.z),
  }

  local children = {
    scope:Table({
      Grow = 1,
      Rows = rows,
      Selected = selected,
      Identity = function(row)
        return row.id
      end,
      Capacity = options.capacity or 5,
      Columns = app.columns(),
      OnSelect = options.readOnly and nil or function(row)
        local id = row and row.id or nil
        selected:set(selected:get() == id and nil or id)
      end,
    }),
  }

  if not options.readOnly then
    children[#children + 1] = scope:Separator({})

    for _, field in ipairs(app.FIELDS) do
      children[#children + 1] = scope:Stepper({
        Label = field.label,
        Step = field.step,
        Min = -30000000,
        Max = 30000000,
        ValueWidth = 9,
        Value = draft[field.key],
        OnChange = function(value)
          draft[field.key]:set(value)
        end,
      })
    end

    children[#children + 1] = scope:Muted({
      Height = 1,
      Text = scope:Computed(function(use)
        return ("Add a chest at %d %d %d"):format(use(draft.x), use(draft.y), use(draft.z))
      end),
    })
  end

  local actions = nil
  if not options.readOnly then
    actions = {
      scope:Button({
        Text = "Add",
        Variant = "primary",
        OnClick = function()
          ask({
            kind = "depot",
            body = {
              action = "add",
              position = { x = draft.x:get(), y = draft.y:get(), z = draft.z:get() },
            },
          })
        end,
      }),

      -- Only meaningful with something chosen, and hidden rather than disabled
      -- when there is not: a row of greyed-out buttons is a row somebody has to
      -- read before learning it does nothing.
      scope:Button({
        Text = "Up",
        Variant = "ghost",
        Hidden = scope:Computed(function(use)
          return use(selected) == nil
        end),
        OnClick = function()
          ask({ kind = "depot", body = { action = "move", id = selected:get(), delta = -1 } })
        end,
      }),
      scope:Button({
        Text = "Off",
        Variant = "ghost",
        Hidden = scope:Computed(function(use)
          return use(selected) == nil
        end),
        OnClick = function()
          local id = selected:get()
          local wanted = true
          for _, row in ipairs(rows:get()) do
            if row.id == id then
              wanted = not row.enabled
            end
          end
          ask({ kind = "depot", body = { action = "enable", id = id, enabled = wanted } })
        end,
      }),
      scope:Button({
        Text = "Remove",
        Variant = "destructive",
        Hidden = scope:Computed(function(use)
          return use(selected) == nil
        end),
        OnClick = function()
          ask({ kind = "depot", body = { action = "remove", id = selected:get() } })
          selected:set(nil)
        end,
      }),
    }
  end

  return scope:Page({
    Title = "Depots",
    Status = status,
    Children = children,
    Actions = actions,
  })
end

return app
