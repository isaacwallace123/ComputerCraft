--- Mining turtle entrypoint. Runtime concerns live under miner/.

package.path = "/?.lua;/?/init.lua;" .. package.path

if not turtle then
  printError("This is a turtle program.")
  return
end

local Context = require("miner.context")
local log = require("core.log")
local net = require("core.net")
local network = require("miner.network")
local runtime = require("miner.runtime")
local ui = require("core.ui")
local version = require("core.version")

local jobs = {
  quarry = require("jobs.quarry"),
  rare = require("jobs.rare"),
  fuel = require("jobs.fuel_hunt"),
  hollow = require("jobs.hollow"),
  resources = require("jobs.resources"),
}

local ctx = Context.new(jobs)

net.open()
log.info("miner agent starting v" .. version .. " (" .. ctx.node.job .. ")")

local completed, err = pcall(function()
  parallel.waitForAny(function()
    runtime.agent(ctx)
  end, function()
    network.heartbeat(ctx)
  end, function()
    network.commands(ctx)
  end, function()
    runtime.localControls(ctx)
  end)
end)

if not completed and not tostring(err):find("Terminated") then
  log.error(tostring(err))
  ui.clear()
  printError(tostring(err))
  print("\nProgress is saved - reboot to resume.")
else
  ui.clear()
  print("Miner agent stopped.")
end
