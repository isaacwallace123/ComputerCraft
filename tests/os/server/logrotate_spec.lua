local expect = require("support.expect")
local it = require("support.spec").it
local fleet = require("support.fleet")

local logrotate = require("os.server.services.logrotate")

local logContext = fleet.logs

---------------------------------------------------------------------------
-- Logrotate: the machine that is never rebooted is the one that never trimmed
---------------------------------------------------------------------------

it("a short log is left alone", function()
  local ctx = logContext("one\ntwo\nthree\n")
  expect.equal(logrotate.rotate(ctx), 0, "nothing to do")
  expect.equal(ctx.files[logrotate.PATH], "one\ntwo\nthree\n", "and it is untouched")
  expect.falsy(ctx.files[logrotate.PREVIOUS], "no previous generation invented")
end)

it("a full log is moved aside rather than truncated", function()
  -- When something breaks at 3am and is noticed at 9am, the interesting lines
  -- are the first ones after it started. Truncation keeps six hours of
  -- consequences and deletes the cause.
  local lines = {}
  for i = 1, logrotate.MAX_LINES do
    lines[i] = "line " .. i
  end
  local text = table.concat(lines, "\n") .. "\n"

  local ctx = logContext(text)
  expect.equal(logrotate.rotate(ctx), logrotate.MAX_LINES, "rotated the whole file")
  expect.equal(ctx.files[logrotate.PATH], "", "a fresh log")
  expect.contains(ctx.files[logrotate.PREVIOUS], "line 1", "and the cause survived")
  expect.contains(ctx.files[logrotate.PREVIOUS], "line " .. logrotate.MAX_LINES, "with the rest")
end)

it("a log that cannot be moved is not cleared", function()
  -- A full or read-only disk is exactly what this service exists for, and
  -- exactly when clearing the current log would destroy the evidence of it.
  local text = string.rep("line\n", logrotate.MAX_LINES)
  local ctx = logContext(text)
  ctx.storage.write = function(path, value)
    if path == logrotate.PREVIOUS then
      return false
    end
    ctx.files[path] = value
    return true
  end

  expect.equal(logrotate.rotate(ctx), 0, "reported as not done")
  expect.equal(ctx.files[logrotate.PATH], text, "and nothing was lost")
end)

it("a last line with no newline still counts", function()
  expect.equal(logrotate.lines("a\nb"), 2, "two lines")
  expect.equal(logrotate.lines("a\nb\n"), 2, "the same two")
  expect.equal(logrotate.lines(""), 0, "and an empty file is empty")
  expect.equal(logrotate.lines(nil), 0, "as is a missing one")
end)
