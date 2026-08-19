--- Springs, tweens, clipping, and the claim that an idle screen costs nothing.
---
--- Animation is normally the untestable part of a UI, because physics that read
--- a clock can only be tested by sleeping - which makes a suite slow and flaky
--- at the same time. `Root:advance(now)` takes the time instead of reading it,
--- so these step by exactly one tick and assert where things got to.

local expect = require("support.expect")
local it = require("support.spec").it

local keyboard = require("adapters.sim.input")
local recorder = require("adapters.sim.screen")
local ui = require("ui.init")

local T = ui.tokens
local TICK = 50

--- Step a root forward `count` ticks of 50ms from a fixed start.
local function run(root, count, from)
  local now = from or 1000
  for _ = 1, count do
    now = now + TICK
    root:advance(now)
    root:render()
  end
  return now
end

local function mounted(build, width, height)
  local screen = recorder.new(width or 40, height or 10)
  local scope = ui.scoped()
  local root = ui.mount({ scope = scope, screen = screen.port, build = build })
  root:advance(1000)
  root:render()
  screen.forget()
  return root, screen, scope
end

---------------------------------------------------------------------------
-- Springs
---------------------------------------------------------------------------

it("a spring starts where its goal is and does not move", function()
  local scope = ui.scoped()
  local width = scope:Spring(12, 25, 1)
  expect.equal(width:get(), 12, "at the goal from the start")
  scope:destroy()
end)

it("a spring moves towards a new goal and settles exactly on it", function()
  local scope = ui.scoped()
  local goal = scope:Value(12)
  local width = scope:Spring(goal, 25, 1)
  local driver = scope:_animator()

  goal:set(24)
  expect.truthy(driver:busy(), "re-targeting starts it moving")
  expect.equal(width:get(), 12, "but nothing has moved until time passes")

  driver:advance(1000)
  local now = 1000
  local frames = 0
  while driver:busy() and frames < 200 do
    now = now + TICK
    driver:advance(now)
    frames = frames + 1
  end

  expect.falsy(driver:busy(), "it settles")
  -- Exactly, not nearly. A spring that stopped at 23.996 would leave a component
  -- rendering a width of 23 forever, and the bug would look like an off-by-one
  -- in the layout rather than like a spring that never arrived.
  expect.equal(width:get(), 24, "exactly on the goal")
  expect.truthy(frames < 40, "and within a couple of seconds: " .. frames .. " frames")
  scope:destroy()
end)

it("a spring can be re-targeted mid-flight without jumping", function()
  -- The entire reason to use a spring rather than a tween: a person changing
  -- their mind halfway through should see the value curve towards the new goal
  -- from wherever it currently is.
  local scope = ui.scoped()
  local goal = scope:Value(0)
  local value = scope:Spring(goal, 20, 1)
  local driver = scope:_animator()
  driver:advance(1000)

  goal:set(100)
  driver:advance(1050)
  driver:advance(1100)
  local midFlight = value:get()
  expect.truthy(midFlight > 0 and midFlight < 100, "somewhere in between: " .. midFlight)

  goal:set(0)
  driver:advance(1150)
  local afterRetarget = value:get()
  expect.truthy(
    math.abs(afterRetarget - midFlight) < 50,
    "continues from where it was rather than jumping: " .. afterRetarget
  )
  scope:destroy()
end)

it("a spring at the documented speed does not diverge", function()
  -- The instability that made the first version of this file spin forever. A
  -- 50ms frame at speed 25 puts `speed^2 * dt^2` at 1.56, and an integrator
  -- above 1 gains energy every step. The value went to six figures in six
  -- frames, never settled, and so kept the host loop awake at 20 FPS.
  local scope = ui.scoped()
  local goal = scope:Value(0)
  local value = scope:Spring(goal, 25, 1)
  local driver = scope:_animator()
  driver:advance(1000)

  goal:set(1)
  local now, largest = 1000, 0
  for _ = 1, 200 do
    now = now + TICK
    driver:advance(now)
    largest = math.max(largest, math.abs(value:get()))
  end

  expect.truthy(largest < 2, "stayed bounded: reached " .. largest)
  expect.falsy(driver:busy(), "and settled rather than running forever")
  scope:destroy()
end)

