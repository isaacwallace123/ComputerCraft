--- Mining turtle entrypoint. Runtime concerns live under miner/.

package.path = "/?.lua;/?/init.lua;" .. package.path

if not turtle then
  printError("This is a turtle program.")
  return
end

local Context = require("legacy.miner.context")
local log = require("adapters.cc.logfile")
local net = require("legacy.net")
local network = require("legacy.miner.network")
local runtime = require("legacy.miner.runtime")
local ui = require("legacy.shell.ui")
local version = require("lib.version")

local jobs = {
  quarry = require("jobs.mining.quarry"),
  rare = require("jobs.mining.rare"),
  fuel = require("jobs.mining.fuel_hunt"),
  hollow = require("jobs.mining.hollow"),
  resources = require("jobs.mining.resources"),
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
