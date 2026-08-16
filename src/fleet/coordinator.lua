--- Fleet-wide atomic job assignment.

local net = require("core.net")
local rosterStore = require("fleet.roster")

local coordinator = {}

local function availableMiners()
  local devices = rosterStore.load()
  local miners = {}
  for _, node in ipairs(rosterStore.sorted(devices)) do
    local snap = node.snap or {}
    if rosterStore.online(node) and snap.role == "miner" and snap.parked then
      miners[#miners + 1] = node
    end
  end
  return miners
end

function coordinator.quarry(settings)
  local miners = availableMiners()
  if #miners == 0 then
    return false, "no connected parked miners are available"
  end

  local cells = (math.abs(settings.x2 - settings.x1) + 1)
    * (math.abs(settings.z2 - settings.z1) + 1)
  while #miners > cells do
    table.remove(miners)
  end

  local sent = 0
  for index, node in ipairs(miners) do
    local assignment = {
      minX = math.min(settings.x1, settings.x2),
      maxX = math.max(settings.x1, settings.x2),
      minZ = math.min(settings.z1, settings.z2),
      maxZ = math.max(settings.z1, settings.z2),
      topY = settings.topY,
      bottomY = settings.bottomY,
      workerIndex = index,
      workerCount = #miners,
    }
    if
      net.send(tonumber(node.id), "command", {
        action = "assign_job",
        job = "quarry",
        settings = assignment,
      })
    then
      sent = sent + 1
    end
  end

  if sent == 0 then
    return false, "assignments could not be sent - check the modem"
  end
  return true, ("assigned %d/%d parked miners"):format(sent, #miners)
end

return coordinator