it("an overdamped spring does not overshoot", function()
  local scope = ui.scoped()
  local goal = scope:Value(0)
  local value = scope:Spring(goal, 15, 1.5)
  local driver = scope:_animator()
  driver:advance(1000)

  goal:set(10)
  local highest, now = 0, 1000
  for _ = 1, 100 do
    now = now + TICK
    driver:advance(now)
    highest = math.max(highest, value:get())
  end
  expect.truthy(highest <= 10.001, "never went past the goal: " .. highest)
  scope:destroy()
end)

it("a long pause resumes rather than teleports", function()
  -- A chunk unloads, or the server hitches, and the next frame is four seconds
  -- later. Integrating that whole gap snaps every spring straight to its goal,
  -- which looks like the animation never happened.
  local scope = ui.scoped()
  local goal = scope:Value(0)
  local value = scope:Spring(goal, 20, 1)
  local driver = scope:_animator()
  driver:advance(1000)

  goal:set(100)
  driver:advance(5000)

  expect.truthy(value:get() < 100, "did not arrive in one step: " .. value:get())
  expect.truthy(driver:busy(), "and is still going")
  scope:destroy()
end)

---------------------------------------------------------------------------
-- Tweens
---------------------------------------------------------------------------

it("a tween takes its stated duration and lands exactly", function()
  local scope = ui.scoped()
  local goal = scope:Value(0)
  local value = scope:Tween(goal, 0.25, "linear")
  local driver = scope:_animator()
  driver:advance(1000)

  -- Advanced a tick at a time, as the host loop does. One 125ms jump would be
  -- clipped to the 100ms pause clamp and land short - which is the clamp working
  -- rather than the tween being wrong.
  goal:set(100)
  driver:advance(1050)
  driver:advance(1100)
  driver:advance(1125)
  expect.near(value:get(), 50, 1, "half way at half the duration")

  driver:advance(1175)
  driver:advance(1225)
  driver:advance(1250)
  expect.equal(value:get(), 100, "arrived")
  expect.falsy(driver:busy(), "and stopped")
  scope:destroy()
end)

it("every easing starts at 0 and ends at 1", function()
  for name, ease in pairs(ui.anim.easings) do
    expect.near(ease(0), 0, 0.0001, name .. " starts at 0")
    expect.near(ease(1), 1, 0.0001, name .. " ends at 1")
  end
end)

it("back overshoots and comes home, which the others do not", function()
  local highest = 0
  for step = 0, 100 do
    highest = math.max(highest, ui.anim.easings.back(step / 100))
  end
  expect.truthy(highest > 1, "back goes past its goal: " .. highest)
  expect.truthy(highest < 1.15, "but only a little, because there are four frames to do it in")

  for _, name in ipairs({ "linear", "easeOut", "easeInOut" }) do
    local peak = 0
    for step = 0, 100 do
      peak = math.max(peak, ui.anim.easings[name](step / 100))
    end
    expect.near(peak, 1, 0.0001, name .. " does not overshoot")
  end
end)

---------------------------------------------------------------------------
-- The claim that matters: idle costs nothing
---------------------------------------------------------------------------

it("a screen with no animation never allocates a driver", function()
  local root, screen, scope = mounted(function(s)
    return s:Column({ Children = { s:Text({ Text = "still" }) } })
  end)

  -- Not "the driver reports idle" - there is no driver. A dashboard that
  -- animates nothing must not pay a frame timer for the possibility.
  expect.falsy(root:animating(), "nothing is moving")
  expect.falsy(root:advance(9999), "and advancing does no work at all")
  expect.equal(root:render(), 0, "nor does rendering")
  root:destroy()
end)

