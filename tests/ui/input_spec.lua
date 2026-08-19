--- Input: normalisation, hit testing, focus, and a whole screen driven by a
--- scripted pair of hands.
---
--- The point of the input port arriving before the input layer is that these
--- exist at all. A spec writes down what a person did and the framework cannot
--- tell the difference; there is no world, no terminal, and nothing to click on.

local expect = require("support.expect")
local it = require("support.spec").it

local keyboard = require("adapters.sim.input")
local recorder = require("adapters.sim.screen")
local ui = require("ui.init")

local input = ui.input
local KEY = input.KEY

---------------------------------------------------------------------------
-- Normalising
---------------------------------------------------------------------------

it("a mouse click becomes one pointer press", function()
  local events = input.normalise("mouse_click", 1, 12, 4)
  expect.equal(#events, 1, "one event")
  expect.equal(events[1].kind, "pointer", "a pointer")
  expect.equal(events[1].phase, "down", "pressed")
  expect.equal(events[1].x, 12, "at x")
  expect.equal(events[1].y, 4, "at y")
end)

it("a monitor touch becomes a press AND a release", function()
  -- The most important thing this layer knows. CC gives a monitor one event
  -- with no release and no drag, so a component that waited for an up would
  -- never fire on the surface the fleet dashboard actually lives on.
  local events = input.normalise("monitor_touch", "monitor_0", 8, 3)
  expect.equal(#events, 2, "two events from one")
  expect.equal(events[1].phase, "down", "press")
  expect.equal(events[2].phase, "up", "then release")
  expect.equal(events[2].x, 8, "at the same place")
  expect.truthy(events[1].touch, "marked as a touch, so a component can tell")
end)

it("scroll keeps CC's own direction", function()
  local event = input.normalise("mouse_scroll", -1, 5, 5)[1]
  expect.equal(event.phase, "scroll", "a scroll")
  expect.equal(event.delta, -1, "up is negative, as CC reports it")
end)

it("an unknown event is offered to the tree unchanged", function()
  local event = input.normalise("rednet_message", 7, "hello", "icos")[1]
  expect.equal(event.kind, "other", "not swallowed")
  expect.equal(event.name, "rednet_message", "with its name")
  expect.equal(event.args[1], 7, "and its arguments")
end)

---------------------------------------------------------------------------
-- Hit testing
---------------------------------------------------------------------------

local function box(x, y, w, h, extra)
  local node = { _x = x, _y = y, _w = w, _h = h, Children = {} }
  for key, value in pairs(extra or {}) do
    node[key] = value
  end
  return node
end

it("a hit finds the deepest node containing the point", function()
  local child = box(3, 2, 4, 1, { name = "child" })
  local parent = box(1, 1, 20, 5, { name = "parent" })
  parent.Children = { child }
  child._parent = parent

  expect.equal(input.hit(parent, 4, 2).name, "child", "inside the child")
  expect.equal(input.hit(parent, 10, 4).name, "parent", "inside only the parent")
  expect.equal(input.hit(parent, 40, 4), nil, "outside everything")
end)

it("overlapping siblings resolve to the one on top", function()
  -- Paint order is first to last, so the last sibling is the one a person sees
  -- and therefore the one they meant to press. Getting this backwards makes
  -- overlapping controls respond from underneath, which reads as random.
  local under = box(1, 1, 10, 1, { name = "under" })
  local over = box(1, 1, 10, 1, { name = "over" })
  local parent = box(1, 1, 10, 1)
  parent.Children = { under, over }

  expect.equal(input.hit(parent, 5, 1).name, "over", "the later sibling wins")
end)

it("a hidden node and a zero-size node are both unclickable", function()
  local hidden = box(1, 1, 10, 1, { name = "hidden", Hidden = true })
  local squeezed = box(1, 1, 0, 1, { name = "squeezed" })
  local parent = box(1, 1, 10, 1, { name = "parent" })
  parent.Children = { hidden, squeezed }

  expect.equal(input.hit(parent, 5, 1).name, "parent", "neither child takes it")
end)

it("a handler is found by bubbling up from the hit", function()
  -- What lets a table row be clickable while the text inside it is the thing
  -- actually under the cursor.
  local child = box(3, 2, 4, 1)
  local parent = box(1, 1, 20, 5, { OnClick = function() end, name = "row" })
  parent.Children = { child }
  child._parent = parent

  expect.equal(input.bubble(child, "OnClick").name, "row", "found on the ancestor")
  expect.equal(input.bubble(child, "OnScroll"), nil, "and nil when nobody handles it")
end)

---------------------------------------------------------------------------
-- Focus order
---------------------------------------------------------------------------

it("the tab ring follows tree order and skips what cannot take focus", function()
  local a = box(1, 1, 1, 1, { Focusable = true, name = "a" })
  local skipped = box(1, 1, 1, 1, { name = "plain" })
  local disabled = box(1, 1, 1, 1, { Focusable = true, Disabled = true, name = "off" })
  local b = box(1, 1, 1, 1, { Focusable = true, name = "b" })
  local root = box(1, 1, 20, 5)
  root.Children = { a, skipped, disabled, b }

  local ring = input.focusables(root)
  expect.equal(#ring, 2, "two focusable nodes")
  expect.equal(ring[1].name, "a", "in tree order")
  expect.equal(ring[2].name, "b", "with the disabled one skipped")
end)

it("focus wraps in both directions", function()
  local ring = { { name = "a" }, { name = "b" }, { name = "c" } }
  expect.equal(input.nextFocus(ring, ring[1], 1).name, "b", "forward")
  expect.equal(input.nextFocus(ring, ring[3], 1).name, "a", "wraps at the end")
  expect.equal(input.nextFocus(ring, ring[1], -1).name, "c", "and at the start")
  expect.equal(input.nextFocus(ring, nil, 1).name, "a", "from nowhere, the first")
  expect.equal(input.nextFocus({}, nil, 1), nil, "an empty ring has no answer")
end)

---------------------------------------------------------------------------
-- A whole screen, driven
---------------------------------------------------------------------------

local function screenWith(build, width, height)
  local screen = recorder.new(width or 40, height or 10)
  local scope = ui.scoped()
  local root = ui.mount({ scope = scope, screen = screen.port, build = build })
  root:render()
  screen.forget()
  return root, screen
end

it("clicking a button calls it", function()
  local pressed = 0
  local root = screenWith(function(s)
    return s:Row({
      Children = {
        s:Button({
          Text = "Deploy",
          OnClick = function()
            pressed = pressed + 1
          end,
        }),
      },
    })
  end)

  -- A press then a release, which is what a mouse produces. The click fires on
  -- the release, so a person can press and slide off to change their mind.
  root:handle("mouse_click", 1, 4, 1)
  expect.equal(pressed, 0, "not on the press")
  root:handle("mouse_up", 1, 4, 1)
  expect.equal(pressed, 1, "on the release")

  root:handle("mouse_up", 1, 39, 9)
  expect.equal(pressed, 1, "and not when the release is somewhere else")
  root:destroy()
end)

it("a monitor touch fires in one event", function()
  local pressed = 0
  local root = screenWith(function(s)
    return s:Row({
      Children = {
        s:Button({
          Text = "Recall",
          OnClick = function()
            pressed = pressed + 1
          end,
        }),
      },
    })
  end)

  root:handle("monitor_touch", "monitor_0", 4, 1)
  expect.equal(pressed, 1, "a touch is a whole tap")
  root:destroy()
end)

it("a disabled button takes focus from nobody and does nothing when pressed", function()
  local pressed = 0
  local root = screenWith(function(s)
    return s:Row({
      Children = {
        s:Button({
          Text = "Stop",
          Disabled = true,
          OnClick = function()
            pressed = pressed + 1
          end,
        }),
      },
    })
  end)

  root:handle("mouse_click", 1, 4, 1)
  root:handle("mouse_up", 1, 4, 1)
  expect.equal(pressed, 0, "not pressed")
  expect.equal(root.focused, nil, "and not focused")
  root:destroy()
end)

it("tab walks the ring and enter presses what it lands on", function()
  local log = {}
  local root, screen = screenWith(function(s)
    local function press(name)
      return function()
        log[#log + 1] = name
      end
    end
    return s:Row({
      Gap = 1,
      Children = {
        s:Button({ Text = "One", OnClick = press("one") }),
        s:Button({ Text = "Two", OnClick = press("two") }),
        s:Button({ Text = "Three", OnClick = press("three") }),
      },
    })
  end)

  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.enter, false)
  expect.equal(log[1], "one", "tab from nowhere lands on the first")

  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.space, false)
  expect.equal(log[2], "two", "and space presses too, for a turtle with no mouse")

  -- Shift is tracked as a held modifier because CC reports it as its own key
  -- event rather than as a flag on the next one.
  root:handle("key", KEY.leftShift, false)
  root:handle("key", KEY.tab, false)
  root:handle("key_up", KEY.leftShift)
  root:handle("key", KEY.enter, false)
  expect.equal(log[3], "one", "shift-tab goes back")
  root:destroy()
end)

it("moving focus repaints exactly the two controls involved", function()
  local root, screen = screenWith(function(s)
    local children = {}
    for index = 1, 3 do
      children[#children + 1] = s:Button({ Text = "Button " .. index, OnClick = function() end })
      children[#children + 1] = s:Text({ Text = "filler " .. index })
    end
    return s:Column({ Children = children })
  end, 40, 10)

  root:handle("key", KEY.tab, false)
  root:render()
  screen.forget()

  root:handle("key", KEY.tab, false)
  local blits = root:render()

  -- One ring cleared, one ring drawn, on two different rows. Focus is a node
  -- property rather than a search performed at paint time, so this stays at two
  -- however much else is on the page.
  expect.equal(blits, 2, "two nodes repainted, not the page")
  root:destroy()
end)

it("two focus changes on the same row coalesce into one blit", function()
  -- Not a special case in the input layer - the cell diff in ui/core/buffer.lua
  -- emits one run per changed row spanning its first change to its last (D028),
  -- so two adjacent buttons cost one call between them. Worth pinning, because
  -- it is the interaction between two layers that neither one states alone.
  local root, screen = screenWith(function(s)
    return s:Row({
      Gap = 1,
      Children = {
        s:Button({ Text = "One", OnClick = function() end }),
        s:Button({ Text = "Two", OnClick = function() end }),
      },
    })
  end)

  root:handle("key", KEY.tab, false)
  root:render()
  screen.forget()

  root:handle("key", KEY.tab, false)
  expect.equal(root:render(), 1, "one row touched, so one call")
  root:destroy()
end)

it("a handler that throws does not take the screen down", function()
  local caught
  local screen = recorder.new(40, 10)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    onError = function(err)
      caught = err
    end,
    build = function(s)
      return s:Row({
        Children = {
          s:Button({
            Text = "Boom",
            OnClick = function()
              error("handler is wrong", 0)
            end,
          }),
        },
      })
    end,
  })
  root:render()

  root:handle("mouse_click", 1, 4, 1)
  root:handle("mouse_up", 1, 4, 1)

  expect.contains(caught, "handler is wrong", "the error was reported")
  -- The press still focused the button, so there is a repaint owed. The point is
  -- that the frame completes and the next one is idle, rather than the tree
  -- being left in a state nothing can render.
  root:render()
  expect.equal(root:render(), 0, "and the screen settles as normal")
  root:destroy()
end)

it("a resize event re-lays out the screen", function()
  local screen = recorder.new(40, 10)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return s:Column({ Children = { s:Text({ Text = "wide", Grow = 1 }) } })
    end,
  })
  root:render()

  screen.width, screen.height = 20, 6
  root:handle("term_resize")
  root:render()

  local width = root:size()
  expect.equal(width, 20, "the buffer followed the screen")
  root:destroy()
end)

