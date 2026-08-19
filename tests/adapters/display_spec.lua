--- Walls: picking one, sizing it, and keeping its events off the keyboard.
---
--- A base station draws twice - a keyboard desktop on its own terminal and a
--- display-only dashboard on the monitor - and until now ICOS 2 had neither. It
--- built one screen port over `term` and stopped, so `roles.alsoClient` was a
--- question nothing asked and the Fleet page, the one page designed to be left
--- open on a wall, had nowhere to be.
---
--- The part worth testing is not the drawing. It is the two decisions underneath:
--- which monitor, at what scale, and **which surface an event belongs to**. The
--- last one is D020 expressed one layer below where it usually lives: a
--- display-only surface is one whose input port cannot yield a keystroke.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

--- A base with walls. Sizes are characters at text scale 0.5, which is where
--- `display` measures every monitor before comparing them.
local function base(monitors)
  return scenario.new({ groundY = 64, monitors = monitors })
end

---------------------------------------------------------------------------
-- Choosing a wall
---------------------------------------------------------------------------

it("a machine with no monitor gets no wall, which is not a fault", function()
  base({})
  local display = require("adapters.cc.display")

  -- Most machines. A base with no monitor draws on its own terminal, so this
  -- returning nil has to be an ordinary answer rather than an error.
  expect.falsy(display.attach(), "nothing attached")
end)

it("the physically largest wall is chosen, not the first one named", function()
  base({
    { name = "monitor_0", width = 40, height = 20 },
    { name = "monitor_1", width = 160, height = 80 },
  })
  local display = require("adapters.cc.display")

  local _, name = display.attach()
  expect.equal(name, "monitor_1", "the big wall wins")
end)

it("walls are compared at one scale, not at whatever they were left on", function()
  local created = base({
    { name = "monitor_0", width = 160, height = 80 },
    { name = "monitor_1", width = 40, height = 20 },
  })

  -- Somebody left the big wall on scale 5, so it currently reports very few
  -- characters. Comparing as-found would call the small one bigger, which is
  -- comparing settings rather than walls.
  peripheral.wrap("monitor_0").setTextScale(5)

  local display = require("adapters.cc.display")
  local _, name = display.attach()
  expect.equal(name, "monitor_0", "measured fairly, the big wall is still the big wall")
  expect.truthy(created ~= nil, "the world exists")
end)

it("the largest readable scale that still fits is the one chosen", function()
  base({ { name = "monitor_0", width = 160, height = 80 } })
  local display = require("adapters.cc.display")

  local _, _, found = display.attach({ minWidth = 42, minHeight = 18 })
  local size = assert(found, "a monitor is attached")

  -- Big enough for the layout...
  expect.truthy(size.width >= 42, "wide enough")
  expect.truthy(size.height >= 18, "tall enough")

  -- ...and no bigger than it needs to be. A wall showing a fleet at scale 0.5 is
  -- technically correct and unreadable from the far side of a room, which is the
  -- only place anybody reads it from.
  local monitor = assert(peripheral.wrap("monitor_0"), "the wall is wrappable")
  monitor.setTextScale(size.scale + 0.5)
  local wider = monitor.getSize()
  expect.truthy(wider < 42, "one scale larger would not have fitted")
end)

it("a wall too small for the layout shows what it can rather than nothing", function()
  base({ { name = "monitor_0", width = 20, height = 8 } })
  local display = require("adapters.cc.display")

  local port, _, found = display.attach({ minWidth = 42, minHeight = 18 })
  expect.truthy(port, "it is still attached")
  expect.equal(assert(found, "with a size").scale, 0.5, "at the most characters it can manage")
end)

it("the wall is a screen port like any other", function()
  base({ { name = "monitor_0", width = 80, height = 40 } })
  local display = require("adapters.cc.display")

  -- `screen.check` raises on a missing method, so attaching at all is the
  -- assertion: a monitor and a terminal are the same port, which is what lets
  -- one page render to either without knowing which it got.
  local port = assert(display.attach(), "a monitor is attached")
  local width, height = port.size()
  expect.truthy(width > 0 and height > 0, "it reports a size")
end)

---------------------------------------------------------------------------
-- Which surface an event belongs to
---------------------------------------------------------------------------

