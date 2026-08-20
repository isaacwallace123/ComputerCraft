--- Hardware that arrives while the machine is already running.
---
--- Every machine discovered its peripherals once, at boot, and never looked
--- again. Plug a modem into a running server and it had no radio until somebody
--- rebooted it - and a server with a modem in its side and no radio looks
--- exactly like a server whose turtles have wandered out of range. The fix,
--- reboot it, is not something anyone would think to try, because from the
--- outside nothing had changed.

local expect = require("support.expect")
local it = require("support.spec").it

local hotplug = require("os.kernel.services.hotplug")

--- A machine with a peripheral list that can change under it.
local function machine(attached)
  local self = { opened = 0, logged = {} }

  self.context = {
    peripherals = {
      list = function()
        local out = {}
        for name, types in pairs(attached) do
          local set, primary = {}, nil
          for _, kind in ipairs(types) do
            set[kind] = true
            primary = primary or kind
          end
          out[#out + 1] = { name = name, types = set, primary = primary }
        end
        return out
      end,
    },
    transport = {
      open = function()
        self.opened = self.opened + 1
        return true
      end,
    },
    log = {
      info = function(line)
        self.logged[#self.logged + 1] = line
      end,
    },
  }

  self.attach = function(name, types)
    attached[name] = types
  end

  return self
end

it("a modem plugged into a running machine opens the radio", function()
  -- The one thing that can honestly be switched on from here, and the one that
  -- matters: a machine that gains a radio starts using it within a tick.
  local base = machine({})
  base.attach("back", { "modem" })

  local said = hotplug.changed(base.context, hotplug.ATTACH, "back")
  expect.equal(base.opened, 1, "the radio was opened without a reboot")
  expect.contains(said, "modem")
  expect.contains(said, "back", "and says which side, because a base has six")
end)

it("a monitor is reported rather than half-mounted", function()
  -- The wall's size decides the layout and its input port is bound to its name,
  -- both fixed at boot. Standing one up here would be a second boot wearing a
  -- smaller word, so it says the one action that will use it instead.
  local base = machine({})
  base.attach("left", { "monitor" })

  local said = hotplug.changed(base.context, hotplug.ATTACH, "left")
  expect.contains(said, "monitor")
  expect.contains(said, "reboot", "the action, not just the observation")
  expect.equal(base.opened, 0, "and it did not touch the radio")
end)

it("anything else is named, including things nothing here understands", function()
  local base = machine({})
  base.attach("right", { "advancedperipherals:me_bridge" })

  local said = hotplug.changed(base.context, hotplug.ATTACH, "right")
  expect.contains(said, "right")
  expect.contains(said, "me_bridge", "named rather than called unknown")
end)

it("hardware coming off is reported and nothing is undone", function()
  -- `transport` checks `rednet.isOpen` before every send and answers false
  -- rather than raising, so a machine whose modem has been taken off the wall
  -- degrades on its own - which is what a turtle out of range needs anyway.
  local base = machine({})
  local said = hotplug.changed(base.context, hotplug.DETACH, "back")
  expect.contains(said, "removed")
  expect.contains(said, "back")
  expect.equal(base.opened, 0)
end)

it("a peripheral pulled off between the event and the look is not an error", function()
  -- CC fires the event and the block can be gone by the time anything asks
  -- about it. Ordinary, and it must not take the service down.
  local base = machine({})
  local said = hotplug.changed(base.context, hotplug.ATTACH, "top")
  expect.truthy(said ~= nil, "it still says something")
  expect.contains(said, "unknown", "honestly")
end)

it("events that are not about hardware are ignored", function()
  local base = machine({})
  expect.equal(hotplug.changed(base.context, "mouse_click", "back"), nil)
  expect.equal(hotplug.changed(base.context, hotplug.ATTACH, nil), nil, "and a nameless attach")
end)

it("a machine with no peripheral access still survives an attach", function()
  -- A turtle in a hole, and every spec's default.
  local said = hotplug.changed({}, hotplug.ATTACH, "back")
  expect.truthy(said ~= nil)
end)