it("a settled animation stops asking for frames", function()
  local goal
  local root, screen = mounted(function(s)
    goal = s:Value(1)
    return s:Column({
      Children = { s:Meter({ Height = 1, Value = s:Spring(goal, 25, 1) }) },
    })
  end)

  goal:set(0)
  expect.truthy(root:animating(), "in flight")

  local now = 1000
  local frames = 0
  while root:animating() and frames < 200 do
    now = now + TICK
    root:advance(now)
    root:render()
    frames = frames + 1
  end

  -- This is the §8 requirement, and it is the difference between a base station
  -- that idles and one that wakes twenty times a second forever.
  expect.falsy(root:animating(), "settled")
  expect.falsy(root:pending(), "with nothing left to draw")
  expect.equal(root:render(), 0, "and the next frame is free")
  root:destroy()
end)

it("an animated value drives a component without the component knowing", function()
  local goal
  local root, screen = mounted(function(s)
    goal = s:Value(0)
    return s:Column({
      Children = {
        s:Meter({ Height = 1, Width = 10, Value = s:Spring(goal, 25, 1), Tint = T.accent }),
      },
    })
  end, 10, 3)

  local function filled()
    local count = 0
    for x = 1, 10 do
      local _, bg = screen.colourAt(x, 1)
      if bg == ui.buffer.hex(T.accent) then
        count = count + 1
      end
    end
    return count
  end

  expect.equal(filled(), 0, "empty to begin with")

  goal:set(1)
  run(root, 3)
  local partway = filled()
  expect.truthy(partway > 0 and partway < 10, "partly filled mid-flight: " .. partway)

  run(root, 60)
  expect.equal(filled(), 10, "and full once it settles")
  root:destroy()
end)

it("the host loop only wakes on a timer while something is moving", function()
  -- The two are the same mechanism seen from the loop's side: a timeout is
  -- requested only when `animating()` is true, so an idle screen blocks on the
  -- next event and a moving one wakes every tick.
  local requested = {}
  local port = {
    pull = function(timeout)
      -- Recorded as a word rather than as nil: appending nil to a Lua table does
      -- not grow it, so a blocking pull would leave no trace at all.
      requested[#requested + 1] = timeout or "blocked"
      return nil
    end,
    queue = function() end,
  }

  local screen = recorder.new(20, 3)
  local scope = ui.scoped()
  local goal
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      goal = s:Value(0)
      return s:Meter({ Height = 1, Value = s:Spring(goal, 25, 1) })
    end,
  })

  local time = 1000
  local clock = {
    now = function()
      time = time + TICK
      return time
    end,
  }

  goal:set(1)
  ui.run(root, port, { clock = clock, timeout = nil })

  expect.truthy(#requested > 1, "the loop ran while the spring was moving")
  expect.equal(requested[1], ui.anim.FRAME, "asking for a tick, not blocking")
  expect.equal(requested[#requested], "blocked", "and blocked again once it settled")
  root:destroy()
end)

---------------------------------------------------------------------------
-- Clipping
---------------------------------------------------------------------------

it("a clip keeps a run inside its rectangle", function()
  local screen = recorder.new(20, 3)
  local frame = ui.buffer.new(screen.port, 20, 3)

  frame:clip(5, 1, 6, 1)
  frame:write(1, 1, "abcdefghijklmno", 0, 15)
  frame:unclip()
  frame:present()

  expect.equal(screen.charAt(4, 1), " ", "nothing before the clip")
  expect.equal(screen.charAt(5, 1), "e", "the run resumes at the clip edge")
  expect.equal(screen.charAt(10, 1), "j", "and stops at the far edge")
  expect.equal(screen.charAt(11, 1), " ", "nothing after it")
end)

it("clips nest by intersection, not replacement", function()
  -- A scrolling list inside a modal inside a page has to be clipped by all
  -- three. A component that replaced the clip would paint its contents outside
  -- the dialog containing it.
  local screen = recorder.new(20, 3)
  local frame = ui.buffer.new(screen.port, 20, 3)

  frame:clip(1, 1, 10, 1)
  frame:clip(5, 1, 10, 1)
  frame:write(1, 1, string.rep("x", 20), 0, 15)
  frame:unclip()
  frame:unclip()
  frame:present()

  expect.equal(screen.charAt(4, 1), " ", "outside the inner clip")
  expect.equal(screen.charAt(5, 1), "x", "inside both")
  expect.equal(screen.charAt(10, 1), "x", "up to the outer edge")
  expect.equal(screen.charAt(11, 1), " ", "and not past it")
end)

it("a clipped row outside the rectangle is dropped entirely", function()
  local screen = recorder.new(20, 4)
  local frame = ui.buffer.new(screen.port, 20, 4)

  frame:clip(1, 2, 20, 1)
  frame:write(1, 1, "above", 0, 15)
  frame:write(1, 2, "inside", 0, 15)
  frame:write(1, 3, "below", 0, 15)
  frame:unclip()
  frame:present()

  expect.equal(screen.rowText(1):sub(1, 5), "     ", "the row above is masked")
  expect.equal(screen.rowText(2):sub(1, 6), "inside", "the row inside is drawn")
  expect.equal(screen.rowText(3):sub(1, 5), "     ", "and the row below is masked")
end)

it("a ScrollView masks its contents and moves only its origin", function()
  local scroll
  local screen = recorder.new(20, 6)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      scroll = s:Value(0)
      local lines = {}
      for index = 1, 10 do
        lines[index] = s:Text({ Text = ("line %d"):format(index), Height = 1 })
      end
      -- Wrapped, because the root node is always given the whole screen: a
      -- Height on it would be ignored, and the panel would not be shorter than
      -- its contents, which is the entire thing being tested.
      return s:Column({
        Children = { s:ScrollView({ Scroll = scroll, Height = 3, Children = lines }) },
      })
    end,
  })
  root:render()

  expect.contains(screen.rowText(1), "line 1", "the first line")
  expect.contains(screen.rowText(3), "line 3", "and the third")
  expect.falsy(screen.rowText(4):find("line"), "the fourth is masked away")

  scroll:set(2)
  root:render()
  expect.contains(screen.rowText(1), "line 3", "scrolling moved the origin")
  expect.falsy(screen.rowText(4):find("line"), "and the mask still holds")
  root:destroy()
end)

