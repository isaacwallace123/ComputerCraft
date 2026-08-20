--- State objects, the dependency graph, and lifetime.
---
--- No world and no screen. These are the tests the ports layer was built to make
--- possible: the graph is plain Lua over plain tables, so its behaviour under a
--- diamond dependency or a destroyed scope is a unit test rather than something
--- inferred from watching a monitor.

local expect = require("support.expect")
local it = require("support.spec").it

local reactive = require("ui.state.reactive")

---------------------------------------------------------------------------
-- Values and computeds
---------------------------------------------------------------------------

it("a Value holds and reports what it was set to", function()
  local scope = reactive.scoped()
  local fuel = scope:Value(51000)

  expect.equal(fuel:get(), 51000, "initial")
  expect.truthy(fuel:set(800), "a real change reports true")
  expect.equal(fuel:get(), 800, "updated")
  expect.falsy(fuel:set(800), "setting the same value changes nothing")

  scope:destroy()
end)

it("a Computed derives from what it declares", function()
  local scope = reactive.scoped()
  local fuel = scope:Value(51000)
  local low = scope:Computed(function(use)
    return use(fuel) < 800
  end)

  expect.falsy(low:get(), "51000 is not low")
  fuel:set(400)
  expect.truthy(low:get(), "400 is")

  scope:destroy()
end)

it("a Computed recomputes lazily, once, however many times its input moved", function()
  local scope = reactive.scoped()
  local fuel = scope:Value(1)
  local runs = 0
  local doubled = scope:Computed(function(use)
    runs = runs + 1
    return use(fuel) * 2
  end)

  expect.equal(runs, 0, "nothing runs until something reads it")
  expect.equal(doubled:get(), 2, "first read computes")
  expect.equal(runs, 1, "once")
  expect.equal(doubled:get(), 2, "a second read is cached")
  expect.equal(runs, 1, "still once")

  -- This is the property that makes a busy heartbeat cheap: twenty sets between
  -- frames cost one evaluation, not twenty.
  fuel:set(2)
  fuel:set(3)
  fuel:set(4)
  expect.equal(runs, 1, "invalidation does not recompute")
  expect.equal(doubled:get(), 8, "the read does")
  expect.equal(runs, 2, "and only once for all three sets")

  scope:destroy()
end)

it("a diamond evaluates its shared root once per change", function()
  local scope = reactive.scoped()
  local root = scope:Value(2)
  local runs = 0
  local shared = scope:Computed(function(use)
    runs = runs + 1
    return use(root) * 10
  end)
  local left = scope:Computed(function(use)
    return use(shared) + 1
  end)
  local right = scope:Computed(function(use)
    return use(shared) + 2
  end)

  expect.equal(left:get(), 21, "left")
  expect.equal(right:get(), 22, "right")
  expect.equal(runs, 1, "the shared node ran once for both branches")

  root:set(3)
  expect.equal(left:get(), 31, "left again")
  expect.equal(right:get(), 32, "right again")
  expect.equal(runs, 2, "and once more, not twice")

  scope:destroy()
end)

it("dependencies are re-declared on every run, so a branch does not over-subscribe", function()
  local scope = reactive.scoped()
  local useLeft = scope:Value(true)
  local left = scope:Value("L")
  local right = scope:Value("R")
  local runs = 0

  local chosen = scope:Computed(function(use)
    runs = runs + 1
    if use(useLeft) then
      return use(left)
    end
    return use(right)
  end)

  expect.equal(chosen:get(), "L", "takes the left branch")
  local before = runs

  -- `right` was never read on that pass, so changing it must not invalidate.
  -- A framework that kept the old edges would wake this computed for a value it
  -- provably did not look at.
  right:set("R2")
  chosen:get()
  expect.equal(runs, before, "the untaken branch does not invalidate")

  left:set("L2")
  expect.equal(chosen:get(), "L2", "the taken branch does")
end)