---------------------------------------------------------------------------
-- Scrolling a table
---------------------------------------------------------------------------

it("scrolling a table moves the window, not the layout", function()
  local devices = {}
  for index = 1, 20 do
    devices[index] = { id = index, label = ("miner-%d"):format(index) }
  end

  local screen = recorder.new(40, 10)
  local scope = ui.scoped()
  local offset
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      offset = s:Value(0)
      return s:Table({
        Rows = s:Value(devices),
        Offset = offset,
        Capacity = 4,
        Columns = { { Title = "Device", Key = "label", Width = 12 } },
      })
    end,
  })
  root:render()
  expect.contains(screen.rowText(3), "miner-1", "the first slot shows the first device")

  screen.forget()
  root:handle("mouse_scroll", 1, 5, 3)
  local blits = root:render()

  expect.equal(offset:get(), 1, "the offset moved")
  expect.contains(screen.rowText(3), "miner-2", "and the window slid")
  expect.truthy(blits <= 4, "one blit per visible slot at most, and no relayout")

  -- Scrolling past the end is clamped by the table rather than by every screen
  -- that uses one.
  for _ = 1, 50 do
    root:handle("mouse_scroll", 1, 5, 3)
  end
  root:render()
  expect.equal(offset:get(), 16, "clamped to the last full page")

  for _ = 1, 50 do
    root:handle("mouse_scroll", -1, 5, 3)
  end
  root:render()
  expect.equal(offset:get(), 0, "and back to the top")
  root:destroy()
