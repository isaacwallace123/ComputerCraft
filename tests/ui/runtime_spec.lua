--- The node tree end to end: a state change in, terminal calls out.
---
--- These are the specs that decide whether the framework was worth building.
--- Section 12 of docs/ui-framework.md measures one changed label at one blit
--- and the same change through Basalt 2's design at 81; everything above the
--- renderer has to preserve that, and the way it gets lost is invalidating
--- upwards. The counts asserted here are the guard.

local expect = require("support.expect")
local it = require("support.spec").it

local recorder = require("adapters.sim.screen")
local ui = require("ui.init")

local T = ui.tokens

--- Mount a tree and settle it: one full frame, then forget the calls, so every
--- assertion below is about what the *second* frame cost.
local function mounted(build, width, height)
  local screen = recorder.new(width or 51, height or 19)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = build,
  })
  root:render()
  screen.forget()
  return root, screen, scope
end

---------------------------------------------------------------------------
-- The picture
---------------------------------------------------------------------------

it("a mounted tree paints where the layout put it", function()
  local screen = recorder.new(20, 5)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return s:Column({
        Padding = 1,
        Children = { s:Text({ Text = "ICOS" }) },
      })
    end,
  })
  root:render()

  expect.equal(screen.charAt(2, 2), "I", "inside the padding")
  expect.equal(screen.charAt(5, 2), "S", "and four cells long")
  expect.equal(screen.charAt(1, 1), " ", "the padding itself is blank")
  root:destroy()
end)

it("a component paints in its token colours", function()
  local screen = recorder.new(20, 3)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return s:Row({ Children = { s:Badge({ Text = "online", Tone = T.good }) } })
    end,
  })
  root:render()

  local fg, bg = screen.colourAt(3, 1)
  expect.equal(fg, ui.buffer.hex(T.good), "the tone it was given")
  expect.equal(bg, ui.buffer.hex(T.muted), "on the recessed chip")
  root:destroy()
end)

---------------------------------------------------------------------------
-- The budget
---------------------------------------------------------------------------