it("a repaint inside a scrolled panel stays inside it", function()
  -- The case a targeted repaint gets wrong: painting a subtree in isolation is
  -- not the same as painting it in context, because the clips its ancestors
  -- would have pushed are not in force. Without replaying them, a row scrolled
  -- off the top repaints itself over whatever is above the panel.
  local label
  local screen = recorder.new(20, 6)
  local scope = ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      label = s:Value("hidden")
      return s:Column({
        Children = {
          s:Text({ Text = "HEADER", Height = 1 }),
          s:ScrollView({
            Scroll = 2,
            Height = 2,
            Children = {
              s:Text({ Text = label, Height = 1 }),
              s:Text({ Text = "second", Height = 1 }),
              s:Text({ Text = "third", Height = 1 }),
            },
          }),
        },
      })
    end,
  })
  root:render()
  expect.contains(screen.rowText(1), "HEADER", "the header is drawn")

  -- This text is scrolled two rows above the panel, so it lands exactly on the
  -- header's row if the clip is not replayed.
  label:set("LEAKED")
  root:render()

  expect.contains(screen.rowText(1), "HEADER", "and is still there afterwards")
  expect.falsy(screen.rowText(1):find("LEAKED"), "nothing leaked out of the panel")
  root:destroy()
end)

it("an Overlay covers its parent without changing its parent's size", function()
  local screen = recorder.new(20, 6)
  local scope = ui.scoped()
  local tree
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      tree = s:Column({
        Children = {
          s:Text({ Text = "page", Height = 1 }),
          s:Overlay({
            Children = { s:Text({ Text = "dialog", Height = 1 }) },
          }),
        },
      })
      return tree
    end,
  })
  root:render()

  -- A modal that made its page as tall as the dialog inside it would shove the
  -- page's own content around every time one opened.
  local _, _, _, height = ui.layout.box(tree.Children[1])
  expect.equal(height, 1, "the page content kept its own height")
  expect.contains(screen.rowText(1), "dialog", "and the overlay is drawn over it")
  root:destroy()
end)