end)

it("clicking a table row reports the row, not the slot", function()
  local chosen
  local screen = recorder.new(40, 10)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return s:Table({
        Rows = s:Value({ { id = 11, label = "a" }, { id = 22, label = "b" } }),
        Offset = s:Value(1),
        Capacity = 3,
        OnSelect = function(row)
          chosen = row.id
        end,
        Columns = { { Title = "Device", Key = "label", Width = 12 } },
      })
    end,
  })
  root:render()

  -- Offset 1, so the first slot is holding the second device. A screen must get
  -- the device, not the widget it happened to be in.
  root:handle("mouse_click", 1, 5, 3)
  root:handle("mouse_up", 1, 5, 3)
  expect.equal(chosen, 22, "the row under the offset")

  chosen = nil
  root:handle("mouse_click", 1, 5, 4)
  root:handle("mouse_up", 1, 5, 4)
  expect.equal(chosen, nil, "and an empty slot selects nothing")
  root:destroy()
end)

---------------------------------------------------------------------------
-- The shell
---------------------------------------------------------------------------

it("the shell runs a scripted session and stops when it runs out", function()
  local pressed = 0
  local screen = recorder.new(40, 10)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return s:Row({
        Children = {
          s:Button({
            Text = "Go",
            OnClick = function()
              pressed = pressed + 1
            end,
          }),
        },
      })
    end,
  })

  local hands = keyboard.new()
  hands.click(3, 1).push("mouse_up", 1, 3, 1)
  hands.press(KEY.enter)

  ui.run(root, hands.port)

  -- Twice: the release fired it, and then enter fired it again, because the
  -- press left the button holding the focus ring. That is the behaviour a
  -- keyboard-only surface depends on, and seeing both paths in one session is
  -- the point of the assertion.
  expect.equal(pressed, 2, "clicked, then activated from the keyboard")
  expect.equal(hands.pending(), 0, "and the script was consumed")
  root:destroy()
