--- Give this machine a role. Run once per computer or turtle.
---
--- This is the whole "deploy another turtle" story: place it, pull the code,
--- run `install`, pick miner. It labels itself, finds the base station over
--- rednet by name, and announces itself - the base adds it to the roster with
--- no configuration on the base's side at all.

package.path = "/?.lua;/?/init.lua;" .. package.path

local ui = require("core.ui")
local net = require("core.net")
local config = require("core.config")

local NODE_PATH = ".node"

local node = config.load(NODE_PATH, { role = nil, label = nil })

local ROLES = {
  { key = "miner", label = "Mining turtle", turtleOnly = true },
  { key = "fleet", label = "Fleet base station", turtleOnly = false },
  { key = "utility", label = "Utility (no autorun)", turtleOnly = false },
}

local choices = {}
local available = {}
for _, role in ipairs(ROLES) do
  if not role.turtleOnly or turtle then
    available[#available + 1] = role
    choices[#choices + 1] = role.label
  end
end

local picked = ui.menu("Install - pick a role", choices)
if not picked then
  ui.clear()
  print("Cancelled.")
  return
end

local role = available[picked]
node.role = role.key

ui.clear()
print("Role: " .. role.label .. "\n")

local suggested = node.label
if not suggested then
  if role.key == "fleet" then
    suggested = "base"
  else
    suggested = role.key .. "-" .. os.getComputerID()
  end
end

node.label = ui.ask("Name this machine", suggested)
os.setComputerLabel(node.label)
config.save(NODE_PATH, node)

print("")

if role.key == "miner" then
  if not net.open() then
    printError("No modem attached.")
    print("The turtle will mine fine, but nothing will track it.")
    print("Attach an ender modem for reporting to work underground.")
  else
    write("Looking for the base station... ")
    local baseId = net.findBase()
    if baseId then
      print("found (id " .. baseId .. ")")
      net.send(baseId, "hello", { label = node.label, role = "miner", phase = "installed" })
      print("Registered with the fleet.")
    else
      print("not found")
      print("")
      print("That is fine - the turtle will keep looking while it")
      print("works. Make sure `fleet` is running on the base.")
    end
  end
elseif role.key == "fleet" then
  if not net.open() then
    printError("No modem attached - the base cannot hear turtles.")
  end
end

print("")
print("Done. Reboot (Ctrl+R) to start in this role.")
