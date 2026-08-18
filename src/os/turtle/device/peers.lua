--- What the rest of the fleet is doing, from the turtle's point of view.
---
--- Every miner already broadcasts its world position twice a second-ish as part
--- of the normal status heartbeat. Until now only the base station listened. This
--- keeps the same packets on every turtle so a miner can tell "there is a turtle
--- in that block" apart from "there is a block I must not break", and can decide
--- who gives way without any negotiation round trip.
---
--- Nothing here is required for safety. A turtle with no peers in its table
--- behaves exactly as it did before: it still refuses to dig another turtle, it
--- just has to discover it by bumping into it.

local peers = {}

--- A snapshot older than this tells you nothing useful about where a moving
--- turtle is now, so it stops counting as an obstacle.
peers.TTL = 8

local known = {}

local function fresh(record)
  return record and (os.epoch("utc") - record.at) / 1000 <= peers.TTL
end

--- Fold a status broadcast into the table. Snapshots without world coordinates
--- are kept but cannot be used for avoidance - a turtle that never ran `where`
--- has nothing to compare against.
function peers.note(id, snapshot)
  if type(snapshot) ~= "table" or snapshot.role ~= "miner" then
    return
  end
  if id == os.getComputerID() then
    return
  end

  local world = snapshot.world
  known[id] = {
    id = id,
    at = os.epoch("utc"),
    label = snapshot.label,
    parked = snapshot.parked == true,
    sector = snapshot.sector,
    x = type(world) == "table" and world.x or nil,
    y = type(world) == "table" and world.y or nil,
    z = type(world) == "table" and world.z or nil,
  }
end

function peers.forget(id)
  known[id] = nil
end

--- Live peers, newest information only.
function peers.all()
  local list = {}
  for id, record in pairs(known) do
    if fresh(record) then
      list[#list + 1] = record
    else
      known[id] = nil
    end
  end
  return list
end

function peers.count()
  return #peers.all()
end

--- Which peer, if any, was last seen inside this world block.
---
--- Deliberately exact rather than a radius: a turtle one block away is normal
--- traffic, and treating it as an obstacle would deadlock a fleet working
--- adjacent ribs. Only the block we are about to enter matters.
function peers.at(worldX, worldY, worldZ)
  if not worldX then
    return nil
  end
  for _, record in ipairs(peers.all()) do
    if record.x == worldX and record.y == worldY and record.z == worldZ then
      return record
    end
  end
  return nil
end

--- Right of way. Lowest computer ID wins, which needs no shared clock, no
--- messages, and no tie to break - both turtles reach the same answer from
--- numbers they already have.
function peers.yieldsTo(id)
  return type(id) == "number" and os.getComputerID() > id
end

return peers
