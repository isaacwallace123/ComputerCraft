--- Seeing past the sides of the computer.
---
--- The failure this is built from: a base with four disk drives on a wired
--- network listed one - the drive touching the computer - and said "2 attached"
--- with complete confidence. Nothing was broken. The modems on the other three
--- had never been right-clicked, so they published nothing, and an unpublished
--- block and an absent block look identical from inside a computer.

local expect = require("support.expect")
local it = require("support.spec").it

local network = require("domain.hardware.network")

--- A machine with peripherals on its sides and, optionally, on a cable.
---
--- `remote` maps a modem name to the peripherals it publishes. Anything not
--- listed answers the way CC does for a method a peripheral does not have:
--- `false` and a reason, never a raise.
local function machine(sides, remote)
  local self = { calls = 0 }

  self.port = {
    list = function()
      local out = {}
      for _, entry in ipairs(sides) do
        local types = {}
        for _, kind in ipairs(entry.types) do
          types[kind] = true
        end
        out[#out + 1] = { name = entry.name, types = types, primary = entry.types[1] }
      end
      return out
    end,

    call = function(name, method, argument)
      self.calls = self.calls + 1
      local network_ = (remote or {})[name]

      if method == "isWireless" then
        for _, entry in ipairs(sides) do
          if entry.name == name then
            return true, entry.wireless == true
          end
        end
        return false, "no such peripheral"
      end

      if method == "getNamesRemote" then
        if network_ == nil then
          return false, "No such method"
        end
        local names = {}
        for published in pairs(network_) do
          names[#names + 1] = published
        end
        return true, names
      end

      if method == "getTypeRemote" then
        local kinds = network_ and network_[argument]
        if kinds == nil then
          return false, "not on this network"
        end
        return true, table.unpack(kinds)
      end

      return false, "No such method"
    end,

    methods = function()
      return { "getNamesRemote", "isWireless" }
    end,
  }

  return self
end

it("peripherals on a cable are listed beside the ones on the sides", function()
  local base = machine({
    { name = "front", types = { "modem" } },
    { name = "right", types = { "drive" } },
  }, {
    front = {
      drive_0 = { "drive" },
      drive_1 = { "drive" },
      minecraft_chest_2 = { "minecraft:chest", "inventory" },
    },
  })

  local found = network.survey(base.port)
  expect.equal(#found, 5, "two on the sides and three on the cable")

  local names = {}
  for _, entry in ipairs(found) do
    names[entry.name] = entry
  end

  expect.truthy(names.drive_0, "the drive the side scan could never see")
  expect.truthy(names.drive_0.remote, "marked as reached over the cable")
  expect.equal(names.drive_0.via, "front", "and through which modem")
  expect.truthy(names.minecraft_chest_2.types["minecraft:chest"], "with its real types")
  expect.truthy(names.minecraft_chest_2.types.inventory, "all of them, not just the first")

  expect.falsy(names.right.remote, "the drive on the side is not a network one")
  expect.equal(network.reach(found), 3, "three of the five are on the cable")
end)

it("a wired modem reaching nothing says the thing nobody would guess", function()
  -- This is the whole point of the module. The cable is laid, the drives are
  -- placed, the computer lists none of them, and the fix is a right-click that
  -- nothing anywhere prompts you to make.
  local base = machine({ { name = "front", types = { "modem" } } }, { front = {} })

  local said = network.explain(base.port, "front")
  expect.contains(said, "wired")
  expect.contains(said, "right-click", "the action, not just the diagnosis")
  expect.equal(#network.survey(base.port), 1, "and nothing was invented to fill the list")
end)

it("a wireless modem is not given cable advice", function()
  local base = machine({ { name = "back", types = { "modem" }, wireless = true } })

  local said = network.explain(base.port, "back")
  expect.contains(said, "wireless")
  expect.falsy(said:find("right%-click"), "there is no cable to click anything on")
end)

it("a wired modem says what it reaches, by name", function()
  -- CC's flat list gives `drive_0` with no indication of where it is. The
  -- connection is the question being asked and nothing else answers it.
  local base = machine({ { name = "front", types = { "modem" } } }, {
    front = { drive_0 = { "drive" }, monitor_1 = { "monitor" } },
  })

  local said = network.explain(base.port, "front")
  expect.contains(said, "drive_0")
  expect.contains(said, "monitor_1")
  expect.contains(said, "2", "and how many")
end)

it("a modem that will not say what it is gets no advice at all", function()
  -- A modem erroring on `isWireless` has an unknown kind, and guessing "wired"
  -- would hand somebody instructions about a cable that may not exist.
  local base = { port = nil }
  base.port = {
    list = function()
      return { { name = "top", types = { modem = true }, primary = "modem" } }
    end,
    call = function()
      return false, "exploded"
    end,
    methods = function()
      return {}
    end,
  }

  local said = network.explain(base.port, "top")
  expect.contains(said, "will not say")
  expect.equal(#network.survey(base.port), 1, "and the survey carries on regardless")
end)

it("a peripheral on a side and on the network is listed once", function()
  -- A drive touching the computer that also has its own modem is published
  -- twice by CC. Listing it twice would make the count wrong in the direction
  -- that looks like the bug this module fixes.
  local base = machine({
    { name = "front", types = { "modem" } },
    { name = "drive_0", types = { "drive" } },
  }, { front = { drive_0 = { "drive" } } })

  local found = network.survey(base.port)
  expect.equal(#found, 2, "not three")

  for _, entry in ipairs(found) do
    if entry.name == "drive_0" then
      expect.equal(entry.via, "front", "but it does record that the cable reaches it")
      expect.falsy(entry.remote, "and keeps the types the side scan reported")
    end
  end
end)

it("a machine with no peripheral access surveys to nothing rather than erroring", function()
  expect.equal(#network.survey(nil), 0)
  expect.equal(network.reach(nil), 0)
end)
