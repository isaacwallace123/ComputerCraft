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
local network = require("domain.hardware.network")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

--- One row per peripheral, with its group folded in.
---
--- Flattened rather than nested, because a table is what draws well on a
--- 51-column screen and a tree is what does not. The mod is a column, which
--- sorts and reads the same way a heading would and costs no rows.
--- One row per peripheral, from the whole survey rather than the side scan.
---
--- `network.survey` rather than `peripherals.list` is the difference between a
--- base with four drives on a cable reporting one and reporting four. See
--- `domain/hardware/network.lua` - the short version is that a wired modem
--- publishes a block only once somebody has right-clicked it, and until this
--- page could say so there was nothing anywhere to suggest that was the problem.
function app.rows(peripherals)
  local found = network.survey(peripherals)

  -- Where each thing was reached, kept aside because `kinds.byMod` regroups the
  -- list and only carries the fields it knows about.
  local reach = {}
  for _, entry in ipairs(found) do
    reach[entry.name] = entry
  end

  local rows = {}
  for _, group in ipairs(kinds.byMod(found)) do
    for _, item in ipairs(group.items) do
      local entry = reach[item.name] or {}
      rows[#rows + 1] = {
        name = item.name,
        mod = group.vanilla and "cc" or group.mod,
        kind = item.kind,
        label = item.label,
        vanilla = group.vanilla,
        via = entry.via,
        remote = entry.remote == true,
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

  -- Counted separately because "6 attached" on a base with a cable answers the
  -- wrong question. What somebody wiring a network wants to know is whether the
  -- cable is carrying anything, and that is this number.
  local remote = network.reach(rows)
  local head = ("%d attached"):format(#rows)
  if remote > 0 then
    head = ("%d attached, %d on the network"):format(#rows, remote)
  end

  if count == 0 then
    return head, T.foreground
  end
  return ("%s, %d mod%s"):format(head, count, count == 1 and "" or "s"), T.good
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
    use(tick)
    local name = use(selected)
    if name == nil or peripherals == nil then
      return "select something to see what it can do"
    end

    -- A modem is asked what it reaches rather than what methods it has. Its
    -- method list is the same eight names on every machine and tells nobody
    -- anything; what it is connected to is the entire question, and it is the
    -- one CC's flat name list cannot answer.
    for _, row in ipairs(use(rows)) do
      if row.name == name then
        if row.kind == "radio" then
          return network.explain(peripherals, name)
        end
        if row.via then
          local names = peripherals.methods(name)
          return ("through %s - %s"):format(row.via, table.concat(names or {}, " "))
        end
        break
      end
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
