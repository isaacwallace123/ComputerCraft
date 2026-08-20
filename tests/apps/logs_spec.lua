local expect = require("support.expect")
local registry = require("apps.registry")
local it = require("support.spec").it
local fleet = require("support.fleet")

local logPort = require("ports.log")
local logs = require("apps.logs.app")
local osBoot = require("os.kernel.boot")
local roles = require("os.kernel.roles")
local shell = require("os.client.shell")
local ui = require("ui.init")

local fakeClock = fleet.clock
local fakePorts = fleet.ports

---------------------------------------------------------------------------
-- Logs: the loop that was open, now closed
---------------------------------------------------------------------------

it("a failing service ends up in the log, which is what logrotate rotates", function()
  -- The loop that was open: every service returns what it did rather than
  -- logging it, and nothing was writing the file logrotate exists to rotate.
  local port = logPort.memory()
  local clock = fakeClock(0)
  local ports = fakePorts(clock)
  ports.log = port

  local machine = assert(osBoot.machine({}, {
    role = roles.CLIENT,
    ports = ports,
    draw = function()
      error("no screen", 0)
    end,
  }))

  for _ = 1, 8 do
    machine.supervisor:step()
    clock.advance(60)
  end

  local lines = port.recent(20)
  expect.truthy(#lines > 0, "something was written")
  expect.contains(lines[1].text, "screen", "naming the service")
  expect.contains(lines[1].text, "no screen", "and what it said")
end)

it("the first failure is a warning and the rest are errors", function()
  -- A service that fails once and restarts is ordinary - a radio going out of
  -- range does it - and a machine that shouted about every one would train
  -- somebody to skip the shouting.
  local port = logPort.memory()
  local clock = fakeClock(0)
  local ports = fakePorts(clock)
  ports.log = port

  local machine = assert(osBoot.machine({}, {
    role = roles.CLIENT,
    ports = ports,
    draw = function()
      error("flapping", 0)
    end,
  }))

  for _ = 1, 8 do
    machine.supervisor:step()
    clock.advance(60)
  end

  local lines = port.recent(20)
  expect.truthy(#lines >= 2, "more than one failure was recorded")
  expect.equal(lines[1].level, "warn", "the first is a warning")
  expect.equal(lines[#lines].level, "error", "and a service that keeps failing is an error")
end)

it("a log page shows the newest line last, because a log is a sequence", function()
  -- Every other list in ICOS puts the interesting thing first. Reading a
  -- sequence backwards means reading every consequence before its cause.
  local port = logPort.memory()
  port.info("first")
  port.warn("second")
  port.error("third")

  local lines = logs.lines(port, 10, false)
  expect.equal(#lines, 3, "all three")
  expect.contains(lines[1].text, "first", "oldest first")
  expect.contains(lines[3].text, "third", "newest last")
end)

it("warnings-only keeps the two levels that mean something", function()
  local port = logPort.memory()
  port.info("routine")
  port.warn("odd")
  port.info("routine")
  port.error("bad")

  expect.equal(#logs.lines(port, 10, false), 4, "everything")
  expect.equal(#logs.lines(port, 10, true), 2, "and only what matters")
end)

it("an unparseable line is still shown", function()
  -- The CC adapter recovers the level from a formatted string rather than
  -- storing it, so a line that predates the format - or one somebody typed into
  -- .log by hand - has none. Hiding it would hide exactly the note they left.
  expect.equal(logs.level({ text = "something hand-written" }), "info", "shown as info")
  expect.equal(logs.level(nil), "info", "and nothing is not a crash")
  expect.equal(logs.level({ level = "error" }), "error", "while a real level survives")

  -- The bug this pins down: the CC adapter recovers the level from a line
  -- adapters/cc/logfile.lua writes upper-case, and returning it raw made every page compare
  -- "WARN" against "warn" - so the warnings-only filter showed an empty screen
  -- while warnings were arriving. One function owns the vocabulary now.
  expect.equal(logPort.level("WARN"), "warn", "case is the port's business")
  expect.equal(logPort.level("Error"), "error", "however it arrives")
  expect.equal(logPort.level("banana"), "info", "and a level nobody knows is not a hidden line")
end)

it("only two levels are coloured, because a log of all colours has none", function()
  local T = require("ui.theme").TOKENS
  expect.equal(logs.tone("error"), T.destructive, "errors")
  expect.equal(logs.tone("warn"), T.warn, "warnings")
  expect.equal(logs.tone("info"), T.foreground, "and the majority stays plain")
end)

it("Logs reaches every surface, including the one that needs it most", function()
  -- `edit .log` on a turtle whose screen is thirteen rows and whose program is
  -- still running is not a thing anybody does at 2am.
  local onTurtle = registry.available("turtle", "launcher")
  local found = false
  for _, entry in ipairs(onTurtle) do
    if entry.id == "logs" then
      found = true
    end
  end
  expect.truthy(found, "a turtle can read its own log")
end)
