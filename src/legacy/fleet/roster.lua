--- Persistent paired-device roster shared by Fleet and Devices.

local config = require("adapters.cc.config")
local util = require("lib.util")

local roster = {}

roster.PATH = ".fleet"
roster.LATE_AFTER = 10
roster.OFFLINE_AFTER = 60

function roster.load()
  return config.load(roster.PATH, {})
end

function roster.save(devices)
  config.save(roster.PATH, devices)
end

--- Seconds since this device last reported.
---
--- `util.since` no longer defaults its second argument - a defaulted clock is
--- a second clock nobody declared, and that is the bug that put two turtles in
--- one shaft. ICOS 1 has no clock port, so the CC clock is named here, which is
--- the same arrangement `legacy/mine/registry.lua` makes for the mine.
function roster.age(node)
  return util.since(node.lastSeen, os.epoch("utc"))
end

function roster.online(node)
  return roster.age(node) <= roster.OFFLINE_AFTER
end

function roster.sorted(devices)
  local list = {}
  for id, node in pairs(devices) do
    node.id = tonumber(id) or id
    list[#list + 1] = node
  end
  -- Natural order, so miner-10 follows miner-9 instead of miner-1.
  table.sort(list, function(a, b)
    local left = (a.snap and a.snap.label) or a.id
    local right = (b.snap and b.snap.label) or b.id
    return util.naturalLess(left, right)
  end)
  return list
end

--- Insert a heartbeat while preserving the device's original pairing time.
function roster.update(devices, id, snapshot)
  local key = tostring(id)
  local previous = devices[key]
  local now = os.epoch("utc")
  devices[key] = {
    snap = snapshot,
    lastSeen = now,
    pairedAt = previous and previous.pairedAt or now,
  }
  return previous, devices[key]
end

return roster
