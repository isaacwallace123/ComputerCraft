--- Hardware: what is plugged in, and which mods this machine can reach.
---
--- A fleet in a modpack is surrounded by blocks somebody else's mod put there,
--- and this is the page that says which of them are within reach. It needs no
--- registry, no version handshake and nothing installed: Minecraft namespaces
--- every registry name as `mod:thing`, CC passes that through as the peripheral
--- type, so **a machine that lists its peripherals already knows which mods it
--- can talk to.**
---
--- ## It says what it does not know
---
--- Most of what a modpack attaches is something this fleet has no opinion about,
--- and those are listed as `unknown` rather than guessed at. A page that
--- invented a purpose for an unrecognised block would be a page somebody trusted
--- once.
---
--- What that buys is a list of *candidates*: the blocks a future job could use,
--- named, grouped by the mod that provides them, on the machine they are
--- attached to. That is the whole first step of interacting with a mod, and it
--- is the step nothing here could take before.

local kinds = require("domain.hardware.kinds")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

--- One row per peripheral, with its group folded in.
---
--- Flattened rather than nested, because a table is what draws well on a
--- 51-column screen and a tree is what does not. The mod is a column, which
--- sorts and reads the same way a heading would and costs no rows.
function app.rows(peripherals)
  local rows = {}

  for _, group in ipairs(kinds.byMod(peripherals.list())) do
    for _, item in ipairs(group.items) do
      rows[#rows + 1] = {
        name = item.name,
        mod = group.vanilla and "cc" or group.mod,
        kind = item.kind,
        label = item.label,
        vanilla = group.vanilla,
      }
    end
  end

  return rows
end

--- The headline: how many things, from how many mods.
function app.summary(rows)
  local mods = {}
  local count = 0
  for _, row in ipairs(rows) do
    if not row.vanilla and not mods[row.mod] then
      mods[row.mod] = true
      count = count + 1
    end
  end

  if #rows == 0 then
    return "nothing attached", T.mutedFg
  end
  if count == 0 then
    return ("%d attached"):format(#rows), T.foreground
  end
  return ("%d attached, %d mod%s"):format(#rows, count, count == 1 and "" or "s"), T.good
end

function app.columns()
  return {
    { Title = "Peripheral", Grow = 1, Key = "name" },
    {
      Title = "Type",
      Width = 16,
      Key = "label",
      Tone = function(row)
        return row.vanilla and T.foreground or T.accent
      end,
    },
    {
      Title = "Use",
      Width = 8,
      Key = "kind",
      Tone = function(row)
        -- Muted for the ones nothing here knows what to do with, which is most
        -- of them and is not a fault - it is a list of candidates.
        return row.kind == "unknown" and T.mutedFg or T.good
      end,
    },
  }
end

function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)
  local peripherals = context.peripherals

  local rows = scope:Computed(function(use)
    use(tick)
    if peripherals == nil then
      return {}
    end
    return app.rows(peripherals)
  end)

  local status = scope:Computed(function(use)
    if peripherals == nil then
      return "no peripheral access on this machine"
    end
    return (app.summary(use(rows)))
  end)

  local selected = options.selected or scope:Value(nil)

  --- What the selected peripheral can actually do.
  ---
  --- The method list, which is the only honest answer for a block this fleet
  --- does not recognise - and the thing somebody wiring up a new job needs
  --- first. It is also why the page is worth having on a turtle.
  local detail = scope:Computed(function(use)
    local name = use(selected)
    if name == nil or peripherals == nil then
      return "select something to see what it can do"
    end
    local names = peripherals.methods(name)
    if names == nil or #names == 0 then
      return "no methods - it may have been removed"
    end
    return table.concat(names, " ")
  end)

  return scope:Page({
    Title = "Hardware",
    Status = status,
    Children = {
      scope:Table({
        Columns = app.columns(),
        Rows = rows,
        Selected = selected,
        Capacity = options.capacity or 7,
        OnSelect = function(row)
          selected:set(row and row.name or nil)
        end,
      }),
      scope:Separator({}),
      scope:Muted({ Text = detail, Height = 1 }),
    },
  })
end

return app
