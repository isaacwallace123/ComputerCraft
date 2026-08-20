--- Springs and tweens, which are state objects like any other.
---
--- That sentence is the whole design. §8 of docs/ui-framework.md is short
--- because §7 already did the work: a `Spring` is a value that moves towards a
--- goal, so anything that can consume a value can consume an animated one, and
--- animating a colour needs no different code from setting it.
---
---     Width = scope:Spring(scope:Computed(function(use)
---       return use(selected) and 24 or 12
---     end), 25, 1)
---
--- There is no `animate()` call, no timeline for the common case, and nothing
--- for a component to opt into. A `Meter` bound to a spring animates; the meter
--- does not know.
---
--- ## An idle screen must cost nothing
---
--- The hard requirement, not an optimisation. A settled spring removes itself
--- from the driver, and a driver with nothing in flight tells the host loop to
--- block on the next event rather than wake on a timer. So a dashboard at rest
--- is purely event-driven and costs zero, on a server that is also reconciling
--- ten turtles - which is the machine this has to be affordable on.
---
--- The failure this avoids is subtle: an animation system that ticks
--- unconditionally looks free in a test and shows up in production as a base
--- station that never idles, competing for the 5ms scheduling slice §2 describes
--- with the fleet service beside it.
---
--- ## Time comes from a clock port
---
--- `advance(now)` takes the time rather than reading it, so a spec can step an
--- animation by exactly 50ms and assert where it got to. Physics that read a
--- clock directly can only be tested by sleeping, which is how a suite becomes
--- slow and flaky at the same time.

local reactive = require("ui.state.reactive")

local anim = {}

--- Below this, a spring is close enough and stops.
---
--- One hundredth of a cell. The screen is a character grid, so anything under
--- half a cell is invisible - but a spring driving a colour or a fraction is not
--- measured in cells, so the threshold is well below what any consumer can
--- render rather than tuned to one of them.
anim.EPSILON = 0.01

--- One tick. The frame interval while anything is in flight, and the shortest
--- one CC can honour: `os.startTimer` rounds up to the next multiple of 0.05, so
--- asking for less gets 0.05 anyway and only obscures the intent.
anim.FRAME = 0.05

--- The largest slice a spring is integrated over, whatever the frame took.
---
--- This is not a quality setting, it is a stability limit, and it is the single
--- least obvious thing in this file. A frame here is 50ms, which is enormous for
--- a spring: at speed 25 the term `speed^2 * dt^2` comes to 1.56, the integrator
--- gains energy every step instead of losing it, and the value oscillates wider
--- and wider until it is in the thousands. It never settles, so the driver never
--- empties, so the host loop never goes back to blocking - a runaway animation
--- becomes a machine that spins at 20 FPS forever.
---
--- That is not hypothetical. Section 8 of docs/ui-framework.md gives
--- `Spring(goal, 25, 1)` as its worked example, and the first version of this
--- file integrated it in one 50ms step and diverged on the second frame.
---
--- Splitting each frame into slices of at most 1/60s puts `speed^2 * dt^2` at
--- 0.17 for the same spring and leaves headroom to about speed 50. Three
--- sub-steps per frame of arithmetic on a handful of numbers is nothing; the
--- alternative is a stability limit nobody discovers until they pick a speed
--- slightly too high and the screen shakes itself apart.
anim.MAX_STEP = 1 / 60

---------------------------------------------------------------------------
-- Easings
---------------------------------------------------------------------------

--- The four §8 names, and no more.
---
--- Every one of these is chosen to read well at 10-15 FPS, which is the ceiling
--- §2 establishes. `easeInOut` on a 250ms transition is about four frames; an
--- easing with more character than these would spend its character on frames
--- that do not exist.
anim.easings = {
  linear = function(t)
    return t
  end,

  easeOut = function(t)
    return 1 - (1 - t) * (1 - t)
  end,

  easeInOut = function(t)
    if t < 0.5 then
      return 2 * t * t
    end
    return 1 - 2 * (1 - t) * (1 - t)
  end,

  -- A small overshoot. Deliberately small: at four frames a large one reads as a
  -- glitch rather than as bounce.
  back = function(t)
    local s = 1.70158
    local u = t - 1
    return u * u * ((s + 1) * u + s) + 1
  end,
}

---------------------------------------------------------------------------
-- The driver
---------------------------------------------------------------------------

local Driver = {}
Driver.__index = Driver

function anim.driver()
  return setmetatable({ active = {}, _last = nil }, Driver)
end

function Driver:add(animation)
  self.active[animation] = true
end

function Driver:remove(animation)
  self.active[animation] = nil
end

--- Is anything still moving? The host loop asks this to decide whether to wake
--- on a timer or block on the next event.
function Driver:busy()
  return next(self.active) ~= nil
end

--- Step every animation to `now`, in milliseconds. Returns whether anything is
--- still in flight.
---
--- The first call establishes a baseline rather than stepping, because the time
--- between a screen being built and its first frame is not animation time - it
--- is however long the machine took to boot, and integrating across it would
--- snap every spring straight to its goal.
function Driver:advance(now)
  if self._last == nil then
    self._last = now
    return self:busy()
  end

  local dt = (now - self._last) / 1000
  self._last = now

  if dt <= 0 then
    return self:busy()
  end
  -- A machine that was paused - a chunk unloaded, a server hitch - comes back
  -- with a huge delta. Clamping means an animation resumes rather than teleports,
  -- and 100ms is two ticks, which is the longest step that still integrates
  -- stably at these spring speeds.
  if dt > 0.1 then
    dt = 0.1
  end

  for animation in pairs(self.active) do
    if animation:_step(dt) then
      self.active[animation] = nil
    end
  end

  return self:busy()
