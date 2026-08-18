--- Always-on fleet networking for base stations and Pocket controllers.
---
--- No UI owns Rednet receive. The stationary base is the sole authority for
--- sector leases and automation; a controller only mirrors status and sends
--- requests. Closing Fleet or Devices therefore cannot stop coordination.

local log = require("adapters.cc.logfile")
local net = require("legacy.net")
local config = require("adapters.cc.config")
local util = require("lib.util")
local version = require("lib.version")
local coordinator = require("legacy.fleet.coordinator")
local operations = require("legacy.fleet.operations")
local policyStore = require("legacy.fleet.policy")
local rosterStore = require("legacy.fleet.roster")

local service = {}

local function updateRoster(devices, sender, snapshot, announce)
  local previous = devices[tostring(sender)]
  rosterStore.update(devices, sender, snapshot)

  local oldPhase = previous and previous.snap and previous.snap.phase
  if announce then
    log.info((snapshot.label or tostring(sender)) .. " joined")
  elseif snapshot.phase ~= oldPhase then
    local line = ("%s: %s"):format(snapshot.label or tostring(sender), snapshot.phase or "unknown")
    if snapshot.phase == "stuck" then
      log.error(line .. " - " .. tostring(snapshot.detail))
    else
      log.info(line)
    end
  end
  rosterStore.save(devices)
end

local function updateResult(devices, sender, body)
  local key = tostring(sender)
  local node = devices[key] or {}
  if type(body.snapshot) == "table" then
    node.snap = body.snapshot
  end
  node.lastSeen = os.epoch("utc")
  node.pairedAt = node.pairedAt or node.lastSeen
  devices[key] = node
  rosterStore.save(devices)

  local label = (node.snap and node.snap.label) or key
  local message = ("%s %s: %s"):format(
    label,
    body.action or "command",
    body.message or "acknowledged"
  )
  if body.ok == false then
    log.warn(message)
  else
    log.info(message)
  end
end