it("use passes plain values straight through", function()
  local scope = reactive.scoped()
  -- Components accept either a state object or a constant for the same
  -- property, so every read site would otherwise need a branch.
  local sum = scope:Computed(function(use)
    return use(5) + use(scope:Value(3))
  end)
  expect.equal(sum:get(), 8, "constants and states mix")
end)

---------------------------------------------------------------------------
-- Observers
---------------------------------------------------------------------------

it("an Observer fires on change and not on creation", function()
  local scope = reactive.scoped()
  local phase = scope:Value("mining")
  local seen = {}
  scope:Observer(phase, function(value)
    seen[#seen + 1] = value
  end)

  expect.equal(#seen, 0, "creating an observer is not a change")
  phase:set("returning")
  phase:set("parked")
  expect.equal(#seen, 2, "two changes")
  expect.equal(seen[2], "parked", "in order")

  phase:set("parked")
  expect.equal(#seen, 2, "setting the same value is not a change")

  scope:destroy()
end)

it("an Observer on a Computed sees the derived value", function()
  local scope = reactive.scoped()
  local fuel = scope:Value(51000)
  local low = scope:Computed(function(use)
    return use(fuel) < 800
  end)
  local seen
  scope:Observer(low, function(value)
    seen = value
  end)

  fuel:set(400)
  expect.truthy(seen, "the observer was handed the computed value, not the raw one")
end)

---------------------------------------------------------------------------
-- Failure modes
---------------------------------------------------------------------------

it("a cycle fails loudly rather than hanging", function()
  local scope = reactive.scoped()
  local a
  local b = scope:Computed(function(use)
    return use(a)
  end)
  a = scope:Computed(function(use)
    return use(b)
  end)

  local ok, err = pcall(function()
    return a:get()
  end)
  expect.falsy(ok, "a cycle is an error")
  expect.contains(err, "cyclic", "and says so")
end)

it("a Computed cannot be set", function()
  local scope = reactive.scoped()
  local derived = scope:Computed(function()
    return 1
  end)
  local ok, err = pcall(function()
    derived:set(2)
  end)
  expect.falsy(ok, "refused")
  expect.contains(err, "only a Value", "with a reason")
end)

---------------------------------------------------------------------------
-- Lifetime, which is the whole leak story
---------------------------------------------------------------------------

it("destroying a scope unlinks everything it made", function()
  local outer = reactive.scoped()
  local source = outer:Value(1)

  local before = reactive.live()
  local inner = reactive.scoped()
  local fired = 0
  inner:Observer(source, function()
    fired = fired + 1
  end)

  source:set(2)
  expect.equal(fired, 1, "the observer is live")

  inner:destroy()
  source:set(3)
  expect.equal(fired, 1, "and silent once its scope is gone")
  expect.equal(reactive.live(), before, "with nothing left alive behind it")

  outer:destroy()
end)

it("a child scope dies with its parent", function()
  local parent = reactive.scoped()
  local source = parent:Value(1)
  local child = parent:child()
  local fired = 0
  child:Observer(source, function()
    fired = fired + 1
  end)

  parent:destroy()
  expect.falsy(child:alive(), "the child went with it")
end)

it("opening and closing a screen many times leaks nothing", function()
  -- The dev-mode counter section 15 of the framework plan asks for. A leak here
  -- shows up as a number rather than as a machine that gets slower over an
  -- evening.
  local host = reactive.scoped()
  local shared = host:Value(0)
  local baseline = reactive.live()

  for pass = 1, 10 do
    local screen = reactive.scoped()
    local derived = screen:Computed(function(use)
      return use(shared) + pass
    end)
    screen:Observer(derived, function() end)
    shared:set(pass)
    screen:destroy()
  end

  expect.equal(reactive.live(), baseline, "ten opens and closes leave nothing behind")
  host:destroy()
end)

it("creating in a destroyed scope is refused", function()
  local scope = reactive.scoped()
  scope:destroy()
  local ok, err = pcall(function()
    scope:Value(1)
  end)
  expect.falsy(ok, "refused")
  expect.contains(err, "destroyed scope", "with a reason")
end)
