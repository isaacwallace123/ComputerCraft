--- ICOS boot entry point.
---
---   splash -> escape hatch -> automatic update -> the machine this computer is
---
--- ## What replaced what
---
--- The ICOS 1 version was two hundred lines that discovered a monitor, migrated
--- a role, drew a splash, ran an updater, loaded an app registry, and then
--- branched five ways on role and hardware to decide which program to run.
---
--- Four of those five branches were "which shell does this machine get", and
--- that question is now answered by `os/kernel/roles.lua` mapping a node record
--- onto one of four operating systems - so the branch is a table lookup in
--- `os/kernel/boot.lua` and does not appear here at all.
---
--- What is left is the part that is genuinely about *booting*: put something on
--- the screen, let somebody stop you, take the update, hand over.
---
--- ## The escape hatch comes before everything
---
--- Holding a key during the splash opens setup instead of the autorun, and that
--- ordering is the whole safety property: a bad deploy must never produce a
--- machine that boots straight into a broken program forever. It is checked
--- before the update runs, because the update is the most likely thing to have
--- broken the machine and the least useful thing to run again when it has.
---
--- ## An ICOS 1 node record still boots
---
--- `roles.roleOf` maps every ICOS 1 role onto one of the four operating systems,
--- so there is no fallback path and no flag. A machine set up as `miner` boots
--- the turtle OS; one set up as `fleet` boots a server with a client beside it.
--- The migration happens in the mapping, once, rather than as a branch here that
--- somebody would eventually have to delete - which matters because every device
--- in the world has one of those records on it right now.

package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("adapters.cc.config")
local machine = require("adapters.cc.machine")
local sound = require("adapters.cc.sound")
local splash = require("os.kernel.splash")
local version = require("lib.version")

local NODE_PATH = ".node"

local node = config.load(NODE_PATH, {
  role = nil,
  label = nil,
  job = nil,
  parked = false,
  autoUpdate = true,
})

local caps = machine.capabilities()

--- Early builds offered the stationary base role to Pocket Computers. Migrate
--- those installations to the controller role so they never compete with the
--- real base for the hosted Rednet name.
if caps.kind == "pocket" and node.role == "fleet" then
  node.role = "controller"
  config.save(NODE_PATH, node)
end

---------------------------------------------------------------------------
-- Splash, and the way out of it
---------------------------------------------------------------------------

local screen = require("adapters.cc.screen").new(term)

-- The jingle runs alongside the animation rather than before it, so a machine
-- with a speaker boots no slower than one without. `parallel` is used here and
-- nowhere else in ICOS 2: this is before the supervisor exists, and two things
-- that both finish is exactly what `waitForAll` is for. The bug `os/turtle/
-- main.lua` exists to fix is `waitForAny`, which returns when *either*
-- finishes - a different function with a similar name.
local interrupted = false
parallel.waitForAll(function()
  interrupted = splash.run(screen, {
    subtitle = node.label or caps.kind,
    version = version,
    pull = function()
      return os.pullEvent()
    end,
  })
end, function()
  sound.play("boot")
end)

---------------------------------------------------------------------------
-- Setup, update, hand over
---------------------------------------------------------------------------

if not node.role then
  -- Never been set up. Setup is not optional and there is nothing to fall back
  -- to, so this is the one path that does not care whether a key was held.
  shell.run("commands/setup.lua")
  return
end

if interrupted then
  -- The hatch. Setup can change the role, the job and the position, which is
  -- everything needed to rescue a machine that is booting into the wrong thing.
  print("")
  print("Interrupted - opening setup.")
  print("Reboot to start normally.")
  print("")
  shell.run("commands/setup.lua")
  return
end

if node.autoUpdate ~= false and caps.http and fs.exists(".update") then
  local ok, ran = pcall(shell.run, "update.lua", "--automatic")
  if not ok or ran == false then
    -- Not fatal. A machine that refused to boot because it could not reach a
    -- repository would be a fleet that stops working when GitHub does.
    printError("Update failed - running installed code.")
    sound.play("error")
    sleep(1.2)
  end
end

local booted, why = require("os.kernel.boot").machine(node)
if booted == nil then
  printError(why)
  print("Run `commands/setup.lua` to choose a role.")
  return
end

sound.play("ready")

local outcome, reason = require("os.kernel.boot").run(booted)

if outcome == "stopped" then
  printError("every service gave up: " .. tostring(reason))
  print("Run `icos status` to see which.")
  sound.play("error")
elseif outcome == "halted" then
  print("Stopped on request.")
else
  print("ICOS stopped.")
end
