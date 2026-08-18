--- State objects, and the graph that connects them to what they change.
---
--- The Fusion model rather than the React one, for the reason set out in
--- section 3 of docs/ui-framework.md: a state change updates the one property
--- bound to it, and no component function runs again. There is no re-render
--- because there is nothing to re-render - the graph already knows what changed.
---
--- ## Dependencies are declared, not captured
---
--- `Computed(function(use) return use(fuel) < 800 end)`. The `use` is the
--- declaration. Fusion 0.2 captured dependencies implicitly by watching which
--- states were read; 0.3 made it explicit, and this follows 0.3 for two
--- reasons. Implicit capture in plain Lua means every `get` has to consult a
--- global "who is currently evaluating" register, which is exactly the kind of
--- hidden coupling that makes a bug in one screen appear in another. And a
--- reader of the code can see the dependency set without running it.
---
--- ## Setting a value does not paint
---
--- `:set()` invalidates. It marks every dependent `Computed` stale and collects
--- the sinks - observers and node bindings - that ultimately care. Observers run
--- at once, because they are side effects the application asked for and delaying
--- one changes its meaning. Node bindings only mark their node dirty; the
--- painting happens on the next frame.
---
--- That split is what makes twenty values changing in one heartbeat produce one
--- frame rather than twenty. Without it, fine-grained reactivity is slower than
--- repainting everything, not faster.
---
--- ## Recomputation is lazy
---
--- An invalidated `Computed` does not recompute when its input changes; it
--- recomputes the next time somebody reads it. A chain of five `Computed`s
--- feeding one label costs one evaluation of each per frame no matter how many
--- times the underlying value was set in between.
---
--- ## Lifetime is the scope, and it is not optional
---
--- Every object here holds a reference to the objects it depends on and is held
--- by them in turn, so nothing is collectable while its dependency is alive. A
--- component that subscribes to a service and is never torn down keeps that
--- service's updates flowing into dead nodes forever. `scope:destroy()` unlinks
--- everything the scope made, and closing an app must call it. `reactive.live()`
--- returns the number of objects currently alive so a leak shows up as a number
--- rather than as a machine that gets slower over an evening.

local reactive = {}

local VALUE = "value"
local COMPUTED = "computed"
local SINK = "sink"

--- Live object count, for the leak check named in section 15 of the framework
--- plan. Incremented on construction, decremented on destroy.
local liveCount = 0

function reactive.live()
  return liveCount
end

---------------------------------------------------------------------------
-- The graph
---------------------------------------------------------------------------

--- Break the link between a dependent and everything it currently depends on.
---
--- Called before every recomputation, not only on destroy: a `Computed` whose
--- body takes a branch reads a different set of states each time, and leaving
--- the old edges in place would make it wake for changes it no longer cares
--- about. That is not merely wasteful - a stale edge to a state that was itself
--- destroyed is a reference that keeps a whole dead subgraph alive.
local function unlink(dependent)
  for dependency in pairs(dependent._dependencies) do
    dependency._dependents[dependent] = nil
    dependent._dependencies[dependency] = nil
  end
end

--- Walk everything downstream of a changed state, marking `Computed`s stale and
--- collecting the sinks that have to act.
---
--- `seen` is what keeps this linear rather than exponential on a diamond-shaped
--- graph: two paths to the same node traverse it once.
---
--- It is a per-pass set rather than the `_stale` flag, and that distinction is
--- load-bearing. Using staleness as the stop condition looks equivalent and is
--- not: a `Computed` that nobody read stays stale after the first change, so the
--- second change would find it already marked, stop there, and never reach the
--- observers beyond it. Traversal control and value validity are two different
--- questions and conflating them silently drops notifications.
local function invalidate(state, sinks, seen)
  for dependent in pairs(state._dependents) do
    if dependent._kind == COMPUTED then
      if not seen[dependent] then
        seen[dependent] = true
        dependent._stale = true
        invalidate(dependent, sinks, seen)
      end
    else
      sinks[dependent] = true
    end
  end
end

local function notify(state)
  local sinks = {}
  invalidate(state, sinks, {})
  for sink in pairs(sinks) do
    if sink._alive then
      sink._notify()
    end
  end
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

local State = {}
State.__index = State

--- Read without declaring a dependency.
---
--- Correct inside an event handler, which runs once and does not need to be
--- woken again. Wrong inside a `Computed`, where it produces a value that never
--- updates - which is a silent failure, so prefer `use` and reach for this
--- deliberately.
function State:get()
  if self._kind == COMPUTED and self._stale then
    self:_recompute()
  end
  return self._value
end

function State:set(value)
  if self._kind ~= VALUE then
    error("only a Value can be set; this is a " .. self._kind, 2)
  end
  if not self._alive then
    error("set on a destroyed Value", 2)
  end
  -- Identity, not deep equality. A table whose contents changed is a different
  -- value even though it is the same reference, and the framework cannot know
  -- which the caller meant - so replacing a list means handing over a new table,
  -- and mutating one in place will not be noticed. Deep comparison here would
  -- cost a walk of every device record on every heartbeat to discover what the
  -- caller already knew.
  if self._value == value then
    return false
  end
  self._value = value
  notify(self)
  return true