it("a settled screen costs nothing at all", function()
  local root, screen = mounted(function(s)
    return s:Column({ Children = { s:Text({ Text = "idle" }) } })
  end)

  expect.falsy(root:pending(), "nothing is scheduled")
  expect.equal(root:render(), 0, "and rendering does nothing")
  expect.equal(#screen.calls, 0, "no terminal calls")
  root:destroy()
end)

it("one changed label is one blit, and does not re-solve the layout", function()
  local label
  local root, screen, scope = mounted(function(s)
    label = s:Value("miner-3")
    return s:Column({
      Padding = 1,
      Children = {
        s:Text({ Text = "Fleet" }),
        s:Text({ Text = label }),
        s:Text({ Text = "6 devices" }),
      },
    })
  end, 51, 19)

  label:set("miner-4")
  local blits = root:render()

  -- This is the number the whole framework exists for. The same change through
  -- a design that invalidates the root frame costs 81 on a large monitor.
  expect.equal(blits, 1, "one blit")
  expect.equal(#screen.calls, 1, "one terminal call")
  expect.equal(screen.calls[1].text, "4", "carrying the one character that moved")
  root:destroy()
end)

it("a colour change repaints without re-measuring", function()
  local tone
  local root, screen = mounted(function(s)
    tone = s:Value(T.good)
    return s:Column({
      Padding = 1,
      -- An explicit width so the box is the text: a stretched Text fills its
      -- box, which is correct and would make this assertion about padding.
      Children = { s:Text({ Text = "mining", Color = tone, Width = 6 }) },
    })
  end)

  tone:set(T.destructive)
  local blits = root:render()

  expect.equal(blits, 1, "one row repainted")
  expect.equal(screen.calls[1].fg, string.rep(ui.buffer.hex(T.destructive), 6), "in the new colour")
  root:destroy()
end)

it("a change that resizes a node does re-solve the layout", function()
  local label
  local root, screen = mounted(function(s)
    label = s:Value("ok")
    return s:Row({
      Children = { s:Text({ Text = label }), s:Text({ Text = "after" }) },
    })
  end, 30, 3)

  -- "ok" to "stalled" is five cells wider, so everything to its right moves and
  -- the whole screen is repainted. That is the correct answer, and the cell diff
  -- still keeps it to the rows that actually differ.
  label:set("stalled")
  root:render()

  expect.equal(screen.rowText(1):sub(1, 12), "stalledafter", "the neighbour moved along")
  root:destroy()
end)

it("twenty changes between frames produce one frame", function()
  local values = {}
  local root, screen = mounted(function(s)
    local children = {}
    for index = 1, 20 do
      values[index] = s:Value(("row %d"):format(index))
      children[index] = s:Text({ Text = values[index], Width = 20 })
    end
    return s:Column({ Children = children })
  end, 51, 25)

  -- A heartbeat handler updating twenty devices must not produce twenty frames.
  -- Nothing painted until render is called, and then all twenty land together.
  for index = 1, 20 do
    values[index]:set(("row %d!"):format(index))
  end
  expect.equal(#screen.calls, 0, "setting a value paints nothing")

  local blits = root:render()
  expect.equal(blits, 20, "one blit per changed row, in a single frame")
  root:destroy()
end)

it("only the nodes that changed are repainted", function()
  local a, b
  local root, screen = mounted(function(s)
    a, b = s:Value("aaa"), s:Value("bbb")
    local children = {}
    for index = 1, 10 do
      children[index] = s:Text({ Text = ("static %d"):format(index), Width = 20 })
    end
    children[4] = s:Text({ Text = a, Width = 20 })
    children[9] = s:Text({ Text = b, Width = 20 })
    return s:Column({ Children = children })
  end, 51, 19)

  a:set("aaz")
  b:set("bbz")
  local blits = root:render()

  expect.equal(blits, 2, "two rows, not ten")
  root:destroy()
end)

it("a value set to what it already was schedules nothing", function()
  local label
  local root, screen = mounted(function(s)
    label = s:Value("parked")
    return s:Column({ Children = { s:Text({ Text = label }) } })
  end)

  label:set("parked")
  expect.falsy(root:pending(), "no frame scheduled")
  expect.equal(root:render(), 0, "and nothing drawn")
  root:destroy()
end)

it("a Computed that recomputes to the same text repaints nothing", function()
  -- The case that matters on a fleet dashboard: every heartbeat replaces the
  -- whole device list, so every cell's Computed is invalidated, and almost all
  -- of them format to the string they already had.
  local devices
  local root, screen = mounted(function(s)
    devices = s:Value({ { label = "miner-1", fuel = 51000 }, { label = "miner-2", fuel = 22000 } })
    local rows = {}
    for index = 1, 2 do
      rows[index] = s:Row({
        Children = {
          s:Text({
            Width = 12,
            Text = s:Computed(function(use)
              return use(devices)[index].label
            end),
          }),
          s:Text({
            Width = 8,
            Text = s:Computed(function(use)
              return ui.format.count(use(devices)[index].fuel)
            end),
          }),
        },
      })
    end
    return s:Column({ Children = rows })
  end)

  -- A fresh list with one number changed. Three of the four cells recompute to
  -- exactly what they held before.
  devices:set({ { label = "miner-1", fuel = 51000 }, { label = "miner-2", fuel = 21000 } })
  local blits = root:render()

  expect.equal(blits, 1, "one cell moved, so one blit")
  root:destroy()
end)

---------------------------------------------------------------------------
-- Lifetime
---------------------------------------------------------------------------

it("destroying a root stops its bindings and leaves nothing alive", function()
  local host = ui.scoped()
  local shared = host:Value("first")
  local baseline = ui.live()

  for _ = 1, 5 do
    local screen = recorder.new(20, 3)
    local scope = ui.scoped()
    local root = ui.mount({
      scope = scope,
      screen = screen.port,
      build = function(s)
        return s:Column({ Children = { s:Text({ Text = shared }) } })
      end,
    })
    root:render()
    root:destroy()
  end

  shared:set("after")
  expect.equal(ui.live(), baseline, "five screens opened and closed leave nothing behind")
  host:destroy()
end)

---------------------------------------------------------------------------
-- Composites
---------------------------------------------------------------------------

it("a Page lays out its title, body and actions", function()
  local screen = recorder.new(40, 12)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return s:Page({
        Title = "Fleet",
        Status = "4 of 6 online",
        Children = { s:Text({ Text = "body" }) },
        Actions = { s:Button({ Text = "Deploy", Variant = "primary" }) },
      })
    end,
  })
  root:render()

  expect.equal(screen.rowText(2):sub(3, 7), "Fleet", "the title, indented")
  expect.contains(screen.rowText(2), "4 of 6 online", "and the status, right-aligned")
  -- Row 3 is the separator and row 4 is the body's top padding, so the content
  -- starts at 5. The blank row is the point: it is the breathing space that
  -- replaces a drawn border.
  expect.contains(screen.rowText(5), "body", "the body below the separator")
  expect.contains(screen.rowText(12), "Deploy", "and the action row at the bottom")
  root:destroy()
end)

it("a Table shows a fixed pool of slots over a changing list", function()
  local devices
  local screen = recorder.new(40, 10)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      devices = s:Value({ { label = "miner-1" }, { label = "miner-2" } })
      return s:Table({
        Rows = devices,
        Capacity = 3,
        Columns = { { Title = "Device", Key = "label", Width = 12 } },
      })
    end,
  })
  root:render()

  expect.contains(screen.rowText(1), "DEVICE", "the heading is upper case")
  expect.contains(screen.rowText(3), "miner-1", "first slot")
  expect.contains(screen.rowText(4), "miner-2", "second slot")
  expect.falsy(screen.rowText(5):find("miner"), "the empty slot stays blank")

  -- A device leaving the roster does not destroy a row; it changes what a cell
  -- says. That is what keeps the binding graph stable across a heartbeat.
  screen.forget()
  devices:set({ { label = "miner-9" }, { label = "miner-2" } })
  local blits = root:render()
  expect.equal(blits, 1, "one cell changed")
  expect.contains(screen.rowText(3), "miner-9", "and shows the new value")

  root:destroy()
