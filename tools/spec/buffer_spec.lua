--- The cell buffer, its diff, and the terminal traffic it actually produces.
---
--- These are the first specs in this repository that need no world at all. The
--- renderer talks to a screen port and nothing else, so a recording port is a
--- complete substitute for a monitor - which is the point docs/ui-framework.md
--- makes about `ports/screen` and the reason phase 1 built it first.
---
--- Two things get asserted throughout, and they are not the same thing. The cell
--- grid says the picture is right. The call count says it was arrived at
--- cheaply. A renderer can pass either one alone by being wrong in a way the
--- other would catch.

local expect = require("support.expect")
local it = require("support.spec").it

local buffer = require("ui.core.buffer")
local recorder = require("adapters.sim.screen")

local WHITE, BLACK = 0, 15

--- A buffer over a fresh recording screen, already presented once so the front
--- buffer matches the picture. Every test here is about the SECOND frame; the
--- first is always a full repaint by construction, because a new buffer cannot
--- know what was on the terminal before it existed.
local function settled(width, height)
  local screen = recorder.new(width, height)
  local frame = buffer.new(screen.port)
  frame:clear(WHITE, BLACK)
  frame:present()
  screen.forget()
  return frame, screen
end

---------------------------------------------------------------------------
-- The three budget properties
---------------------------------------------------------------------------