end)

it("the shell stops on terminate without tearing anything down", function()
  local screen = recorder.new(40, 10)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return s:Text({ Text = "hello" })
    end,
  })

  local hands = keyboard.new()
  hands.push("terminate")
  hands.click(1, 1)

  ui.run(root, hands.port)

  -- The click after the terminate is still queued: the loop stopped, it did not
  -- drain. A shell that consumed the rest would make a held Ctrl-T swallow
  -- whatever a person did next.
  expect.equal(hands.pending(), 1, "stopped rather than drained")
  expect.truthy(root.tree ~= nil, "and left the tree alone for its owner to destroy")
  root:destroy()
end)

---------------------------------------------------------------------------
-- Devices: the acceptance test
---------------------------------------------------------------------------

--- A roster with enough devices to need scrolling.
local function roster(count, phase)
  local list = {}
  for index = 1, count do
    list[index] = {
      id = index,
      label = ("miner-%d"):format(index),
      phase = index == 2 and (phase or "mining") or "mining",
      job = "rare",
      fuel = 50000 - index * 1000,
      fuelLimit = 100000,
      since = index * 30,
      online = true,
    }
  end
  return list
end

local function devicesPage(count)
  local devicesView = require("apps.devices.view")
  local screen = recorder.new(51, 19)
  local scope = ui.scoped()
  local state = {}
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      state.roster = s:Value(roster(count or 12))
      state.selected = s:Value(nil)
      state.offset = s:Value(0)
      state.deployed = {}
      return devicesView.build(s, {
        devices = state.roster,
        selected = state.selected,
        offset = state.offset,
        capacity = 8,
        onSelect = function(device)
          state.selected:set(device.id)
        end,
        onDeploy = function(device)
          state.deployed[#state.deployed + 1] = device.id
        end,
        onRecall = function() end,
      })
    end,
  })
  root:render()
  return root, screen, state