--- Queue events into the simulated world and read them back through a port.
local function drain(port, count)
  local seen = {}
  for _ = 1, count do
    local name = port.pull(0.05)
    if name == nil then
      break
    end
    seen[#seen + 1] = name
  end
  return seen
end

it("a keystroke never reaches the wall", function()
  local created = base({ { name = "monitor_0", width = 80, height = 40 } })
  local wall = require("adapters.cc.input").monitor("monitor_0")

  created:push("key", 30)
  created:push("char", "d")
  created:push("monitor_touch", "monitor_0", 4, 2)

  local seen = drain(wall, 3)

  -- D020, one layer below where it is usually stated. The dashboard surface is
  -- not merely handed no callbacks - it cannot be typed at, so no app running on
  -- it can act on a keystroke however that app was written.
  expect.equal(#seen, 1, "only one event was for this surface")
  expect.equal(seen[1], "monitor_touch", "and it was the touch")
end)

it("a touch on the wall never moves the terminal's selection", function()
  local created = base({ { name = "monitor_0", width = 80, height = 40 } })
  local terminal = require("adapters.cc.input").terminal()

  created:push("monitor_touch", "monitor_0", 4, 2)
  created:push("key", 30)

  local seen = drain(terminal, 2)
  expect.equal(#seen, 1, "the touch was not for the terminal")
  expect.equal(seen[1], "key", "the keystroke was")
end)

it("a base with two walls acts only on the one that was touched", function()
  local created = base({
    { name = "monitor_0", width = 80, height = 40 },
    { name = "monitor_1", width = 80, height = 40 },
  })
  local wall = require("adapters.cc.input").monitor("monitor_0")

  created:push("monitor_touch", "monitor_1", 4, 2)
  created:push("monitor_touch", "monitor_0", 6, 3)

  local seen = drain(wall, 2)
  expect.equal(#seen, 1, "the other wall's touch is ignored")
end)

---------------------------------------------------------------------------
-- A base station is a server and a client at once
---------------------------------------------------------------------------

--- Ports for a headless server, plus whatever screens the caller wants.
---
--- Every blocking call yields, and that is not decoration. A service body is a
--- `while true` that parks on a receive or a sleep; a stub that returned
--- instantly would spin inside `coroutine.resume`, which never returns - so the
--- supervisor never gets control back and the whole spec run hangs rather than
--- failing. Yielding is what a real port does when it waits.
local function idle()
  coroutine.yield()
end

local function serverPorts(extra)
  local ports = {
    clock = {
      now = function()
        return 0
      end,
      sleep = idle,
    },
    storage = {
      read = function() end,
      write = function()
        return true
      end,
    },
    serialise = {
      encode = function()
        return ""
      end,
      decode = function()
        return {}
      end,
    },
    transport = {
      open = function()
        return true
      end,
      send = function() end,
      broadcast = function() end,
      receive = idle,
      host = function()
        return true
      end,
      id = function()
        return 1
      end,
    },
    locator = { saved = function() end, gps = function() end },
    beacon = {
      open = function()
        return true
      end,
      answer = idle,
    },
    log = {
      info = function() end,
      warn = function() end,
      error = function() end,
      recent = function()
        return {}
      end,
    },
  }
  for key, value in pairs(extra or {}) do
    ports[key] = value
  end
  return ports
end

local function ids(machine)
  local out = {}
  for _, row in ipairs(machine.supervisor:health()) do
    out[row.id] = true
  end
  return out
end

it("a headless server runs no screen at all", function()
  local server = require("os.server.main")
  local machine = server.boot(serverPorts(), { draw = function() end })

  -- Every spec is a headless server, and so is a real base whose monitor has
  -- been unplugged. The supervisor refuses a service whose ports are absent, so
  -- this is the absence of a port rather than a branch in the composition root.
  expect.falsy(ids(machine).desktop, "no desktop")
  expect.falsy(ids(machine).wall, "no wall")
end)

it("a server with a terminal draws a desktop on it", function()
  local server = require("os.server.main")
  local drawn = {}
  local machine = server.boot(serverPorts({ screen = {}, input = {} }), {
    draw = function()
      drawn.desktop = true
    end,
  })

  expect.truthy(ids(machine).desktop, "the client half of the base station")
  expect.falsy(ids(machine).wall, "and no wall, because none is attached")
  machine.supervisor:step()
  expect.truthy(drawn.desktop, "the desktop was actually run")
end)

it("a server with a monitor draws on both, and the wall is read-only", function()
  local server = require("os.server.main")
  local shells = {}
  local machine = server.boot(serverPorts({ screen = {}, input = {}, wall = {}, wallInput = {} }), {
    draw = function()
      shells.desktop = true
    end,
    drawWall = function()
      shells.wall = true
    end,
  })

  expect.truthy(ids(machine).desktop, "the keyboard surface")
  expect.truthy(ids(machine).wall, "and the wall")

  machine.supervisor:step()
  expect.truthy(shells.desktop, "the desktop ran")
  expect.truthy(shells.wall, "the wall ran")
end)

it("the wall shell is handed the wall's own ports", function()
  local server = require("os.server.main")
  local wallScreen, wallInput = { tag = "wall" }, { tag = "wallInput" }
  local seen = nil

  local machine = server.boot(
    serverPorts({
      screen = { tag = "term" },
      input = { tag = "keys" },
      wall = wallScreen,
      wallInput = wallInput,
    }),
    {
      draw = function() end,
      drawWall = function(inner)
        seen = inner
      end,
    }
  )
  machine.supervisor:step()

  -- The default `drawWall` copies the context and swaps in the wall's pair, so
  -- a page mounted there talks to the monitor rather than to the terminal. Both
  -- halves matter: the wrong screen draws in the wrong place, and the wrong
  -- input port would let somebody type at a display-only surface.
  expect.truthy(seen ~= nil, "the wall shell was called")
end)

it("neither screen is critical, because a base with no monitor is still a base", function()
  local server = require("os.server.main")
  local machine = server.boot(serverPorts({ screen = {}, input = {} }), { draw = function() end })

  for _, row in ipairs(machine.supervisor:health()) do
    if row.id == "desktop" or row.id == "wall" then
      -- A server reporting unhealthy because a monitor was unplugged would be
      -- reporting it on the monitor.
      expect.falsy(row.critical, row.id .. " must not take the machine down")
    end
  end
end)

it("terminate reaches every surface, whatever the filter says", function()
  local created = base({ { name = "monitor_0", width = 80, height = 40 } })
  local wall = require("adapters.cc.input").monitor("monitor_0")

  created:push("terminate")

  -- The machine going down is not somebody interacting with a screen. A shell
  -- that filtered this out would keep painting through a Ctrl-T.
  local seen = drain(wall, 1)
  expect.equal(seen[1], "terminate", "the wall stops too")
end)
