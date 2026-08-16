--- Commands shared by the stationary base UI and remote Pocket controllers.

local config = require("core.config")
local net = require("core.net")
local policy = require("fleet.policy")
local rosterStore = require("fleet.roster")

local control = {}

local function isController()
  return config.load(".node", {}).role == "controller"
end

local function baseRequest(action, fields)
  local base = net.findBase()
  if not base then
    return false, "base station is offline"
  end
  local body = fields or {}
  body.action = action
  if not net.send(base, "controller", body) then
    return false, "could not reach base station"
  end
  return true
end

function control.forget(id)
  local saved = rosterStore.load()
  saved[tostring(id)] = nil
  rosterStore.save(saved)

  if isController() then
    return baseRequest("forget", { target = tonumber(id) or id })
  end
  os.queueEvent("icos_forget_device", id)
  return true
end

function control.setPolicy(fields)
  local saved = policy.update(fields)
  if isController() then
    local ok, err = baseRequest("set_policy", { fields = fields })
    if not ok then
      return false, err, saved
    end
  end
  return true, nil, saved
end

function control.requestSync()
  if not isController() then
    return true
  end
  return baseRequest("subscribe")
end

function control.operation(action, fields)
  if not isController() then
    return require("fleet.operations").perform(action, fields)
  end

  local requestId = ("%d:%d"):format(os.getComputerID(), os.epoch("utc"))
  local ok, err = baseRequest("operation", {
    requestId = requestId,
    operation = action,
    fields = fields,
  })
  if not ok then
    return false, err
  end

  local path = ".fleet-responses"
  local deadline = os.epoch("utc") + 5000
  while os.epoch("utc") < deadline do
    local responses = config.load(path, {})
    local response = responses[requestId]
    if type(response) == "table" then
      responses[requestId] = nil
      config.save(path, responses)
      return response.ok ~= false, response.message, response.data
    end
    sleep(0.1)
  end
  return false, "base did not answer in time"
end

return control