it("an unchanged frame emits no terminal calls at all", function()
  local frame, screen = settled(51, 19)

  -- Repaint every row with exactly what is already there. The rows are all
  -- marked dirty, so the diff genuinely runs - it just finds nothing.
  frame:clear(WHITE, BLACK)
  frame:write(3, 5, "miner-7  mining", WHITE, BLACK)
  frame:present()
  screen.forget()

  frame:clear(WHITE, BLACK)
  frame:write(3, 5, "miner-7  mining", WHITE, BLACK)
  local blits = frame:present()

  expect.equal(blits, 0, "blits from an identical frame")
  expect.equal(#screen.calls, 0, "terminal calls from an identical frame")
end)

it("a one-character change emits exactly one blit of one character", function()
  local frame, screen = settled(51, 19)

  frame:write(3, 5, "fuel 51000", WHITE, BLACK)
  frame:present()
  screen.forget()

  frame:write(3, 5, "fuel 51001", WHITE, BLACK)
  local blits = frame:present()

  expect.equal(blits, 1, "blits")
  expect.equal(#screen.calls, 1, "terminal calls")

  local call = screen.calls[1]
  expect.equal(call.kind, "blit", "call kind")
  expect.equal(call.text, "1", "only the changed character is sent")
  expect.equal(call.x, 12, "at the column that changed")
  expect.equal(call.y, 5, "on the row that changed")
end)

it("a full-screen change emits at most one blit per row", function()
  local frame, screen = settled(164, 81)

  for y = 1, 81 do
    -- Padded by hand: Lua caps a format spec's width at two digits, which is
    -- the same reason `legacy/shell/ui.lua` grew a `pad` helper.
    -- A different background as well as different text, so every cell on every
    -- row genuinely differs. Repainting the same text on the same background
    -- would leave the trailing spaces identical and the runs correspondingly
    -- shorter, which is a weaker test than the one this is meant to be.
    local text = ("row %d of the fleet table"):format(y)
    frame:write(1, y, text .. string.rep(" ", 164 - #text), WHITE, 7)
  end
  local blits = frame:present()

  expect.equal(blits, 81, "one blit per row, and no more")
  expect.equal(#screen.calls, 81, "terminal calls")
  for _, call in ipairs(screen.calls) do
    expect.equal(#call.text, 164, "each row goes in one full-width run")
  end
end)

---------------------------------------------------------------------------
-- The picture
---------------------------------------------------------------------------

it("what is presented is what lands in the cells", function()
  local frame, screen = settled(51, 19)

  frame:write(4, 2, "ICOS", 3, 8)
  frame:present()

  expect.equal(screen.charAt(4, 2), "I", "first character")
  expect.equal(screen.charAt(7, 2), "S", "last character")
  expect.equal(screen.charAt(3, 2), " ", "nothing written before it")
  expect.equal(screen.charAt(8, 2), " ", "nothing written after it")

  local fg, bg = screen.colourAt(5, 2)
  expect.equal(fg, "3", "foreground as a blit digit")
  expect.equal(bg, "8", "background as a blit digit")
end)

it("per-character colours survive the round trip", function()
  local frame, screen = settled(51, 19)

  frame:blit(1, 1, "abcd", "0123", "ffee")
  frame:present()

  expect.equal(screen.rowText(1):sub(1, 4), "abcd", "text")
  local fg, bg = screen.colourAt(3, 1)
  expect.equal(fg, "2", "third foreground")
  expect.equal(bg, "e", "third background")
end)

it("the buffer can be asked what it holds without a screen", function()
  local frame = settled(51, 19)

  frame:write(10, 4, "ore", 5, 9)

  local char, fg, bg = frame:get(10, 4)
  expect.equal(char, "o", "character")
  expect.equal(fg, 5, "foreground index")
  expect.equal(bg, 9, "background index")

  expect.equal(frame:get(200, 4), nil, "off the right-hand edge")
  expect.equal(frame:get(10, 99), nil, "below the last row")
end)

---------------------------------------------------------------------------
-- Coalescing, which is what makes the whole thing worth having
---------------------------------------------------------------------------

it("several changes on one row become a single run", function()
  local frame, screen = settled(51, 19)

  frame:write(1, 8, string.rep(".", 51), WHITE, BLACK)
  frame:present()
  screen.forget()

  -- Two widgets on the same row update independently, as they would in a table.
  frame:write(5, 8, "AA", WHITE, BLACK)
  frame:write(30, 8, "BB", WHITE, BLACK)
  local blits = frame:present()

  expect.equal(blits, 1, "one call, not one per widget")
  local call = screen.calls[1]
  expect.equal(call.x, 5, "spanning from the first change")
  expect.equal(#call.text, 27, "to the last")
  expect.contains(call.text, "AA", "carrying the first change")
  expect.contains(call.text, "BB", "and the second")
end)

it("changes on different rows stay separate", function()
  local frame, screen = settled(51, 19)

  frame:write(1, 3, "one", WHITE, BLACK)
  frame:write(1, 9, "two", WHITE, BLACK)
  local blits = frame:present()

  expect.equal(blits, 2, "one per touched row")
end)

it("a colour change with no text change still repaints", function()
  local frame, screen = settled(51, 19)

  frame:write(2, 6, "recall", WHITE, BLACK)
  frame:present()
  screen.forget()

  frame:write(2, 6, "recall", 14, BLACK)
  local blits = frame:present()

  expect.equal(blits, 1, "the row is repainted")
  expect.equal(screen.calls[1].fg, "eeeeee", "with the new foreground")
end)

---------------------------------------------------------------------------
-- Edges
---------------------------------------------------------------------------

it("writes off the edges are clipped, not errors", function()
  local frame, screen = settled(20, 5)

  frame:write(-2, 1, "abcdef", WHITE, BLACK)
  frame:write(18, 2, "abcdef", WHITE, BLACK)
  frame:write(1, 99, "nowhere", WHITE, BLACK)
  frame:write(99, 1, "nowhere", WHITE, BLACK)
  frame:present()

  expect.equal(screen.rowText(1):sub(1, 4), "def ", "the left overhang is trimmed")
  expect.equal(screen.rowText(2), "                 abc", "the right overhang is trimmed")
end)

it("a mismatched blit is refused rather than drawn crooked", function()
  local frame = settled(20, 5)

  local ok, err = pcall(function()
    frame:blit(1, 1, "abc", "00", "fff")
  end)
  expect.falsy(ok, "short colour strings are rejected")
  expect.contains(err, "blit at 1,1", "and the error says where")
end)

it("invalidate forces a repaint of an unchanged picture", function()
  local frame, screen = settled(51, 19)

  frame:write(1, 1, "unchanged", WHITE, BLACK)
  frame:present()
  screen.forget()

  expect.equal(frame:present(), 0, "nothing to do yet")

  frame:invalidate()
  local blits = frame:present()
  expect.equal(blits, 19, "every row is redrawn")
end)

it("a resize keeps the content that still fits and repaints all of it", function()
  local screen = recorder.new(51, 19)
  local frame = buffer.new(screen.port)
  frame:clear(WHITE, BLACK)
  frame:write(1, 2, "kept", WHITE, BLACK)
  frame:present()
  screen.forget()

  expect.truthy(frame:resize(30, 10), "the resize is reported")
  local width, height = frame:size()
  expect.equal(width, 30, "new width")
  expect.equal(height, 10, "new height")
  expect.equal(frame:get(1, 2), "k", "content inside the new bounds survives")

  local blits = frame:present()
  expect.equal(blits, 10, "and every row is repainted, because the game cleared it")

  expect.falsy(frame:resize(30, 10), "resizing to the same size is a no-op")
end)

---------------------------------------------------------------------------
-- The port contract itself
---------------------------------------------------------------------------

it("an adapter missing a method is rejected where it is built", function()
  local screen = require("ports.screen")

  local ok, err = pcall(function()
    screen.check({ size = function() end })
  end)
  expect.falsy(ok, "an incomplete screen is not a screen")
  expect.contains(err, "port screen: missing method", "and the error names the port")
end)

it("null ports answer instead of raising", function()
  local screen = require("ports.screen").null(80, 24)
  local width, height = screen.size()
  expect.equal(width, 80, "null screens still have a size")
  expect.equal(height, 24, "so layout code needs no headless branch")

  local storage = require("ports.storage").null()
  expect.equal(storage.read("/anything"), nil, "a null read finds nothing")
  expect.truthy(storage.write("/anything", "x"), "a null write succeeds and forgets")

  local body = require("ports.body").null()
  local moved, reason = body.move("forward")
  expect.falsy(moved, "a computer with no turtle hardware refuses to move")
  expect.contains(reason, "no turtle hardware", "and says why")
end)