end

--- Cycle detection, which has to happen here rather than at construction: the
--- graph is built by running the bodies, so a cycle only exists once one of them
--- reads its own output. Failing loudly with the chain named beats hanging.
function State:_recompute()
  if self._computing then
    error("cyclic Computed: " .. table.concat(self._chain or { "?" }, " -> "), 0)
  end
  self._computing = true
  unlink(self)

  local chain = { self._name or "Computed" }
  local ok, result = pcall(self._compute, function(dependency)
    if type(dependency) ~= "table" or not dependency._kind then
      -- Passing a plain value through `use` is common and harmless - it lets a
      -- component accept either a state object or a constant for the same
      -- property without the caller branching.
      return dependency
    end
    dependency._dependents[self] = true
    self._dependencies[dependency] = true
    chain[#chain + 1] = dependency._name or dependency._kind
    return dependency:get()
  end)

  self._computing = false
  self._chain = chain
  if not ok then
    self._stale = false
    error(result, 0)
  end
  self._value = result
  self._stale = false
end

function reactive.isState(value)
  return type(value) == "table" and getmetatable(value) == State
end

--- Read a property that may or may not be reactive.
---
--- Components take `Color = theme.muted` and `Color = someComputed` through the
--- same argument, so every read site needs this. It is the reason a component
--- never has to ask whether it was given a constant.
function reactive.peek(value)
  if reactive.isState(value) then
    return value:get()
  end
  return value
end

---------------------------------------------------------------------------
-- Scopes
---------------------------------------------------------------------------

--- Subscribe a sink, and make sure there is a graph to subscribe to.
---
--- A `Computed` builds its dependency edges by running, and it does not run
--- until somebody reads it. So a sink attached to one that has never been
--- evaluated would be attached to a node with no inputs, and a change upstream
--- would reach nothing. Forcing one evaluation here is what connects it.
---
--- The cost is that attaching an observer evaluates its chain once, immediately.
--- That is the right trade: an observer exists because the value matters, and
--- the alternative is a subscription that silently never fires.
local function attachSink(sink, state)
  if state._kind == COMPUTED and state._stale then
    state:get()
  end
  state._dependents[sink] = true
  sink._dependencies[state] = true
end

local Scope = {}
Scope.__index = Scope

--- A lifetime. Everything made through it dies with it.
function reactive.scoped()
  return setmetatable({ _owned = {}, _alive = true }, Scope)
end

function Scope:_own(object)
  if not self._alive then
    error("cannot create in a destroyed scope", 3)
  end
  self._owned[#self._owned + 1] = object
  liveCount = liveCount + 1
  return object
end

local function newState(scope, kind, name)
  return scope:_own(setmetatable({
    _kind = kind,
    _name = name,
    _alive = true,
    _dependents = {},
    _dependencies = {},
  }, State))
end

--- Mutable state.
function Scope:Value(initial, name)
  local state = newState(self, VALUE, name)
  state._value = initial
  return state
end

--- Derived state. `fn` receives `use`; every state it reads through `use`
--- becomes a dependency.
function Scope:Computed(fn, name)
  if type(fn) ~= "function" then
    error("Computed needs a function", 2)
  end
  local state = newState(self, COMPUTED, name)
  state._compute = fn
  state._stale = true
  return state
end

--- Run `fn` when `state` changes. Not called on creation - an observer reports
--- transitions, and a caller that wants the current value already has it.
function Scope:Observer(state, fn)
  if not reactive.isState(state) then
    error("Observer needs a state object", 2)
  end
  local sink = self:_own({
    _kind = SINK,
    _alive = true,
    _dependents = {},
    _dependencies = {},
  })
  sink._notify = function()
    fn(state:get())
  end
  attachSink(sink, state)
  return sink
end

--- The primitive the node runtime binds with. `onChange` is called when the
--- watched state changes, and is expected to be cheap: it marks something dirty
--- rather than doing the work.
function Scope:_sink(state, onChange)
  local sink = self:_own({
    _kind = SINK,
    _alive = true,
    _dependents = {},
    _dependencies = {},
  })
  sink._notify = onChange
  attachSink(sink, state)
  return sink
end

--- A child lifetime. Destroying the parent destroys it, which is what lets a
--- list give each row its own scope without the caller tracking them.
function Scope:child()
  local child = reactive.scoped()
  self:_own(child)
  return child
end

--- Unlink everything and mark it dead.
---
--- Order matters: a sink is unlinked before the states it watched, so nothing
--- can be notified halfway through its own teardown. Objects are marked dead as
--- well as unlinked, because a caller may still hold a reference and using one
--- afterwards should fail where the mistake is rather than silently do nothing.
function Scope:destroy()
  if not self._alive then
    return
  end
  self._alive = false
  for index = #self._owned, 1, -1 do
    local object = self._owned[index]
    if getmetatable(object) == Scope then
      object:destroy()
    else
      unlink(object)
      for dependent in pairs(object._dependents) do
        dependent._dependencies[object] = nil
      end
      object._dependents = {}
      object._alive = false
      liveCount = liveCount - 1
    end
    self._owned[index] = nil
  end
end

function Scope:alive()
  return self._alive
end

reactive.Scope = Scope

return reactive
