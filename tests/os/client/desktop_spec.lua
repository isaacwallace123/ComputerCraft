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
  local entries = apps("a", "b", "c", "d")
  local moved = desktop.swap(entries, 1, 4)

  expect.equal(ids(moved), "d,b,c,a")

  -- `reactive` compares by identity, so a list mutated in place is the same
  -- table it was: the value would be set, no listener would fire, and the icon
  -- would appear not to have moved.
  expect.truthy(moved ~= entries, "a copy")
  expect.equal(ids(entries), "a,b,c,d", "the original is intact")
end)

it("a swap with a cell that is not there changes nothing", function()
  expect.equal(ids(desktop.swap(apps("a", "b"), 2, 9)), "a,b")
end)

---------------------------------------------------------------------------
-- What is open
---------------------------------------------------------------------------

it("opening an app that is already open does not give it a second tab", function()
  local tabs = desktop.opened(desktop.opened({}, 3), 3)
  expect.equal(#tabs, 1)
  expect.equal(tabs[1], 3)
end)

it("tabs keep the order they were opened in", function()
  local tabs = desktop.opened(desktop.opened(desktop.opened({}, 5), 2), 9)

  -- Not sorted, and not most-recent-first. A strip that reordered itself as you
  -- used it would move the tab you were about to click.
  expect.equal(tabs[1], 5)
  expect.equal(tabs[2], 2)
  expect.equal(tabs[3], 9)
end)

it("closing takes one tab out and leaves the rest in place", function()
  local tabs = desktop.closed({ 5, 2, 9 }, 2)
  expect.equal(#tabs, 2)
  expect.equal(tabs[1], 5)
  expect.equal(tabs[2], 9)
end)

it("closing something that is not open is not a crash", function()
  expect.equal(#desktop.closed({ 5 }, 7), 1)
end)

---------------------------------------------------------------------------
-- The grid
---------------------------------------------------------------------------

it("what the tiles do not use is split, not left on the right", function()
  -- Four tiles of eleven with three gaps is forty-seven of fifty-one, so two
  -- cells each side. The bug this pins was a wall flush against the left edge
  -- with all four cells of slack piled on the right.
  local columns, tile, margin = desktop.grid(51)
  expect.equal(columns, 4)
  expect.equal(tile, 11)
  expect.equal(margin, 2)

  -- A pocket computer: two columns, and whatever is left over is still shared.
  local narrow, _, handheld = desktop.grid(26)
  expect.equal(narrow, 2)
  expect.equal(handheld, 1)
end)

it("the gap between rows is given up before the bottom row is", function()
  -- Three rows of four-high tiles plus the bar and the line under it is fifteen
  -- rows on a nineteen-row terminal, so the gaps fit.
  expect.equal(desktop.spacing(19, 11, 4), 1, "eleven apps still breathe")

  -- Sixteen apps is four rows, and the gaps no longer fit. Dropping them is the
  -- right answer; the wrong one is what happened before this function existed,
  -- where the bottom row went off the screen and read as the app not existing.
  expect.equal(desktop.spacing(19, 16, 4), 0)
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

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

--- Build one session's tree and render it. Returns nothing; it either throws or
--- it does not, which is the whole assertion.
local function draw(open, entries, options)
  options = options or {}
  local scope = ui.scoped()
  local state = {
    open = scope:Value(open),
    selected = scope:Value(1),
    holding = scope:Value(2),
    tick = scope:Value(0),
    tabs = options.tabs or {},
    wanted = scope:Value(nil),
    closing = scope:Value(nil),
  }

  local root = host.mount({
    screen = screenPort.null(51, 19),
    scope = scope,
    build = function(inner)
      return desktop.build(inner, options.context or {
        label = "test",
        clock = {
          now = function()
            return 0
          end,
          time = function()
            return 13.5
          end,
        },
      }, state, entries, {
        width = 51,
        height = 19,
        role = options.role,
        surface = options.surface,
      })
    end,
  })

  root:render()
  scope:destroy()
  return root
end

it("the wall draws, sprites and all", function()
  -- The one kind of test here that renders. Every other failure in this file is
  -- arithmetic; this one catches the class that arithmetic cannot - a bound
  -- property the runtime cannot resolve, a sprite that is nil where a node
  -- expects one, a layout that throws before anything reaches the screen.
  --
  -- That class has taken this system down twice in world, both times leaving a
  -- machine that looked hung on its splash while every service behind it ran.
  draw(nil, {
    page.fake("fleet", "Fleet", { "client" }, { "desktop" }),
    page.fake("bank", "Bank", { "client" }, { "desktop" }),
    -- An app with no picture of its own, which must fall back rather than hand
    -- the Sprite node a nil.
    page.fake("swarm", "Swarm", { "client" }, { "desktop" }),
  }, { tabs = { 2 } })
end)

it("an open app draws with the bar above it", function()
  draw(2, {
    page.fake("fleet", "Fleet", { "client" }, { "desktop" }),
    page.fake("bank", "Bank", { "client" }, { "desktop" }),
  }, { tabs = { 2 } })
end)

it("a machine with no world clock draws no time rather than midnight", function()
  local format = require("ui.format")

  -- Nil is a real answer - a spec, a simulated run, anything not in Minecraft -
  -- and "00:00" would be a time that is wrong rather than absent.
  expect.equal(format.clock(nil), "")
  expect.equal(format.clock(13.5), "13:30")
  expect.equal(format.clock(0), "00:00")

  -- Rounding the minutes can carry, and 13:60 is not a time.
  expect.equal(format.clock(13.999), "14:00")
  expect.equal(format.clock(24), "00:00", "the day wraps rather than clamping")
end)

it("the tab strip gives up its oldest rather than pushing the clock off", function()
  -- The bar used to grow until it ran off the right edge, taking the time with
  -- it - so the machine's own chrome became the one thing on screen that could
  -- not fit on screen. The newest tabs are kept, because the one you just opened
  -- is the one you are about to go back to.
  local entries = {}
  local tabs = {}
  for index = 1, 10 do
    entries[index] = page.fake("app" .. index, "App" .. index, { "client" }, { "desktop" })
    tabs[index] = index
  end

  -- It either draws inside its own width or it throws; a bar that overflowed
  -- silently is what this is here to catch.
  draw(nil, entries, { tabs = tabs })
end)

---------------------------------------------------------------------------
-- Sections
---------------------------------------------------------------------------

it("fleet, mine and automation are one app with three sections", function()
  -- They were separate icons, and setting up a mine meant crossing the home
  -- screen to do one thing. One is on the wall; the rest are reachable from a
  -- bar across the top of it. Job is not among them any more: a page whose only
  -- control was "pick a job" could leave the fleet configured and not sent, so
  -- it is a picker beside Deploy on Fleet instead.
  local appRegistry = require("apps.registry")

  local wall = appRegistry.available("server", "desktop")
  local names = {}
  for _, entry in ipairs(wall) do
    names[entry.id] = true
  end

  expect.truthy(names.fleet, "the section leader is on the wall")
  expect.falsy(names.operations, "and the other three are not")
  expect.falsy(names.automation)
  expect.equal(appRegistry.byId("job"), nil, "and Job is gone entirely")

  local family = appRegistry.family("operations", "server", "desktop")
  expect.equal(#family, 3, "but all three are reachable from the bar")
  expect.equal(family[1].id, "fleet", "with the leader first")

  for _, entry in ipairs(family) do
    expect.truthy(entry.sectionName ~= nil, entry.id .. " needs a short name for the bar")
    expect.truthy(#entry.sectionName <= 6, entry.id .. "'s bar label must fit beside three others")
  end
end)

it("a hidden section page is still reachable by id", function()
  -- The bar names its siblings by id because a hidden entry has no index on the
  -- wall - an index could never reach it.
  local appRegistry = require("apps.registry")

  expect.truthy(appRegistry.byId("automation"), "found by id")
  expect.equal(appRegistry.byId("automation").id, "automation")
  expect.equal(appRegistry.byId("nonesuch"), nil)

  local entries = appRegistry.available("server", "desktop")
  expect.equal(desktop.entryAt(entries, "automation").id, "automation", "resolved for the page body")
  expect.equal(desktop.entryAt(entries, 1), entries[1], "and an index still means the wall")
  expect.equal(desktop.entryAt(entries, nil), nil, "nil is the wall itself")
  expect.equal(desktop.entryAt(entries, "nonesuch"), nil, "a retired id is not a crash")
end)

it("every hidden app still ships, because the bar can open it", function()
  -- A page reachable from a bar and absent from the manifest is a page that
  -- opens into "could not load" on a real machine and never fails here.
  local appRegistry = require("apps.registry")
  local modules = {}
  for _, module in ipairs(appRegistry.modules()) do
    modules[module] = true
  end

  for _, entry in ipairs(appRegistry.family("operations", "server", "desktop")) do
    expect.truthy(modules[entry.module], entry.id .. " is in a section but not in modules()")
  end
end)

it("an open section page draws the bar that reaches its siblings", function()
  -- The bug this exists for drew nothing and reported nothing. `build` was
  -- called with a fresh options table that never carried `role`, so the section
  -- lookup defaulted to "client" - and Fleet is not a client app, so the family
  -- came back empty and the bar quietly did not render. Mine, Automation and
  -- Job became unreachable, with no error anywhere and a page that looked
  -- entirely normal.
  --
  -- A filter whose failure mode is an empty list needs a test that counts what
  -- reached the tree, not one that checks it did not throw.
  local appRegistry = require("apps.registry")
  local entries = appRegistry.available("server", "desktop")

  local index = nil
  for position, entry in ipairs(entries) do
    if entry.id == "fleet" then
      index = position
    end
  end
  expect.truthy(index ~= nil, "fleet is on a server's wall")

  local ctx = require("support.fleet").context()
  local context = ctx.context or ctx
  context.clock.time = context.clock.time or function()
    return 13.5
  end

  local scope = ui.scoped()
  local state = {
    open = scope:Value(index),
    selected = scope:Value(1),
    holding = scope:Value(nil),
    tick = scope:Value(0),
    tabs = { index },
    wanted = scope:Value(nil),
    closing = scope:Value(nil),
  }

  local tree = desktop.build(scope, context, state, entries, {
    width = 51,
    height = 19,
    role = "server",
    surface = "desktop",
  })

  local found = {}
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.Text) == "string" then
      found[(node.Text:gsub("%s", ""))] = true
    end
    for _, child in ipairs(node.Children or {}) do
      walk(child)
    end
  end
  walk(tree)
  scope:destroy()

  for _, entry in ipairs(appRegistry.family("operations", "server", "desktop")) do
    expect.truthy(found[entry.sectionName], entry.sectionName .. " is not on the section bar")
  end

  expect.truthy(found.x, "and every open tab has a close control")
end)
