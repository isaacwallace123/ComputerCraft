--- The constellation: who knows where they are, and who is telling anybody.
---
--- GPS in ICOS 2 is not a machine, it is a property every machine can have - so
--- there is no "the GPS host" to look at, and until this page there was no way
--- to see the constellation at all. What you could see was one turtle saying "no
--- position", which is the symptom of a fleet-wide fact rendered on the one
--- machine least able to explain it.
---
--- ## The number that matters is four
---
--- Trilateration needs four hosts. Three is not "nearly working", it is exactly
--- as useless as zero, and the difference between those two states is invisible
--- from any individual machine. So the count is the headline and everything else
--- on the page explains it.
---
--- ## Hosting is not the same as being located
---
--- A machine can know where it is and still not host - a Pocket Computer never
--- does, a turtle only while parked, anything without a wireless modem cannot.
--- Two columns rather than one, because "located but silent" is the state
--- somebody needs to see to understand why four machines with positions are
--- still not a constellation.

local host = require("domain.gps.host")
local registry = require("domain.fleet.registry")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

app.manifest = {
  id = "gps",
  name = "GPS",

  -- Not a turtle. A turtle showing the constellation is showing something it
  -- cannot act on, and its screen has four rows to spare.
  roles = { "client", "server", "mobile" },
  surfaces = { "desktop", "monitor", "handheld" },
  requiresInput = false,
}

--- Whether a device is currently able to answer a GPS ping.
---
--- The same rule `domain/gps/host.lua` applies on the machine itself, evaluated
--- here from what the heartbeat carries. Two places reading one rule rather than
--- two rules that agree today - a page that decided this independently would
--- start disagreeing with the machines the first time either changed.
function app.hosting(snapshot)
  snapshot = snapshot or {}

  if not snapshot.located then
    return false, "no position"
  end

  -- A pocket computer travels in an inventory at ten blocks a second with no way
  -- to observe any of it. It is the one machine whose answer is never.
  if snapshot.role == "controller" or snapshot.kind == "pocket" then
    return false, "handheld"
  end

  if snapshot.parked == false then
    return false, "moving"
  end

  return true
end

--- One row per device, plus what it contributes.
function app.rows(state, now)
  local rows = {}

  for _, record in ipairs(registry.records(state.fleet)) do
    local snapshot = record.snap or {}
    local serving, why = app.hosting(snapshot)
    local world = snapshot.world

    rows[#rows + 1] = {
      id = record.id,
      label = snapshot.label or ("device-" .. tostring(record.id)),
      at = world and ("%d, %d, %d"):format(world.x, world.y, world.z) or "unknown",
      hosting = serving and "hosting" or (why or "no"),
      serving = serving,
      located = snapshot.located == true,
      health = registry.health(record, now),
    }
  end

  -- Hosts first, because the question this page answers is "how many are
  -- hosting" and the answer should be readable without counting the whole list.
  table.sort(rows, function(a, b)
    if a.serving ~= b.serving then
      return a.serving
    end
    return tostring(a.label) < tostring(b.label)
  end)

  return rows
end

--- How many machines are actually answering.
function app.quorum(rows)
  local serving = 0
  for _, row in ipairs(rows) do
    if row.serving then
      serving = serving + 1
    end
  end
  return serving
end

--- The headline, and the colour it is in.
---
--- Says what to do rather than what is true when the answer is "not enough",
--- because "2 of 4" tells somebody the state and not the remedy - and the remedy
--- here is unusual enough to be worth spelling out: any machine will do, and
--- `commands/locate` is what makes one count.
function app.summary(rows)
  local serving = app.quorum(rows)

  if serving >= host.QUORUM then
    return ("%d hosts - the constellation works"):format(serving), T.good
  end

  local short = host.QUORUM - serving
  return ("%d of %d hosts - locate %d more"):format(serving, host.QUORUM, short), T.warn
end

function app.columns()
  return {
    { Title = "Device", Grow = 1, Key = "label" },
    {
      Title = "Position",
      Width = 16,
      Key = "at",
      Tone = function(row)
        return row.located and T.foreground or T.mutedFg
      end,
    },
    {
      Title = "GPS",
      Width = 10,
      Key = "hosting",
      Tone = function(row)
        return row.serving and T.good or T.mutedFg
      end,
    },
  }
end

function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)

  local rows = scope:Computed(function(use)
    use(tick)
    if context.state == nil then
      return {}
    end
    return app.rows(context.state, context.clock.now())
  end)

  local status = scope:Computed(function(use)
    return (app.summary(use(rows)))
  end)

  local selected = options.selected or scope:Value(nil)

  return scope:Page({
    Title = "GPS",
    Status = status,
    Children = {
      scope:Table({
        Columns = app.columns(),
        Rows = rows,
        Selected = selected,
        Capacity = options.capacity or 8,
        OnSelect = function(row)
          selected:set(row and row.id or nil)
        end,
      }),
      scope:Separator({}),
      scope:Muted({
        Height = 1,
        Text = scope:Computed(function(use)
          local serving = app.quorum(use(rows))
          if serving >= host.QUORUM then
            return "Any machine that boots now locates itself."
          end
          return "Every located, stationary machine counts. Run commands/locate."
        end),
      }),
    },
  })
end

return app
