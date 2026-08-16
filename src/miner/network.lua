--- Miner heartbeat and remote command receiver.

local log = require("core.log")
local net = require("core.net")
local peers = require("turtle.peers")
local site = require("mine.site")

local network = {}

local HEARTBEAT_SECONDS = 2
local GPS_REFRESH_SECONDS = 30
local BASE_RECHECK_SECONDS = 60

function network.heartbeat(ctx)
  local lastGps = 0
  local lastLookup = 0

  while true do
    if os.clock() - lastGps > GPS_REFRESH_SECONDS then
      lastGps = os.clock()
      ctx.worldPos = require("turtle.nav").worldPosition() or ctx.worldPos
    end

    if not ctx.baseId or os.clock() - lastLookup > BASE_RECHECK_SECONDS then
      lastLookup = os.clock()
      local found = net.findBase()
      if found and found ~= ctx.baseId then
        log.info("base station is " .. found)
        net.broadcast("hello", ctx:snapshot())
      end
      ctx.baseId = found or ctx.baseId
    end

    net.broadcast("status", ctx:snapshot())
    ctx:draw()
    sleep(HEARTBEAT_SECONDS)
  end
end

function network.commands(ctx)
  while true do
    local sender, kind, body = net.receive(1)
    if kind == "status" and type(body) == "table" then
      -- Another miner's heartbeat. Only the base used to care about these; now
      -- every turtle keeps them so it can tell a colleague apart from a wall.
      peers.note(sender, body)
    elseif kind == "mine_result" and type(body) == "table" then
      site.deliver(body)
    elseif kind == "command" and type(body) == "table" then
      if body.action == "recall" then
        if ctx.node.parked then
          ctx:reply(sender, body.action, true, "already parked")
        else
          log.warn("recalled by base")
          ctx.control.recall = true
          ctx:reply(sender, body.action, true, "recall accepted")
        end
      elseif body.action == "deploy" then
        if ctx.node.parked then
          log.info("deploy order from base")
          ctx.control.deploy = true
          ctx.control.deployFrom = sender
        else
          ctx:reply(sender, body.action, false, "already running")
        end
      elseif body.action == "set_job" then
        if ctx.node.parked then
          ctx.control.setJob = { name = body.job, sender = sender }
        else
          ctx:reply(sender, body.action, false, "recall this turtle first")
        end
      elseif body.action == "assign_job" then
        if ctx.node.parked then
          ctx.control.assignment = {
            name = body.job,
            settings = body.settings,
            sender = sender,
          }
        else
          ctx:reply(sender, body.action, false, "recall this turtle first")
        end
      elseif body.action == "configure" then
        if ctx.node.parked then
          ctx.control.settings = { values = body.settings, sender = sender }
        else
          ctx:reply(sender, body.action, false, "recall this turtle first")
        end
      elseif body.action == "status_request" then
        net.send(sender, "status", ctx:snapshot())
      elseif body.action == "update" then
        if not http or not fs.exists(".update") then
          ctx:reply(sender, body.action, false, "OTA update is not configured")
        elseif ctx.control.update then
          ctx:reply(sender, body.action, true, "update already queued")
        else
          ctx.control.update = { sender = sender }
          if ctx.node.parked then
            ctx:reply(sender, body.action, true, "update starting")
          else
            ctx.control.recall = true
            log.warn("update requested - returning home first")
            ctx:reply(sender, body.action, true, "update queued; returning home first")
          end
        end
      elseif body.action == "rename" and type(body.label) == "string" then
        local label = body.label:sub(1, 32)
        os.setComputerLabel(label)
        ctx.node.label = label
        ctx:saveNode()
        ctx:reply(sender, body.action, true, "renamed to " .. label)
      end
    end
  end
end

return network
