--- ICOS application registry.
---
--- Programs in apps/ are deliberately ordinary CraftOS scripts: they can be
--- run from the shell, from the turtle launcher, or inside a desktop window.
--- This registry adds the metadata the OS needs without forcing every script
--- to become a special module.

local apps = {}

local DEFINITIONS = {
  {
    id = "fleet",
    name = "Fleet",
    program = "apps/fleet.lua",
    args = { "--embedded" },
    kinds = { "computer", "pocket", "command" },
    roles = { "fleet" },
    surfaces = { "desktop" },
    needs = function(caps)
      return caps.modem
    end,
  },
  {
    id = "miner",
    name = "Miner",
    program = "apps/miner.lua",
    kinds = { "turtle" },
    roles = { "miner" },
    surfaces = { "launcher" },
  },
  {
    id = "scan",
    name = "Ore Scan",
    program = "apps/scan.lua",
    surfaces = { "desktop", "launcher" },
    needs = function(caps)
      return caps.geoScanner
    end,
  },
  {
    id = "swarm",
    name = "Swarm",
    program = "apps/swarm.lua",
    kinds = { "turtle" },
    roles = { "utility" },
    surfaces = { "launcher" },
  },
  {
    id = "update",
    name = "Update",
    program = "update.lua",
    kinds = { "computer", "pocket", "command" },
    surfaces = { "desktop" },
    needs = function(caps)
      return caps.http
    end,
  },
  {
    id = "terminal",
    name = "Terminal",
    program = "shell",
    kinds = { "computer", "pocket", "command" },
    surfaces = { "desktop" },
  },
  {
    id = "setup",
    name = "Setup",
    program = "install.lua",
    kinds = { "computer", "pocket", "command" },
    surfaces = { "desktop" },
  },
  {
    id = "power",
    name = "Power",
    program = "apps/power.lua",
    kinds = { "computer", "pocket", "command" },
    surfaces = { "desktop" },
  },
  {
    id = "where",
    name = "Set position",
    program = "apps/where.lua",
    kinds = { "turtle" },
    surfaces = { "tools" },
  },
  {
    id = "equip",
    name = "Swap modem",
    program = "apps/equip.lua",
    kinds = { "turtle" },
    surfaces = { "tools" },
  },
  {
    id = "update-tool",
    name = "Update now",
    program = "update.lua",
    kinds = { "turtle" },
    surfaces = { "tools" },
    needs = function(caps)
      return caps.http
    end,
  },
  {
    id = "setup-tool",
    name = "Change role",
    program = "install.lua",
    kinds = { "turtle" },
    surfaces = { "tools" },
  },
}

local function matches(list, value)
  if not list then
    return true
  end
  for _, entry in ipairs(list) do
    if entry == value then
      return true
    end
  end
  return false
end

local function canRun(app, caps, node, surface)
  if not matches(app.kinds, caps.kind) or not matches(app.roles, node and node.role) then
    return false
  end
  if surface and not matches(app.surfaces, surface) then
    return false
  end
  return not app.needs or app.needs(caps) == true
end

function apps.all()
  return DEFINITIONS
end

--- Apps valid for this hardware, configured role, and UI surface.
function apps.available(caps, node, surface)
  local out = {}
  for _, app in ipairs(DEFINITIONS) do
    if canRun(app, caps, node, surface) then
      out[#out + 1] = app
    end
  end
  return out
end

function apps.byId(id)
  for _, app in ipairs(DEFINITIONS) do
    if app.id == id then
      return app
    end
  end
  return nil
end

--- Run an app in the caller's current terminal/window.
function apps.run(app)
  if not app or not app.program then
    return false, "invalid app"
  end
  return shell.run(app.program, table.unpack(app.args or {}))
end

return apps
