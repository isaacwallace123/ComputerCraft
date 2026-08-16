--- Persistent paired-device roster shared by Fleet and Devices.

local config = require("core.config")
local util = require("core.util")

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

function roster.age(node)
  return util.since(node.lastSeen)
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
  table.sort(list, function(a, b)
    return tostring((a.snap and a.snap.label) or a.id) < tostring((b.snap and b.snap.label) or b.id)
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
