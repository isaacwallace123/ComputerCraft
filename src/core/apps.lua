--- ICOS application registry.
---
--- Programs in apps/ are deliberately ordinary CraftOS scripts: they can be
--- run from the shell, from the turtle launcher, or inside a desktop window.
--- This registry adds the metadata the OS needs without forcing every script
--- to become a special module.

local apps = {}

-- Operational input means a keyboard-capable surface where configuration and
-- commands are safe to expose. A monitor still has touch coordinates for
-- harmless paging and app switching, but is intentionally display-only.
local INPUT_SURFACES = {
  desktop = true,
  handheld = true,
  launcher = true,
  tools = true,
}

local DEFINITIONS = {
  {
    id = "fleet",
    name = "Fleet",
    program = "apps/fleet.lua",
    args = { "--embedded", "--no-aux" },
    kinds = { "computer", "pocket", "command" },
    roles = { "fleet", "controller" },
    surfaces = { "desktop", "handheld" },
    requiresInput = true,
  },
  {
    id = "fleet-status",
    name = "Fleet Status",
    program = "apps/fleet.lua",
    args = { "--embedded", "--readonly" },
    kinds = { "computer", "command" },
    roles = { "fleet" },
    surfaces = { "monitor" },
    requiresInput = false,
  },
  {
    id = "devices",
    name = "Devices",
    program = "apps/devices.lua",
    args = { "--embedded" },
    kinds = { "computer", "pocket", "command" },
    roles = { "fleet", "controller" },
    surfaces = { "desktop", "handheld" },
    requiresInput = true,
  },
  {
    id = "automation",
    name = "Auto Recovery",
    program = "apps/automation.lua",
    kinds = { "computer", "pocket", "command" },
    roles = { "fleet", "controller" },
    surfaces = { "desktop", "handheld" },
    requiresInput = true,
  },
  {
    id = "operations",
    name = "Mine Control",
    program = "apps/operations.lua",
    kinds = { "computer", "pocket", "command" },
    roles = { "fleet", "controller" },
    surfaces = { "desktop", "handheld" },
    requiresInput = true,
  },
  {
    id = "logs",
    name = "Fleet Log",
    program = "apps/logs.lua",
    kinds = { "computer", "pocket", "command" },
    roles = { "fleet", "controller" },
    surfaces = { "desktop", "handheld" },
    requiresInput = true,
  },
  {
    id = "fleet-log-status",
    name = "Fleet Log",
    program = "apps/logs.lua",
    args = { "--readonly" },
    kinds = { "computer", "command" },
    roles = { "fleet" },
    surfaces = { "monitor" },
    requiresInput = false,
  },
  {
    id = "fleet-console",
    name = "Fleet Console",
    program = "apps/console.lua",
    kinds = { "computer", "command" },
    roles = { "fleet" },
    surfaces = { "desktop" },
    requiresInput = true,
  },
  {
    id = "miner",
    name = "Miner",
    program = "apps/miner.lua",
    kinds = { "turtle" },
    roles = { "miner" },
    surfaces = { "launcher" },
    requiresInput = true,
  },
  {
    id = "scan",
    name = "Ore Scan",
    program = "apps/scan.lua",
    surfaces = { "desktop", "handheld", "launcher" },
    requiresInput = true,
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
    requiresInput = true,
  },
  {
    id = "update",
    name = "Update",
    program = "update.lua",
    kinds = { "computer", "pocket", "command" },
    surfaces = { "desktop", "handheld" },
    requiresInput = true,
    needs = function(caps)
      return caps.http
    end,
  },
  {
    id = "terminal",
    name = "Terminal",
    program = "shell",
    kinds = { "computer", "pocket", "command" },
    surfaces = { "desktop", "handheld" },
    requiresInput = true,
  },
  {
    id = "setup",
    name = "Setup",
    program = "install.lua",
    kinds = { "computer", "pocket", "command" },
    surfaces = { "desktop", "handheld" },
    requiresInput = true,
  },
  {
    id = "power",
    name = "Power",
    program = "apps/power.lua",
    kinds = { "computer", "pocket", "command" },
    surfaces = { "desktop", "handheld" },
    requiresInput = true,
  },
  {
    id = "where",
    name = "Set position",
    program = "apps/where.lua",
    kinds = { "turtle" },
    surfaces = { "tools" },
    requiresInput = true,
  },
  {
    id = "equip",
    name = "Swap modem",
    program = "apps/equip.lua",
    kinds = { "turtle" },
    surfaces = { "tools" },
    requiresInput = true,
  },
  {
    id = "update-tool",
    name = "Update now",
    program = "update.lua",
    kinds = { "turtle" },
    surfaces = { "tools" },
    requiresInput = true,
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
    requiresInput = true,
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

function apps.surfaceHasInput(surface)
  return surface == nil or INPUT_SURFACES[surface] == true
end

local function canRun(app, caps, node, surface)
  if not matches(app.kinds, caps.kind) or not matches(app.roles, node and node.role) then
    return false
  end
  if surface and not matches(app.surfaces, surface) then
    return false
  end
  -- Input is a property of the output surface, not just the computer. A base
  -- computer has a keyboard on its own terminal while its attached monitor has
  -- touch coordinates only. Unknown apps default to requiring input so a new
  -- configuration page cannot accidentally appear on a display-only wall.
  if app.requiresInput ~= false and not apps.surfaceHasInput(surface) then
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
