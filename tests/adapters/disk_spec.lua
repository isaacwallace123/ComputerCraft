--- A full disk, which is the failure that actually took a base station down.
---
--- A live ICOS 1 base ran for weeks, filled its disk, and put
--- `adapters/cc/logfile.lua:68: Out of space` across a running desktop. Three
--- separate defects lined up to produce that, and **none of them could be
--- reproduced here**, because the simulated filesystem was an unbounded table.
--- So the first thing this file needed was a disk with a size.
---
--- What it pins down:
---
---   * a logger may not take down its caller, whatever the disk is doing
---   * `storage.write` answers `false` rather than raising, which is what the
---     port always claimed and could not do
---   * `logrotate`'s "could not copy it, so do not clear it" guard is reachable
---   * the log stays bounded on a machine that is never rebooted
---
--- The last one is the original bug. `trim` ran once, at require time - fine for
--- a turtle that reboots most days, useless on the one machine that never does.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

--- A fresh logger over a fresh world.
---
--- `adapters.` is deliberately not in the world's reboot set, so the logger's
--- module-level ring buffer and trim counter survive a `scenario.new` that is
--- meant to be a clean machine. Dropping it by hand is safe here for the reason
--- the reboot set's own comment gives: nothing in it carries identity across a
--- require - no metatables, no sentinel tables.
local function logger(created)
  package.loaded["adapters.cc.logfile"] = nil
  local log = require("adapters.cc.logfile")
  return log, created
end

---------------------------------------------------------------------------
-- The logger
---------------------------------------------------------------------------

it("a full disk does not stop the machine that was logging", function()
  local created = scenario.new({ groundY = 64 })
  local log = logger(created)

  log.info("this one fits")
  created:fillDisk(0)

  -- The whole finding, as one assertion. This used to raise out of `log.info`
  -- and through whatever called it, which is why a desktop showed a stack trace
  -- instead of a fleet.
  local ok = pcall(log.info, "this one does not")
  expect.truthy(ok, "logging on a full disk must not raise")

  -- And the line is still in the ring buffer the dashboard reads, because
  -- losing the file is not a reason to lose the screen.
  local recent = log.recent(4)
  expect.contains(recent[#recent].text, "this one does not", "the dropped line is still shown")
end)

it("the log stays bounded on a machine that is never rebooted", function()
  local created = scenario.new({ groundY = 64 })
  local log = logger(created)

  -- Comfortably more than the 400-line cap and the 100-line trim interval, with
  -- no reboot anywhere - which is exactly the base station's life.
  for index = 1, 700 do
    log.info("line " .. index)
  end

  local lines = 0
  for _ in (created.files[".log"] or ""):gmatch("\n") do
    lines = lines + 1
  end

  expect.truthy(lines <= 400, "the file is trimmed while running, not only at boot")
  expect.truthy(lines > 300, "trimming keeps a useful tail rather than emptying the file")

  -- The newest line survives. Truncation keeps the end of the file, and a trim
  -- that dropped the most recent line would be worse than no trim at all.
  expect.contains(created.files[".log"], "line 700", "the newest line is kept")
end)

---------------------------------------------------------------------------
-- The storage port
---------------------------------------------------------------------------

it("storage.write returns false on a full disk instead of raising", function()
  local created = scenario.new({ groundY = 64 })
  local storage = require("adapters.cc.storage").new()

  expect.truthy(storage.write(".probe", "small"), "a write that fits succeeds")
  created:fillDisk(0)

  local ok, result, reason = pcall(storage.write, ".probe", string.rep("x", 512))
  expect.truthy(ok, "the port answers rather than raising")
  expect.falsy(result, "a write that cannot happen is false")
  expect.truthy(reason ~= nil, "and it says why")
end)

it("a refused write leaves the previous contents alone", function()
  local created = scenario.new({ groundY = 64 })
  local storage = require("adapters.cc.storage").new()

  storage.write(".keep", "the good copy")
  created:fillDisk(4)

  storage.write(".keep", string.rep("y", 4096))

  -- The replacement is written under `.tmp` and only moved into place once it
  -- is complete, so a failure half way through cannot destroy what was there.
  -- This is the property `.nav` depends on, expressed against the one condition
  -- that actually triggers it.
  expect.equal(storage.read(".keep"), "the good copy", "the live file is untouched")
end)

---------------------------------------------------------------------------
-- logrotate, whose guard was unreachable
---------------------------------------------------------------------------

it("logrotate keeps the log when it cannot copy it aside first", function()
  local created = scenario.new({ groundY = 64 })
  local logrotate = require("os.server.services.logrotate")
  local storage = require("adapters.cc.storage").new()

  local text = ("a line\n"):rep(logrotate.MAX_LINES + 10)
  storage.write(logrotate.PATH, text)
  created:fillDisk(0)

  local context = { storage = storage }
  local rotated = logrotate.rotate(context)

  -- `rotate` guards with `if not storage.write(previous, text)`. That guard has
  -- been in the file since it was written and could never fire, because the
  -- write raised instead of returning false - so on a full disk the service
  -- errored, backed off, and never rotated. Which is the one condition it
  -- exists for.
  expect.equal(rotated, 0, "nothing is reported rotated")
  expect.equal(storage.read(logrotate.PATH), text, "the log is not cleared")
end)

it("logrotate moves the log aside when there is room", function()
  scenario.new({ groundY = 64 })
  local logrotate = require("os.server.services.logrotate")
  local storage = require("adapters.cc.storage").new()

  local text = ("a line\n"):rep(logrotate.MAX_LINES + 10)
  storage.write(logrotate.PATH, text)

  local context = { storage = storage }
  local rotated = logrotate.rotate(context)

  expect.equal(rotated, logrotate.MAX_LINES + 10, "every line is accounted for")
  expect.equal(storage.read(logrotate.PREVIOUS), text, "the previous generation is kept")
  expect.equal(storage.read(logrotate.PATH), "", "and the current log starts empty")
end)