end

---------------------------------------------------------------------------
-- Spring
---------------------------------------------------------------------------

local Spring = {}
Spring.__index = Spring

--- Integrate one step of a damped spring.
---
--- Semi-implicit Euler: velocity is updated from the current position, then the
--- position from the *new* velocity. The explicit form - both from the old
--- values - gains energy at large steps and oscillates wider instead of
--- settling, which on a screen looks like a value that will not stop twitching.
function Spring:_step(dt)
  local goal = self._goalValue
  local speed, damping = self._speed, self._damping

  -- Sub-stepped for stability, never for smoothness: see `anim.MAX_STEP`. The
  -- frame rate is what it is, and a spring that took one 50ms step at any useful
  -- speed would diverge rather than settle.
  local remaining = dt
  while remaining > 0 do
    local step = remaining > anim.MAX_STEP and anim.MAX_STEP or remaining
    local acceleration = (goal - self._position) * speed * speed
      - self._velocity * 2 * speed * damping
    self._velocity = self._velocity + acceleration * step
    self._position = self._position + self._velocity * step
    remaining = remaining - step
  end

  local settled = math.abs(goal - self._position) < anim.EPSILON
    and math.abs(self._velocity) < anim.EPSILON

  if settled then
    self._position = goal
    self._velocity = 0
  end

  -- Once per frame, not once per sub-step: the sub-steps are an integration
  -- detail and nothing downstream should see three notifications for one frame.
  self._state:set(self._position)
  return settled
end

--- A value that physically follows a goal.
---
--- `goal` may be a plain number or a state object. When it is a state, the
--- spring re-targets whenever it changes - including mid-flight, which is the
--- entire reason to use a spring rather than a tween for anything a person can
--- change their mind about halfway through.
---
--- Returns the state object, not the spring. Nothing downstream should be able
--- to reach the physics; a component that could call `:set()` on a spring would
--- be fighting it every frame.
function anim.Spring(scope, goal, speed, damping)
  local driver = scope:_animator()
  local initial = reactive.peek(goal)

  local spring = setmetatable({
    _speed = speed or 20,
    _damping = damping or 1,
    _position = initial,
    _velocity = 0,
    _goalValue = initial,
    _state = scope:Value(initial),
  }, Spring)

  if reactive.isState(goal) then
    scope:_sink(goal, function()
      local fresh = goal:get()
      if fresh == spring._goalValue then
        return
      end
      spring._goalValue = fresh
      driver:add(spring)
    end)
  end

  spring._state._spring = spring
  return spring._state
end

---------------------------------------------------------------------------
-- Tween
---------------------------------------------------------------------------

local Tween = {}
Tween.__index = Tween

--- How close to the end counts as the end.
---
--- Accumulated floating point never lands on a round number: six 50ms steps sum
--- to 0.24999999999999997, not 0.25, so `elapsed >= duration` is false on the
--- frame that should have finished. The tween then interpolates to
--- 99.99999999999999 and stays active for another frame.
---
--- That matters more than the arithmetic suggests. A `Width` bound to a value a
--- whisker under 24 renders as 23 cells - forever, because the next frame lands
--- on the goal but the layout has already settled - and the bug reads as an
--- off-by-one in the solver rather than as an animation that never quite
--- arrived. A spring avoids this by assigning its goal outright when it settles;
--- a tween needs a tolerance because its clock is the thing being compared.
---
--- A nanosecond is far below any real frame and far above the accumulated error
--- of a few thousand steps.
local ARRIVED = 1e-9

function Tween:_step(dt)
  self._elapsed = self._elapsed + dt

  if self._duration <= 0 or self._elapsed + ARRIVED >= self._duration then
    self._state:set(self._goalValue)
    return true
  end

  local eased = self._easing(self._elapsed / self._duration)
  self._state:set(self._from + (self._goalValue - self._from) * eased)
  return false
end

--- A value that eases to a goal over a fixed duration.
---
--- Use a spring for anything interruptible and a tween when the timing itself is
--- the point - a toast that shows for exactly 300ms, a staggered deal. A tween
--- that is re-targeted mid-flight restarts from where it currently is rather
--- than from its original start, so the result is still continuous; it just
--- takes the full duration again.
---
--- `duration` is in seconds. §8's motion budget: 150ms for state feedback,
--- 250-300ms for transitions, and nothing continuous except a deliberate pulse
--- on an alert. Longer than that reads as jank at 20 FPS rather than as grace.
function anim.Tween(scope, goal, duration, easing)
  local driver = scope:_animator()
  local initial = reactive.peek(goal)
  local ease = type(easing) == "function" and easing or anim.easings[easing or "easeOut"]

  local tween = setmetatable({
    _duration = duration or 0.25,
    _easing = ease or anim.easings.easeOut,
    _from = initial,
    _goalValue = initial,
    _elapsed = 0,
    _state = scope:Value(initial),
  }, Tween)

  if reactive.isState(goal) then
    scope:_sink(goal, function()
      local fresh = goal:get()
      if fresh == tween._goalValue then
        return
      end
      tween._from = tween._state:get()
      tween._goalValue = fresh
      tween._elapsed = 0
      driver:add(tween)
    end)
  end

  return tween._state
end

return anim
