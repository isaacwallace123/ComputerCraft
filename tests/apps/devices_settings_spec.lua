--- The settings panel shows the settings the selected turtle actually has.

local expect = require("support.expect")
local it = require("support.spec").it
local recorder = require("adapters.sim.screen")
local ui = require("ui.init")

local KEY = require("ui.input").KEY
local devicesView = require("apps.devices.view")

--- What the crop farm advertises, as a literal.
---
--- Not `require`d from the job. A job module pulls in `device/nav.lua`, which
--- reads `fs` at load time, so requiring one here would make a test about a
--- panel depend on there being a filesystem - and would fail for a reason that
--- has nothing to do with what is being checked.
local FARM_FIELDS = {
  { label = "Distance", key = "distance", step = 4, min = 1, max = 256 },
  { label = "Width", key = "width", step = 1, min = 1, max = 64 },
  { label = "Length", key = "length", step = 1, min = 1, max = 64 },
  { label = "Rest minutes", key = "restMinutes", step = 1, min = 0, max = 60 },
}

local ROWS = 19

--- Everything on screen, as one string.
local function whole(screen)
  local rows = {}
  for row = 1, ROWS do
    rows[row] = screen.rowText(row)
  end
  return table.concat(rows, "\n")
end

--- A panel showing one device, already open on the settings half.
local function panel(device)
  local screen = recorder.new(51, ROWS)
  local scope = ui.scoped()
  local state = { writes = {} }

  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return devicesView.build(s, {
        devices = s:Value({ device }),
        selected = s:Value(device.id),
        editing = s:Value(true),
        capacity = 3,
        onSelect = function() end,
        onSetting = function(target, key, value)
          state.writes[#state.writes + 1] = { id = target.id, key = key, value = value }
        end,
      })
    end,
  })
  root:render()
  return root, screen, state
end

--- What a farming turtle puts in its heartbeat.
local function farmer()
  return {
    id = 4,
    label = "farm-4",
    phase = "parked",
    job = "crops",
    fuel = 20000,
    fuelLimit = 100000,
    settings = { distance = 4, width = 9, length = 9, restMinutes = 5 },
    settingFields = FARM_FIELDS,
  }
end

it("a farming turtle is offered its own settings, not a miner's", function()
  -- The panel used to build its rows from `devices.FIELDS` - the mining
  -- defaults - because nothing ever passed `options.fields`. So a farming
  -- turtle showed `vein budget` and `scan every`: four steppers for settings it
  -- does not have, while its plot size was unreachable from the base. Every
  -- turtle has advertised `settingFields` in its heartbeat all along; the panel
  -- simply never looked.
  local root, screen = panel(farmer())
  local text = whole(screen)

  expect.contains(text, "Distance", "its own fields are on screen")
  expect.contains(text, "Rest minutes", "including the last one")
  expect.falsy(text:find("vein budget"), "and a miner's are not:\n" .. text)
  root:destroy()
end)

it("changing a farm setting reports the farm's own key", function()
  -- The write path matters as much as the display. A panel that showed the
  -- right labels and wrote `veinBudget` would be worse than one that showed the
  -- wrong labels, because the mistake would reach the turtle.
  local root, _, state = panel(farmer())

  -- Every focusable in turn, rather than assuming which index a stepper is:
  -- the panel's layout is not what this test is about, and an index would make
  -- it fail the next time somebody adds a button.
  for _, node in ipairs(root:focusRing()) do
    root:focus(node)
    root:handle("key", KEY.right, false)
  end

  expect.truthy(#state.writes > 0, "something was written")

  local allowed = { distance = true, width = true, length = true, restMinutes = true }
  for _, write in ipairs(state.writes) do
    expect.truthy(allowed[write.key], "every write is a farm setting, got " .. tostring(write.key))
  end
  root:destroy()
end)

it("a device that advertises nothing still gets a usable panel", function()
  -- An older build, or a job with no settings. Falling back to the mining
  -- defaults is what the panel did for everybody before; it is now the
  -- exception rather than the rule, and it must still not be an empty box.
  local device = farmer()
  device.settingFields = nil

  local root, screen = panel(device)
  expect.contains(whole(screen), "target Y", "it falls back to the defaults it always used")
  root:destroy()
end)