end)

---------------------------------------------------------------------------
-- A whole screen
---------------------------------------------------------------------------

it("the Fleet screen renders, and a heartbeat costs one blit per changed cell", function()
  local fleetScreen = require("apps.fleet.view")

  local function roster(fuel2, phase3)
    return {
      {
        id = 1,
        label = "miner-1",
        phase = "mining",
        fuel = 51000,
        fuelLimit = 100000,
        online = true,
      },
      {
        id = 2,
        label = "miner-2",
        phase = "returning",
        fuel = fuel2,
        fuelLimit = 100000,
        online = true,
      },
      {
        id = 3,
        label = "miner-3",
        phase = phase3,
        fuel = 47800,
        fuelLimit = 100000,
        online = true,
      },
      {
        id = 4,
        label = "miner-4",
        phase = "parked",
        fuel = 640,
        fuelLimit = 100000,
        online = false,
      },
    }
  end

  local screen = recorder.new(51, 19)
  local scope = ui.scoped()
  local devices, selected
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      devices = s:Value(roster(12400, "unloading"))
      selected = s:Value(nil)
      return fleetScreen.build(s, {
        devices = devices,
        selected = selected,
        capacity = 8,
        onDeploy = function() end,
        onRecall = function() end,
        onStop = function() end,
      })
    end,
  })
  root:render()

  expect.contains(screen.rowText(2), "Fleet", "the title")
  expect.contains(screen.rowText(2), "4 known", "and the derived count")
  expect.contains(screen.rowText(19), "Deploy all", "actions at the foot")

  -- Rows 1-2 are the header, 3 the separator, 4 the body's top padding, 5 the
  -- column headings and 6 the gap under them, so the roster starts at 7.
  local rows = {}
  for row = 5, 15 do
    rows[#rows + 1] = screen.rowText(row)
  end
  local body = table.concat(rows, " ")
  expect.contains(body, "miner-1", "the roster is listed")
  expect.contains(body, "miner-4", "all of it")

  -- One turtle burns fuel and another finishes unloading. Everything else on the
  -- page recomputes to exactly what it held before.
  --
  -- One blit, not two. The fuel meter used to be a column and is now in the
  -- detail panel, which shows the selected device - and nothing is selected
  -- here, so a fuel reading changing is a value nothing on screen is displaying.
  -- The property is unchanged and is the point: a heartbeat costs one blit per
  -- run of cells that actually moved, however many values arrived.
  screen.forget()
  devices:set(roster(12300, "mining"))
  local blits = root:render()
  expect.equal(blits, 1, "one run moved, so one blit")

  -- Selecting a row is a highlight and a panel, not a relayout. The row's own
  -- runs change and the detail beside it fills in - which is more cells than the
  -- old Fleet page touched, because that page had nothing to fill.
  --
  -- What is being pinned is that it stays proportional to what changed rather
  -- than repainting the screen: a 51x19 page is 969 cells, and this is a
  -- fraction of one column plus one row.
  screen.forget()
  selected:set(3)
  root:render()
  expect.truthy(#screen.calls > 0, "something was drawn")
  expect.truthy(#screen.calls < 20, "and it was the row and its panel, not the page")

  root:destroy()
end)

it("a display-only surface simply has no actions", function()
  -- D020's requiresInput boundary, expressed as an absent argument rather than a
  -- branch inside the view. A monitor mounts the same screen and there is no
  -- code path that could put a recall button on it.
  local fleetScreen = require("apps.fleet.view")
  local screen = recorder.new(51, 19)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return fleetScreen.build(s, {
        devices = s:Value({
          { id = 1, label = "miner-1", phase = "mining", fuel = 100, online = true },
        }),
        selected = s:Value(nil),
        capacity = 4,
      })
    end,
  })
  root:render()

  for row = 1, 19 do
    expect.falsy(screen.rowText(row):find("Deploy"), "no action row on a display-only surface")
  end
  root:destroy()
end)

it("phase tones say what a state means, not what it looks like", function()
  local fleetScreen = require("apps.fleet.view")
  expect.equal(fleetScreen.phaseTone({ phase = "mining" }), T.good, "working is good")
  expect.equal(fleetScreen.phaseTone({ phase = "parked" }), T.mutedFg, "parked is neither")
  expect.equal(
    fleetScreen.phaseTone({ phase = "mining", stuck = true }),
    T.destructive,
    "stuck is bad"
  )
  expect.equal(fleetScreen.phaseTone({ phase = "reticulating" }), T.warn, "an unknown phase warns")
  expect.equal(fleetScreen.phaseTone(nil), T.mutedFg, "an empty slot is muted")
end)
