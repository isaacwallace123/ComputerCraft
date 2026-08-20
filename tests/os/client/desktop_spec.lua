--- Arranging the wall of icons, and the two silent ways it can go wrong.
---
--- The layout functions are pure and are tested here without a screen, because
--- the failures worth catching do not look like failures: an uninstalled app
--- holding a cell draws a hole, and a newly added app that never gets a cell
--- draws nothing at all. Neither errors, and neither is visible in a screenshot
--- unless you already knew to count.

local expect = require("support.expect")
local it = require("support.spec").it
local page = require("support.page")

local desktop = require("os.client.desktop")
local host = require("ui.host")
local screenPort = require("ports.screen")
local ui = require("ui.init")

--- Apps, reduced to the only field the layout code reads.
local function apps(...)
  local out = {}
  for _, id in ipairs({ ... }) do
    out[#out + 1] = { manifest = { id = id, name = id } }
  end
  return out
end

local function ids(entries)
  local out = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = entry.manifest.id
  end
  return table.concat(out, ",")
end

it("a saved arrangement is honoured", function()
  local entries = apps("fleet", "devices", "bank")
  expect.equal(ids(desktop.arrange(entries, { "bank", "fleet", "devices" })), "bank,fleet,devices")
end)

it("an app that was added lands at the end rather than nowhere", function()
  local entries = apps("fleet", "devices", "bank")

  -- The arrangement was saved before Bank existed. A layout that only drew what
  -- it had been told about would hide the new app completely, and the person
  -- looking for it has no reason to suspect their own desktop file.
  expect.equal(ids(desktop.arrange(entries, { "devices", "fleet" })), "devices,fleet,bank")
end)

it("an app that no longer exists does not hold a cell", function()
  local entries = apps("fleet", "bank")
  expect.equal(ids(desktop.arrange(entries, { "swarm", "bank", "fleet" })), "bank,fleet")
end)

it("a duplicate in a saved arrangement is not drawn twice", function()
  local entries = apps("fleet", "bank")
  expect.equal(ids(desktop.arrange(entries, { "fleet", "fleet", "bank" })), "fleet,bank")
end)

it("no arrangement leaves the declared order alone", function()
  local entries = apps("fleet", "devices")
  expect.equal(desktop.arrange(entries, nil), entries, "the same list, untouched")
end)

it("a swap returns a new list, because nothing redraws otherwise", function()
  local layout = { 1, 2, 3, 4 }
  local moved = desktop.swap(layout, 1, 4)

  expect.equal(moved[1], 4)
  expect.equal(moved[4], 1)
  expect.equal(moved[2], 2, "and nothing else slid")

  -- `reactive` compares by identity, so a list mutated in place is the same
  -- table it was: the value would be set, no listener would fire, and the icon
  -- would appear not to have moved.
  expect.truthy(moved ~= layout, "a copy")
  expect.equal(layout[1], 1, "the original is intact")
end)

it("a swap with a cell that is not there changes nothing", function()
  local moved = desktop.swap({ 1, 2 }, 2, 9)
  expect.equal(moved[1], 1)
  expect.equal(moved[2], 2)
end)

it("the gap between rows is given up before the bottom row is", function()
  -- Three rows of four-high tiles plus the bar and the hint is seventeen rows on
  -- a nineteen-row terminal, so the gaps fit.
  expect.equal(desktop.spacing(19, 11, 4), 1, "eleven apps still breathe")

  -- Sixteen apps is four rows, and the gaps no longer fit. Dropping them is the
  -- right answer; the wrong one is what happened before this function existed,
  -- where the bottom row went off the screen and read as the app not existing.
  expect.equal(desktop.spacing(19, 16, 4), 0)

  -- A pocket computer: two columns, twenty rows, and the same arithmetic.
  expect.equal(desktop.spacing(20, 4, 2), 1)
end)

it("the whole desktop draws, sprites and all", function()
  -- The one test here that renders. Every other failure in this file is
  -- arithmetic; this one catches the class that arithmetic cannot - a bound
  -- property the runtime cannot resolve, a sprite that is nil where a node
  -- expects one, a layout that throws before anything reaches the screen.
  --
  -- That class has taken this system down twice in world, both times leaving a
  -- machine that looked hung on its splash while every service behind it ran.
  local scope = ui.scoped()
  local state = {
    selected = scope:Value(1),
    open = scope:Value(nil),
    tick = scope:Value(0),
    layout = scope:Value({ 1, 2, 3 }),
    holding = scope:Value(2),
  }

  local entries = {
    page.fake("fleet", "Fleet", { "client" }, { "desktop" }),
    page.fake("bank", "Bank", { "client" }, { "desktop" }),
    -- An app with no picture of its own, which must fall back rather than hand
    -- the Sprite node a nil.
    page.fake("swarm", "Swarm", { "client" }, { "desktop" }),
  }

  local screen = screenPort.null(51, 19)
  local root = host.mount({
    screen = screen,
    scope = scope,
    build = function(inner)
      return desktop.build(inner, { label = "test" }, state, entries, {
        width = 51,
        height = 19,
      })
    end,
  })

  root:render()

  -- And again with the carried icon somewhere else, because a move is the one
  -- interaction that changes what every tile is bound to.
  state.layout:set(desktop.swap({ 1, 2, 3 }, 2, 3))
  state.holding:set(3)
  root:render()

  scope:destroy()
end)

it("moving the selection stays on the grid", function()
  -- Eleven apps in four columns is three rows, the last of which has three.
  expect.equal(desktop.move(1, 11, 4, -1, 0), 1, "clamped at the left edge")
  expect.equal(desktop.move(4, 11, 4, 1, 0), 4, "and at the right")
  expect.equal(desktop.move(1, 11, 4, 0, -1), 1, "and at the top")

  -- Down from the last column of the second row lands on a cell that does not
  -- exist in the third, so it clamps to the last app rather than to nothing.
  expect.equal(desktop.move(8, 11, 4, 0, 1), 11)
end)
