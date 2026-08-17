--- What am I, and what can I do?
---
--- Every other module asks this rather than testing for globals itself, so
--- "does this machine support X" is answered in exactly one place. It is also
--- what lets install offer only the roles a machine can actually perform - a
--- computer with no modem should never be offered the base station job.

local device = {}

device.KINDS = {
  turtle = "Turtle",
  pocket = "Pocket computer",
  command = "Command computer",
  computer = "Computer",
}

--- The globals CC injects are the only reliable way to tell these apart.
function device.kind()
  if turtle then
    return "turtle"
  end
  if pocket then
    return "pocket"
  end
  if commands then
    return "command"
  end
  return "computer"
end

function device.isAdvanced()
  return term.isColour()
end

--- Everything attached, in one table. Cheap enough to call on demand.
function device.capabilities()
  local caps = {
    kind = device.kind(),
    advanced = device.isAdvanced(),
    id = os.getComputerID(),
    label = os.getComputerLabel(),
    http = http ~= nil,
    modem = false,
    wireless = false,
    speaker = peripheral.find("speaker") ~= nil,
    monitor = peripheral.find("monitor") ~= nil,
    geoScanner = (peripheral.find("geoScanner") or peripheral.find("geo_scanner")) ~= nil,
    chunky = peripheral.find("chunky") ~= nil,
  }

  for _, name in ipairs(peripheral.getNames()) do
    -- Peripherals may expose multiple types. Ender Pocket Computers can expose
    -- their back upgrade with another primary type while still carrying the
    -- `modem` trait, so comparing only getType's first return value misses it.
    if peripheral.hasType(name, "modem") then
      caps.modem = true
      local modem = peripheral.wrap(name)
      if modem and modem.isWireless() then
        caps.wireless = true
      end
    end
  end

  return caps
end

--- Roles a machine can take. `requires` decides whether it is even offered;
--- `warn` is shown when the role will work but something is missing.
device.ROLES = {
  {
    key = "miner",
    label = "Mining turtle",
    detail = "Runs jobs, reports to the fleet",
    requires = function(caps)
      return caps.kind == "turtle"
    end,
    warn = function(caps)
      if not caps.modem then
        return "no modem: it will mine, but nothing will track it"
      end
      return nil
    end,
  },
  {
    key = "fleet",
    label = "Fleet base station",
    detail = "Roster, dashboard, fleet orders",
    requires = function(caps)
      return caps.kind ~= "turtle" and caps.kind ~= "pocket" and caps.modem
    end,
    warn = function(caps)
      if not caps.monitor then
        return "no monitor: the dashboard will draw on this screen"
      end
      if not caps.wireless then
        return "wired modem: turtles will not reach this"
      end
      return nil
    end,
  },
  {
    key = "gps",
    label = "GPS host",
    detail = "Always-on coordinate beacon",
    requires = function(caps)
      return caps.kind ~= "pocket" and caps.wireless
    end,
    warn = function(caps)
      if caps.kind == "turtle" and not caps.chunky then
        return "not Chunky: keep this turtle's chunk loaded another way"
      end
      return nil
    end,
  },
  {
    key = "controller",
    label = "Fleet handheld",
    detail = "Mobile dashboard and full fleet control",
    requires = function(caps)
      -- The shell remains useful offline, so setup should not collapse to a
      -- confusing Utility-only menu when a Pocket genuinely has no upgrade.
      return caps.kind == "pocket"
    end,
    warn = function(caps)
      if not caps.modem then
        return "no modem: the UI works offline; fleet control needs a wireless or ender modem"
      end
      if not caps.wireless then
        return "wired modem: use a wireless or ender modem while mobile"
      end
      return nil
    end,
  },
  {
    key = "utility",
    label = "Utility",
    detail = "No autorun, boots to the menu",
    requires = function()
      return true
    end,
  },
}

--- Roles valid for these capabilities, in menu order.
function device.roles(caps)
  local out = {}
  for _, role in ipairs(device.ROLES) do
    if role.requires(caps) then
      out[#out + 1] = role
    end
  end
  return out
end

--- Lines describing the hardware, for the install screen.
function device.describe(caps)
  local lines = {
    ("%-10s %s%s"):format(
      "type",
      device.KINDS[caps.kind] or caps.kind,
      caps.advanced and " (advanced)" or ""
    ),
    ("%-10s %d"):format("id", caps.id),
  }

  local function yn(value, yes, no)
    return value and yes or no
  end

  lines[#lines + 1] = ("%-10s %s"):format(
    "modem",
    yn(caps.modem, yn(caps.wireless, "wireless", "wired"), "none")
  )
  lines[#lines + 1] = ("%-10s %s"):format("monitor", yn(caps.monitor, "yes", "none"))
  lines[#lines + 1] = ("%-10s %s"):format("speaker", yn(caps.speaker, "yes", "none"))
  if caps.geoScanner then
    lines[#lines + 1] = ("%-10s %s"):format("scanner", "geo scanner")
  end
  if caps.chunky then
    lines[#lines + 1] = ("%-10s %s"):format("loader", "chunky")
  end

  return lines
end

return device