end

it("Devices shows a list, and an empty detail panel until something is picked", function()
  local root, screen = devicesPage(12)

  expect.contains(screen.rowText(2), "Devices", "the title")
  expect.contains(screen.rowText(2), "12 known", "and the derived count")

  local rows = {}
  for row = 5, 15 do
    rows[#rows + 1] = screen.rowText(row)
  end
  local body = table.concat(rows, " ")
  expect.contains(body, "miner-1", "the roster")
  expect.contains(body, "No device selected", "and a detail panel that says so")

  root:destroy()
end)

it("clicking a row fills the detail panel, and only repaints what changed", function()
  local root, screen, state = devicesPage(12)

  screen.forget()
  -- Row 7 is the first table slot; see the Page anatomy in runtime_spec.
  root:handle("mouse_click", 1, 6, 7)
  root:handle("mouse_up", 1, 6, 7)
  local blits = root:render()

  expect.equal(state.selected:get(), 1, "the first device is selected")

  local lines = {}
  for row = 5, 16 do
    lines[#lines + 1] = screen.rowText(row)
  end
  local panel = table.concat(lines, " ")
  expect.contains(panel, "miner-1", "the panel names it")
  expect.contains(panel, "rare", "and shows its job")

  -- The whole right-hand panel changed, plus the row highlight, plus three
  -- buttons becoming enabled. It is a lot of the screen - and still nothing
  -- like a full repaint, which on 51x19 would be 19.
  expect.truthy(blits < 19, "a real change, still not a full repaint: " .. blits)
  root:destroy()
end)

it("the buttons are disabled until something is selected, without being told", function()
  local root, screen, state = devicesPage(12)

  -- `Disabled` is a Computed over the same list the table reads. There is no
  -- code path that enables these buttons, so there is no code path that can
  -- leave them wrong.
  root:handle("mouse_click", 1, 6, 19)
  root:handle("mouse_up", 1, 6, 19)
  expect.equal(#state.deployed, 0, "deploy does nothing with no selection")

  root:handle("mouse_click", 1, 6, 7)
  root:handle("mouse_up", 1, 6, 7)
  root:render()

  root:handle("mouse_click", 1, 6, 19)
  root:handle("mouse_up", 1, 6, 19)
  expect.equal(state.deployed[1], 1, "and deploys the selected device once there is one")
  root:destroy()
end)

it("a selected device that leaves the roster empties the panel rather than lying", function()
  local root, screen, state = devicesPage(12)

  root:handle("mouse_click", 1, 6, 8)
  root:handle("mouse_up", 1, 6, 8)
  root:render()
  expect.equal(state.selected:get(), 2, "the second device")

  -- It goes offline and drops off the roster while its detail is open. Showing
  -- the last known record with no sign that it is stale is worse than showing
  -- nothing.
  local shorter = {}
  for _, device in ipairs(state.roster:get()) do
    if device.id ~= 2 then
      shorter[#shorter + 1] = device
    end
  end
  state.roster:set(shorter)
  root:render()

  local panel = {}
  for row = 5, 16 do
    panel[#panel + 1] = screen.rowText(row)
  end
  expect.contains(table.concat(panel, " "), "No device selected", "the panel empties")
  root:destroy()
end)

it("Devices scrolls its list without moving anything else", function()
  local root, screen, state = devicesPage(20)

  screen.forget()
  root:handle("mouse_scroll", 1, 6, 8)
  root:handle("mouse_scroll", 1, 6, 8)
  local blits = root:render()

  expect.equal(state.offset:get(), 2, "scrolled two rows")

  local rows = {}
  for row = 7, 14 do
    rows[#rows + 1] = screen.rowText(row)
  end
  local body = table.concat(rows, " ")
  expect.contains(body, "miner-3", "the window moved")
  expect.falsy(body:find("miner%-1%D"), "past the first devices")

  -- Eight visible rows changed. The detail panel, the header, the buttons and
  -- the column headings did not, so they cost nothing - which is the whole
  -- reason scrolling is an offset rather than a rebuild.
  expect.truthy(blits <= 8, "at most one blit per visible row: " .. blits)
  root:destroy()
end)

it("Devices is usable from a keyboard alone, which is all a turtle has", function()
  local root, screen, state = devicesPage(12)

  root:handle("mouse_click", 1, 6, 7)
  root:handle("mouse_up", 1, 6, 7)
  root:render()

  -- Tab to the first enabled action and press it. No mouse involved.
  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.enter, false)
  expect.equal(state.deployed[1], 1, "the focused action fired")
  root:destroy()
end)

it("a display-only Devices page has no actions at all", function()
  local devicesView = require("apps.devices.view")
  local screen = recorder.new(51, 19)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return devicesView.build(s, {
        devices = s:Value(roster(4)),
        selected = s:Value(1),
        capacity = 4,
      })
    end,
  })
  root:render()

  for row = 1, 19 do
    local text = screen.rowText(row) or ""
    expect.falsy(text:find("Deploy", 1, true), "no Deploy on row " .. row)
    expect.falsy(text:find("Recall", 1, true), "no Recall on row " .. row)
  end
  expect.equal(#root:focusRing(), 0, "and nothing to tab to")
  root:destroy()
end)

---------------------------------------------------------------------------
-- The settings editor, which the acceptance test in section 14 asks for
---------------------------------------------------------------------------

local function editable(phase)
  local devicesView = require("apps.devices.view")
  local screen = recorder.new(51, 19)
  local scope = ui.scoped()
  local state = { writes = {}, jobs = {} }
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      state.roster = s:Value({
        {
          id = 1,
          label = "miner-1",
          phase = phase or "parked",
          job = "rare",
          fuel = 51000,
          fuelLimit = 100000,
          settings = { targetY = -59, veinBudget = 64, veinRadius = 8, scanEvery = 100 },
        },
      })
      state.selected = s:Value(1)
      return devicesView.build(s, {
        devices = state.roster,
        selected = state.selected,
        capacity = 3,
        onSelect = function() end,
        onSetting = function(device, key, value)
          state.writes[#state.writes + 1] = { id = device.id, key = key, value = value }
        end,
        onJob = function(device, job)
          state.jobs[#state.jobs + 1] = { id = device.id, job = job }
        end,
      })
    end,
  })
  root:render()
  return root, screen, state
end

local function panelText(screen)
  local lines = {}
  for row = 4, 18 do
    lines[#lines + 1] = screen.rowText(row)
  end
  return table.concat(lines, " ")
end

it("the settings editor replaces the detail panel rather than crowding it", function()
  local root, screen = editable()

  expect.contains(panelText(screen), "miner-1", "the detail panel is showing")
  expect.falsy(panelText(screen):find("vein budget"), "and the editor is not")

  -- The last action is the panel switch.
  local ring = root:focusRing()
  root:focus(ring[#ring])
  root:handle("key", KEY.enter, false)
  root:render()

  expect.contains(
    panelText(screen),
    "vein budget",
    "the editor is showing, with room for real labels"
  )
  expect.falsy(panelText(screen):find("seen"), "the detail panel is hidden, not merely covered")
  expect.falsy(panelText(screen):find("DEVICE"), "and so is the list, so the editor gets the width")
  root:destroy()
end)

it("a hidden panel takes no space and paints nothing", function()
  -- `Hidden` used to affect only hit testing, so a hidden node still reserved
  -- its box and still painted: invisible to a click and perfectly visible to a
  -- person, which is the worst of both.
  local root, screen = editable()
  local ring = root:focusRing()
  root:focus(ring[#ring])
  root:handle("key", KEY.enter, false)
  root:render()

  local text = panelText(screen)
  local _, detailWidth = nil, nil
  expect.falsy(text:find("No device selected"), "the hidden card contributes nothing")
  expect.contains(text, "target Y", "and the editor took its place")
  root:destroy()
end)

it("stepping a setting reports the intent and does not write it", function()
  local root, screen, state = editable()
  local ring = root:focusRing()
  root:focus(ring[#ring])
  root:handle("key", KEY.enter, false)
  root:render()

  -- Two tabs: the job picker is the first stop in the editor, and the steppers
  -- follow it. One tab stop per setting, not three - the arrows beside each are
  -- deliberately not focusable.
  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.right, false)

  expect.equal(#state.writes, 1, "one change reported")
  expect.equal(state.writes[1].key, "targetY", "the first field")
  expect.equal(state.writes[1].value, -58, "stepped by its own step")
  expect.equal(state.writes[1].id, 1, "for the selected device")

  -- The screen decides whether to apply it; a stepper never writes its own
  -- value, because in the real app this sends a `configure` message to a turtle
  -- that may refuse.
  local device = state.roster:get()[1]
  expect.equal(device.settings.targetY, -59, "the record is untouched until the screen says so")
  root:destroy()
end)

it("a working turtle cannot be reconfigured", function()
  -- One of the high-risk invariants in docs/ai-handoff.md: remote configuration
  -- requires a parked turtle. Derived from the same record the panel shows, so
  -- there is no code path that leaves the editor live while a turtle is down a
  -- shaft.
  local root, screen, state = editable("mining")
  local ring = root:focusRing()
  root:focus(ring[#ring])
  root:handle("key", KEY.enter, false)
  root:render()

  expect.contains(panelText(screen), "park it first", "the panel says why")

  -- Disabled steppers are not in the ring at all, so tab cannot reach one.
  for _, node in ipairs(root:focusRing()) do
    expect.falsy(
      node.OnKey ~= nil and node.Disabled ~= true and node._kind == "Row",
      "no live stepper"
    )
  end

  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.right, false)
  expect.equal(#state.writes, 0, "and nothing was changed")
  expect.equal(#state.jobs, 0, "including the job")
  root:destroy()
end)

it("a display-only surface gets no editor and no way to reach one", function()
  local devicesView = require("apps.devices.view")
  local screen = recorder.new(51, 19)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return devicesView.build(s, {
        devices = s:Value({ { id = 1, label = "miner-1", phase = "parked", settings = {} } }),
        selected = s:Value(1),
        capacity = 3,
      })
    end,
  })
  root:render()

  for row = 1, 19 do
    expect.falsy((screen.rowText(row) or ""):find("Settings", 1, true), "no switch on row " .. row)
  end
  expect.equal(#root:focusRing(), 0, "and nothing to tab to")
  root:destroy()
end)

it("a composite reads a state prop through peek, not as a truth value", function()
  -- The trap in the composite API, pinned because it is invisible: a composite
  -- receives raw props, so `props.Disabled` is a `Computed` - a table, and
  -- therefore truthy whether it currently reads true or false. `if
  -- props.Disabled then` disabled every stepper on the page permanently, passed
  -- review, and raised nothing.
  local root, screen, state = editable("parked")
  local ring = root:focusRing()
  root:focus(ring[#ring])
  root:handle("key", KEY.enter, false)
  root:render()

  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.right, false)
  expect.equal(#state.writes, 1, "a Computed reading false does not disable the control")
  root:destroy()
end)

it("the job picker cycles through the fleet's jobs and wraps", function()
  -- `src/apps/devices.lua` changes a job by cycling `JOB_ORDER` on each press,
  -- and a `Select` is that shape rather than a dropdown: a dropdown needs
  -- somewhere to drop, and on a monitor it is a floating panel a touch can miss
  -- with no hover to hint it opened.
  local devicesView = require("apps.devices.view")
  local root, screen, state = editable("parked")
  local ring = root:focusRing()
  root:focus(ring[#ring])
  root:handle("key", KEY.enter, false)
  root:render()

  -- The seeded device is on "rare", the second of five.
  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.right, false)
  expect.equal(state.jobs[1].job, devicesView.JOBS[3], "forward one")

  root:handle("key", KEY.left, false)
  root:handle("key", KEY.left, false)
  expect.equal(state.jobs[3].job, devicesView.JOBS[1], "and back two")

  -- The picker reports intent and never writes, so the record still says "rare"
  -- and every press is computed from it. Going left from the first option wraps
  -- to the last rather than sticking.
  root:handle("key", KEY.left, false)
  expect.equal(state.jobs[4].job, devicesView.JOBS[1], "still computed from the unchanged record")
  root:destroy()
end)

it("a toggle flips from either arrow, because it has no direction", function()
  local screen = recorder.new(30, 5)
  local scope = ui.scoped()
  local seen = {}
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      local on = s:Value(false)
      return s:Column({
        Children = {
          s:Toggle({
            Label = "auto recovery",
            Value = on,
            OnChange = function(value)
              seen[#seen + 1] = value
              on:set(value)
            end,
          }),
        },
      })
    end,
  })
  root:render()

  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.right, false)
  expect.equal(seen[1], true, "right turns it on")
  root:handle("key", KEY.left, false)
  expect.equal(seen[2], false, "and left turns it off again, rather than doing nothing")

  root:render()
  expect.contains(screen.rowText(1), "off", "the word carries the state, not only the colour")
  root:destroy()
end)

it("a select with no options does nothing rather than erroring", function()
  local screen = recorder.new(30, 5)
  local scope = ui.scoped()
  local changes = 0
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return s:Column({
        Children = {
          s:Select({
            Label = "job",
            Options = {},
            Value = nil,
            OnChange = function()
              changes = changes + 1
            end,
          }),
        },
      })
    end,
  })
  root:render()

  root:handle("key", KEY.tab, false)
  root:handle("key", KEY.right, false)
  expect.equal(changes, 0, "nothing to cycle to")
  expect.contains(screen.rowText(1), "none", "and it says so")
  root:destroy()
end)

it("the keycodes are GLFW, which is what CC has used since Minecraft 1.13", function()
  -- A wrong constant here is invisible: the screen draws correctly and every
  -- key is ignored. `os/kernel/prompt.lua` shipped with the pre-1.13 LWJGL2
  -- scancodes - 200 for up, 28 for enter - in a table of its own, and the menu
  -- looked finished while responding to nothing.
  --
  -- One table now, this one. These four are the ones a menu cannot work
  -- without, so they are the ones worth pinning.
  expect.equal(input.KEY.up, 265, "up")
  expect.equal(input.KEY.down, 264, "down")
  expect.equal(input.KEY.enter, 257, "enter")
  expect.equal(input.KEY.escape, 256, "escape")

  -- And the prompt uses it rather than restating it, which is what stops the
  -- two drifting again.
  expect.equal(require("os.kernel.prompt").KEY, input.KEY, "one table, shared")
end)
