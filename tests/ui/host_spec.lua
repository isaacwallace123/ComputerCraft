--- The two ways a screen session ends, and why neither existed before.
---
--- `host.run` is an event loop, and until now the only thing that could end one
--- was the input port drying up. That is fine for a machine with one screen and
--- one app, and it is wrong the moment anything on screen can ask to be replaced
--- by something else - which is what a taskbar, an app switcher and a desktop
--- full of icons all are.
---
--- Both failures below were reported from in world in the same words: "clicking
--- doesn't work". Neither errored, neither was visible in a spec, and both were
--- a handler recording a decision that nothing ever read.

local expect = require("support.expect")
local it = require("support.spec").it

local host = require("ui.host")
local screenPort = require("ports.screen")
local ui = require("ui.init")

--- An input port that plays a fixed list of events and then stops.
local function scripted(events)
  local index = 0
  return require("ports.input").check({
    pull = function()
      index = index + 1
      local event = events[index]
      if event == nil then
        return nil
      end
      return table.unpack(event)
    end,
    queue = function() end,
  })
end

--- Mount a one-node screen. The tree does not matter here; the loop does.
local function mounted(build)
  local scope = ui.scoped()
  local root = host.mount({
    screen = screenPort.null(51, 19),
    scope = scope,
    build = build or function(inner)
      return inner:Text({ Text = "hello" })
    end,
  })
  return root, scope
end

it("a handler that wants the session over ends it", function()
  local root, scope = mounted()
  local seen = 0

  host.run(root, scripted({ { "key", 200 }, { "key", 201 }, { "key", 202 } }), {
    onEvent = function()
      seen = seen + 1
      -- Returning `true` would only consume the key. The shell did exactly that
      -- when a number key asked for another app: it recorded the choice, kept
      -- drawing the old one, and read the choice after a loop that had no reason
      -- to end.
      return host.STOP
    end,
  })

  expect.equal(seen, 1, "the loop stopped on the first event, not the last")
  scope:destroy()
end)

it("a click inside the tree can end the session, which onEvent cannot see", function()
  local scope = ui.scoped()
  local picked = nil

  local root = host.mount({
    screen = screenPort.null(51, 19),
    scope = scope,
    build = function(inner)
      return inner:Box({
        Grow = 1,
        Children = {
          inner:Text({
            Text = "Fleet",
            OnClick = function()
              picked = "fleet"
            end,
          }),
        },
      })
    end,
  })

  local events = 0
  -- A press and a release, because `OnClick` fires on the release. CC gives a
  -- terminal both and a monitor neither - `ui/input.lua` synthesises the pair
  -- from one touch - and a spec that sent only the press would be testing a
  -- gesture no surface produces.
  local clicks = { { "mouse_click", 1, 1, 1 }, { "mouse_up", 1, 1, 1 }, { "key", 200 } }
  host.run(root, scripted(clicks), {
    onEvent = function()
      events = events + 1
      -- A pointer event reaches the component's `OnClick`, never here, so this
      -- handler has no way to know anything was clicked.
      return false
    end,
    onFrame = function()
      if picked ~= nil then
        return host.STOP
      end
      return nil
    end,
  })

  expect.equal(picked, "fleet", "the click landed")
  expect.equal(events, 2, "the press and the release, and then it stopped")
  scope:destroy()
end)

it("a session with no reason to stop runs until the input dries up", function()
  local root, scope = mounted()
  local seen = 0

  host.run(root, scripted({ { "key", 200 }, { "key", 201 } }), {
    onEvent = function()
      seen = seen + 1
      return false
    end,
  })

  expect.equal(seen, 2, "both events, and then the port ended it")
  scope:destroy()
end)