local function sendSync(id, devices, fleetPolicy)
  local deviceIds = {}
  local nodesById = {}
  for deviceId, node in pairs(devices) do
    local key = tostring(deviceId)
    deviceIds[#deviceIds + 1] = key
    nodesById[key] = node
  end
  -- Numeric order, so the handheld receives #10 after #9 rather than after #1.
  table.sort(deviceIds, util.naturalLess)

  local sent = net.send(id, "fleet_sync", {
    deviceIds = deviceIds,
    policy = fleetPolicy,
    logs = log.readRecent(40),
    baseId = os.getComputerID(),
    version = version,
  })
  for _, deviceId in ipairs(deviceIds) do
    sent = net.send(id, "fleet_node", { id = deviceId, node = nodesById[deviceId] }) and sent
  end
  return sent
end

local function eligibleForFuelResume(snapshot)
  if not snapshot or not snapshot.parked or snapshot.parkKind ~= "fuel" then
    return false
  end
  if snapshot.fuel == -1 then
    return true
  end
  return tonumber(snapshot.fuel) ~= nil
    and tonumber(snapshot.fuelRequired) ~= nil
    and snapshot.fuel >= snapshot.fuelRequired
end

function service.runBase()
  local warnedOffline = false
  local hosted, hostError = net.hostAsBase()
  while not hosted do
    if not warnedOffline then
      log.error(
        "fleet service offline - " .. tostring(hostError or "could not host base") .. "; retrying"
      )
      warnedOffline = true
    end
    sleep(5)
    hosted, hostError = net.hostAsBase()
  end

  log.info("fleet service online, hosting '" .. net.HOSTNAME .. "'")
  if not net.isWireless() then
    log.warn("wired modem - turtles will not reach this wirelessly")
  end

  local devices = rosterStore.load()
  local subscribers = {}
  local attempts = {}
  local health = {}
  local lastRefresh = 0
  local lastSync = 0
  local lastUpdate = 0
  local reconnectWarned = false

  local function automate(fleetPolicy)
    if not fleetPolicy.enabled then
      return
    end
    local now = os.epoch("utc")
    for _, node in ipairs(rosterStore.sorted(devices)) do
      local snap = node.snap or {}
      local id = tonumber(node.id)
      local retryAt = attempts[tostring(node.id)] or 0
      if id and rosterStore.online(node) and now >= retryAt then
        if fleetPolicy.resumeRefueled and eligibleForFuelResume(snap) then
          if net.send(id, "command", { action = "deploy" }) then
            attempts[tostring(node.id)] = now + 30000
            log.info((snap.label or tostring(id)) .. ": fuel restored; deploy queued")
          end
        elseif
          fleetPolicy.retryDepot
          and snap.parked
          and snap.parkKind == "error"
          and tostring(snap.detail or ""):find("depot full", 1, true)
        then
          if net.send(id, "command", { action = "deploy" }) then
            attempts[tostring(node.id)] = now + 60000
            log.info((snap.label or tostring(id)) .. ": retrying depot unload")
          end
        elseif fleetPolicy.retrySetup and snap.parked and snap.parkKind == "setup" then
          if net.send(id, "command", { action = "deploy" }) then
            attempts[tostring(node.id)] = now + 60000
            log.info((snap.label or tostring(id)) .. ": rechecking setup prerequisites")
          end
        elseif
          fleetPolicy.updateParked
          and snap.parked
          and snap.parkKind ~= "updating"
          and snap.parkKind ~= "error"
          and snap.version
          and snap.version ~= version
          and now - lastUpdate >= 60000
        then
          if net.send(id, "command", { action = "update" }) then
            attempts[tostring(node.id)] = now + 300000
            lastUpdate = now
            log.info((snap.label or tostring(id)) .. ": rolling update queued")
            return
          end
        end
      end
    end
  end

  local function observeHealth()
    for _, node in ipairs(rosterStore.sorted(devices)) do
      local age = rosterStore.age(node)
      local current = age > rosterStore.OFFLINE_AFTER and "offline"
        or (age > rosterStore.LATE_AFTER and "late" or "online")
      local key = tostring(node.id)
      local previous = health[key]
      if previous and previous ~= current then
        local label = (node.snap and node.snap.label) or key
        if current == "offline" then
          log.error(label .. ": heartbeat lost")
        elseif current == "late" then
          log.warn(label .. ": heartbeat late")
        elseif previous ~= "online" then
          log.info(label .. ": heartbeat restored")
        end
      end
      health[key] = current
    end
  end

  while true do
    if not net.isOpen() then
      hosted = false
    end
    if not hosted then
      hosted, hostError = net.hostAsBase()
      if hosted then
        reconnectWarned = false
        log.info("fleet service modem restored")
      elseif not reconnectWarned then
        reconnectWarned = true
        log.error("fleet service disconnected - " .. tostring(hostError or "retrying"))
      end
    end
    local sender, kind, body = net.receive(1)
    -- Views may make an intentional local roster edit (notably Forget). Reload
    -- before applying network input so this service never resurrects that row
    -- from an older in-memory copy.
    devices = rosterStore.load()
    local fleetPolicy = policyStore.load()

    if sender and kind == "hello" and type(body) == "table" then
      updateRoster(devices, sender, body, true)
    elseif sender and kind == "status" and type(body) == "table" then
      updateRoster(devices, sender, body, false)
      coordinator.renewMine(sender, body)
    elseif sender and kind == "mine" and type(body) == "table" then
      local ok, err = pcall(coordinator.mine, sender, body)
      if not ok then
        log.error("fleet: mine request failed - " .. tostring(err))
      end
    elseif sender and kind == "command_result" and type(body) == "table" then
      updateResult(devices, sender, body)
    elseif sender and kind == "controller" and type(body) == "table" then
      subscribers[sender] = os.epoch("utc")
      if body.action == "forget" and body.target ~= nil then
        devices[tostring(body.target)] = nil
        rosterStore.save(devices)
        log.warn("fleet: controller forgot #" .. tostring(body.target))
      elseif body.action == "set_policy" and type(body.fields) == "table" then
        fleetPolicy = policyStore.update(body.fields)
        log.info("fleet: automation policy changed by controller #" .. tostring(sender))
      elseif body.action == "operation" and type(body.operation) == "string" then
        local called, ok, message, data = pcall(operations.perform, body.operation, body.fields)
        if not called then
          ok, message, data = false, tostring(ok), nil
        end
        net.send(sender, "controller_result", {
          requestId = body.requestId,
          ok = ok,
          message = message,
          data = data,
        })
      end
      sendSync(sender, devices, fleetPolicy)
    end

    local now = os.epoch("utc")
    if now - lastRefresh >= fleetPolicy.refreshSeconds * 1000 then
      net.broadcast("command", { action = "status_request" })
      lastRefresh = now
    end
    if now - lastSync >= fleetPolicy.syncSeconds * 1000 then
      for id, seenAt in pairs(subscribers) do
        if now - seenAt > 60000 then
          subscribers[id] = nil
        else
          sendSync(id, devices, fleetPolicy)
        end
      end
      lastSync = now
    end
    automate(fleetPolicy)
    observeHealth()
  end
end

function service.runController()
  if not net.open() then
    log.error("controller offline - no modem attached")
  end

  local devices = rosterStore.load()
  local lastSubscribe = 0

  while true do
    local sender, kind, body = net.receive(1)
    if sender and (kind == "hello" or kind == "status") and type(body) == "table" then
      updateRoster(devices, sender, body, kind == "hello")
    elseif sender and kind == "command_result" and type(body) == "table" then
      updateResult(devices, sender, body)
    elseif sender and kind == "fleet_sync" and type(body) == "table" then
      -- `roster` supports the first controller build. Current bases send one
      -- node per message so a large fleet cannot exceed the modem payload limit.
      if type(body.roster) == "table" then
        devices = body.roster
        rosterStore.save(devices)
      elseif type(body.deviceIds) == "table" then
        local present = {}
        for _, id in ipairs(body.deviceIds) do
          present[tostring(id)] = true
        end
        for id in pairs(devices) do
          if not present[tostring(id)] then
            devices[id] = nil
          end
        end
        rosterStore.save(devices)
      end
      if type(body.policy) == "table" then
        policyStore.save(body.policy)
      end
      if type(body.logs) == "table" then
        config.save(".fleet-log", body.logs)
      end
    elseif
      sender
      and kind == "fleet_node"
      and type(body) == "table"
      and type(body.node) == "table"
    then
      devices[tostring(body.id)] = body.node
      rosterStore.save(devices)
    elseif sender and kind == "controller_result" and type(body) == "table" and body.requestId then
      local responses = config.load(".fleet-responses", {})
      local now = os.epoch("utc")
      for requestId, response in pairs(responses) do
        if type(response) ~= "table" or now - (response.receivedAt or 0) > 60000 then
          responses[requestId] = nil
        end
      end
      body.receivedAt = now
      responses[tostring(body.requestId)] = body
      config.save(".fleet-responses", responses)
    end

    local now = os.epoch("utc")
    if now - lastSubscribe >= 10000 then
      local base = net.findBase()
      if base then
        net.send(base, "controller", { action = "subscribe" })
      end
      lastSubscribe = now
    end
  end
end

return service
