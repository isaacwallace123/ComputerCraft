--- The retained node tree: bindings in, dirty regions out, one frame at a time.
---
--- This is where the framework earns its place or does not. Section 12 of
--- docs/ui-framework.md measures one changed label at **one** blit and the same
--- change through Basalt 2's design at **81**, and the entire difference is one
--- decision made here.
---
--- ## Invalidate the node, never the root
---
--- Basalt 2 knows exactly which property changed - its property system carries a
--- per-property render flag - and then calls `updateRender`, which walks up the
--- parent chain and marks the root frame dirty. The whole visible tree redraws.
--- The information was there and it was discarded at the last step.
---
--- Here a binding marks **the node it is bound to**, and the frame paints that
--- node's subtree and nothing else. Invalidating upwards is the simplest thing
--- that works and it is the thing not to do; `tools\compare.ps1` is the standing
--- check that it has not crept back in.
---
--- ## Paint-dirty and layout-dirty are not the same
---
--- A colour change cannot move anything, so it repaints and no more. A text
--- change might move things, so it re-measures - and then only re-solves the
--- layout **if the measurement actually changed**. "miner-3" becoming "miner-4"
--- is the same eight cells, so it costs one repaint of one node.
---
--- That last refinement is what makes the common case fast. Classifying `Text`
--- as layout-affecting and stopping there would re-solve and repaint the whole
--- screen on every heartbeat, which is exactly the behaviour being replaced.
---
--- ## Why a repaint takes the whole subtree
---
--- Children paint over their parent, so a parent whose background changed has to
--- redraw everything sitting on it. Repainting the subtree is correct and cheap;
--- being cleverer about it would mean tracking overlap, and the cell diff in
--- `ui/buffer.lua` already removes the cost of painting something that did not
--- change. Paint freely into the back buffer; the diff decides what is sent.

local buffer = require("ui.buffer")
local inputModel = require("ui.input")
local layout = require("ui.layout")
local reactive = require("ui.reactive")

local runtime = {}

---------------------------------------------------------------------------
-- Component registry
---------------------------------------------------------------------------

local registry = {}

--- Register a component.
---
--- `definition.layout` names the properties that can change the node's size.
--- Everything else is assumed to be paint-only, which is the safe default in the
--- cheap direction: mis-marking a layout property as paint-only produces a
--- visibly stale layout, while the reverse merely costs a re-measure. Getting it
--- wrong is therefore obvious rather than silent.
function runtime.define(definition)
  if type(definition.kind) ~= "string" then
    error("a component definition needs a kind", 2)
  end
  if type(definition.paint) ~= "function" then
    error(definition.kind .. ": a component definition needs a paint function", 2)
  end
  definition.layout = definition.layout or {}
  definition.defaults = definition.defaults or {}
  registry[definition.kind] = definition
  return definition
end

function runtime.component(kind)
  return registry[kind]
end

--- Composite components: a function that builds a tree instead of painting one.
---
--- `Page` and `Table` are not shapes on the screen, they are arrangements of
--- shapes, and giving them a `paint` would mean reimplementing the layout solver
--- inside them. A composite runs once, at construction, exactly like the screen
--- that called it - so it is subject to the same rule as everything else here:
--- **it never runs again.** Anything inside it that has to change over time
--- changes through a binding, not by rebuilding the composite.
local composites = {}

-- Forward declaration. `constructorFor` closes over this, and a local declared
-- after it would leave that reference resolving to a global instead - which in
-- Lua is not an error, just a nil call at the first use.
local create

function runtime.compose(kind, builder)
  if type(builder) ~= "function" then
    error(tostring(kind) .. ": a composite needs a builder function", 2)
  end
  composites[kind] = builder
end

local function constructorFor(kind)
  local definition = registry[kind]
  if definition then
    return function(scope, props)
      return create(scope, definition, props)
    end
  end
  local builder = composites[kind]
  if builder then
    return builder
  end
  return nil
end

--- Properties that change geometry whatever the component is, and which force a
--- re-solve rather than a re-measure.
---
--- The distinction is the one thing to understand about this file's dirty model.
--- A *content* property like `Text` is re-measured and only promoted to a full
--- re-solve if the measurement actually moved - that is the optimisation that
--- makes a heartbeat cost one blit. A *structural* property is not measured at
--- all in the relevant sense: `Justify` going from start to end does not change
--- a node's size by one cell, and neither does `Scroll`, and neither does
--- `Align`. Sending those through the measure-and-compare path finds nothing
--- changed and skips the re-solve, so the screen keeps the old arrangement
--- while the property claims to have changed.
---
--- That was a real bug and it was invisible in exactly the way this kind of bug
--- is: a `ScrollView` reported the right offset, re-measured to the same size,
--- decided nothing needed moving, and rendered the top of the list forever.
---
--- A component adds its own content properties - `Text` for a label, `Value` for
--- nothing at all - through `definition.layout`.
local STRUCTURAL = {
  Width = true,
  Height = true,
  Grow = true,
  Gap = true,
  Padding = true,
  Direction = true,
  Align = true,
  Justify = true,
  Children = true,
  Scroll = true,
  Absolute = true,
  Hidden = true,
}

--- The structural properties from `props`, for a composite to put on the node
--- it builds.
---
--- A composite is a function, not a node, so a caller writing
--- `scope:Table { Hidden = ..., Grow = 1 }` is handing those to something that
--- has no obligation to do anything with them - and the first version of every
--- composite here quietly dropped them. `Hidden` on a table did nothing at all,
--- which is a silent failure of the most annoying kind: the property is spelled
--- correctly, the value is right, and nothing happens.
---
--- So a composite spreads this over the root node it returns. Only structural
--- properties, because those are the ones that position a node inside its
--- parent and therefore belong to the caller; anything else a composite accepts
--- is its own vocabulary and is its own business.
function runtime.layoutProps(props, into)
  into = into or {}
  for key in pairs(STRUCTURAL) do
    if key ~= "Children" and props[key] ~= nil then
      into[key] = props[key]
    end
  end
  return into
end

---------------------------------------------------------------------------
-- Nodes
---------------------------------------------------------------------------

--- Every node belongs to a root, so a binding can find the frame to schedule.
--- Set when the tree is mounted rather than at construction, because a subtree
--- is often built before it is attached.
local function attach(node, root)
  node._root = root
  for _, child in ipairs(node.Children) do
    attach(child, root)
  end
end

local function markPaint(node)
  local root = node._root
  if not root then
    return
  end
  root._paint[node] = true
  root._dirty = true
end

local function markMeasure(node)
  local root = node._root
  if not root then
    return
  end
  root._measure[node] = true
  root._paint[node] = true
  root._dirty = true
end

--- Everything moves. For structural properties, where asking whether the size
--- changed answers the wrong question.
local function markLayout(node)
  local root = node._root
  if not root then
    return
  end
  root._relayout = true
  root._dirty = true
end

function create(scope, definition, props)
  props = props or {}

  local node = {
    _kind = definition.kind,
    _def = definition,
    _scope = scope,
    Children = props.Children or {},
    -- Layout asks the node how big it wants to be; the component answers.
    Measure = definition.measure,
  }

  -- Defaults are applied here, at construction, and not in `paint`.
  --
  -- That is not a style preference. `Direction` is read by the layout solver
  -- during measure, which happens before anything paints - a `Column` that set
  -- its own direction while painting would already have been laid out as a row.
  -- Anything a component wants to be true about itself has to be true before
  -- the first measure, so this is the only correct place for it.
  for key, value in pairs(definition.defaults) do
    if props[key] == nil then
      node[key] = value
    end
  end

  for key, value in pairs(props) do
    if key ~= "Children" then
      if reactive.isState(value) then
        node[key] = value:get()
        -- The binding is the entire reason this framework is not React. It
        -- writes one property and marks one node, and no component function
        -- runs again for the life of the tree.
        local structural = STRUCTURAL[key]
        local contentAffectsSize = definition.layout[key]
        scope:_sink(value, function()
          local fresh = value:get()
          -- Invalidation is not change. A `Computed` that reads a whole device
          -- list is invalidated whenever any device reports, but the cell it
          -- feeds usually formats to the same string it had before. Comparing
          -- here is what turns forty invalidated cells into the eleven that
          -- actually moved - and it is the difference between a dashboard that
          -- repaints a row per turtle and one that repaints a row per change.
          if node[key] == fresh then
            return
          end
          node[key] = fresh
          if structural then
            markLayout(node)
          elseif contentAffectsSize then
            markMeasure(node)
          else
            markPaint(node)
          end
        end)
      else
        node[key] = value
      end
    end
  end

  for _, child in ipairs(node.Children) do
    child._parent = node
  end

  return node
end

--- Set a property from outside the binding graph, and schedule the repaint.
---
--- Focus is the reason this exists. It is not application state - no screen
--- should have to hold a `Value` for "which control has the ring" - but it does
--- change how a node paints, so something has to mark the node. Anything a
--- screen genuinely owns should be a `Value` and arrive through a binding
--- instead of through here.
function runtime.set(node, key, value)
  if node[key] == value then
    return false
  end
  node[key] = value
  local definition = node._def
  if STRUCTURAL[key] then
    markLayout(node)
  elseif definition and definition.layout[key] then
    markMeasure(node)
  else
    markPaint(node)
  end
  return true
end

---------------------------------------------------------------------------
-- Scopes that can build nodes
---------------------------------------------------------------------------

local UIScope = {}

--- `scope:New "Text" { … }` for anything registered, and `scope:Text { … }` as
--- the shorthand. Both go through the same constructor.
---
--- Reaching components through the scope rather than as free functions is not
--- decoration: it is what makes lifetime automatic. Every node and every binding
--- a screen creates is owned by the scope that created it, so closing the screen
--- destroys them without the screen having tracked anything. Section 15 of the
--- framework plan calls leaks the price of fine-grained reactivity; this is the
--- price not being paid.
function UIScope:New(kind)
  local constructor = constructorFor(kind)
  if not constructor then
    error("no component named " .. tostring(kind), 2)
  end
  return function(props)
    return constructor(self, props)
  end
end

UIScope.__index = function(_, key)
  local own = rawget(UIScope, key)
  if own ~= nil then
    return own
  end
  local inherited = reactive.Scope[key]
  if inherited ~= nil then
    return inherited
  end
  local constructor = constructorFor(key)
  if constructor then
    UIScope[key] = constructor
    return constructor
  end
  return nil
end

--- The animation driver this scope's springs and tweens run on.
---
--- Created on first use, so a screen with no animation allocates nothing and the
--- host loop's "is anything moving" question answers false without a driver
--- existing at all. Owned by the scope, so closing a page stops its animations
--- along with everything else it made.
function UIScope:_animator()
  if not self._driver then
    self._driver = require("ui.anim").driver()
  end
  return self._driver
end

--- A value that physically follows a goal. See `ui/anim.lua`.
function UIScope:Spring(goal, speed, damping)
  return require("ui.anim").Spring(self, goal, speed, damping)
end

--- A value that eases to a goal over a duration. See `ui/anim.lua`.
function UIScope:Tween(goal, duration, easing)
  return require("ui.anim").Tween(self, goal, duration, easing)
end

--- A scope that can make both state and nodes.
function runtime.scoped()
  return setmetatable(reactive.scoped(), UIScope)
end

---------------------------------------------------------------------------
-- Painting
---------------------------------------------------------------------------

--- The surface a node sits on, which every component needs and none can work
--- out for itself.
---
--- docs/ui-design.md calls this out as the rule that elevation-instead-of-outline
--- forces: with sixteen slots there is not always a spare shade, so a recess has
--- to be chosen relative to what is underneath it. A `muted` meter track on a
--- `muted` selected row is invisible, and that was a real bug before it was a
--- rule.
local function paintSubtree(node, frame, surface)
  if node.Hidden then
    return
  end

  local own = node.Background
  local here = own or surface
  node._surface = here

  local definition = node._def
  if definition.paint then
    definition.paint(node, frame, here)
  end

  -- A clipping container narrows the buffer for its subtree and restores it
  -- after. The clip is pushed *after* the node paints its own background, so a
  -- scrolling panel still fills its whole box while its contents are masked to
  -- it - which is what makes the empty part of a short list look like the panel
  -- rather than like a hole.
  local clipped = node.Clip and node._w > 0 and node._h > 0
  if clipped then
    frame:clip(node._x, node._y, node._w, node._h)
  end

  for _, child in ipairs(node.Children) do
    paintSubtree(child, frame, here)
  end

  if clipped then
    frame:unclip()
  end
end

---------------------------------------------------------------------------
-- The root
---------------------------------------------------------------------------

local Root = {}
Root.__index = Root

--- Mount a tree against a screen.
---
--- `build` is called once and never again. That is the whole point of the
--- Fusion model and it is worth stating in the place a reader will look for a
--- re-render hook: there isn't one.
function runtime.mount(options)
  local screen = assert(options.screen, "mount needs a screen port")
  local scope = assert(options.scope, "mount needs a scope")

  local width, height = screen.size()
  local root = setmetatable({
    screen = screen,
    scope = scope,
    palette = options.palette,
    frame = buffer.new(screen, width, height),
    _paint = {},
    _measure = {},
    _dirty = true,
    _relayout = true,
    background = options.background or 15,
    onError = options.onError,
  }, Root)

  root.tree = options.build(scope)
  attach(root.tree, root)
  return root
end

function Root:size()
  return self.frame:size()
end

--- Re-read the screen size and lay out again. Called on `term_resize`, and on
--- nothing else - a resize is the only thing that can change the space without
--- changing the tree.
function Root:resize()
  if self.frame:resize() then
    self._relayout = true
    self._dirty = true
  end
  return self
end

--- Repaint everything from scratch next frame. For after something outside the
--- framework has written to the same terminal.
function Root:invalidate()
  self.frame:invalidate()
  self._relayout = true
  self._dirty = true
  return self
end

--- Is there anything to do? An app's event loop uses this to decide whether to
--- bother, and an idle screen answers false forever.
function Root:pending()
  return self._dirty
end

--- Step any running animations to `now`, in milliseconds, and report whether
--- anything is still moving.
---
--- Takes the time rather than reading a clock, so a spec can advance an
--- animation by exactly one tick and assert where it got to. It also means the
--- framework needs no clock port of its own - the host that already has one
--- passes the number in.
---
--- Answers false with no work at all when the scope never made an animation,
--- which is the common case and has to stay free: a fleet dashboard that
--- animates nothing must not pay a frame timer for the possibility.
function Root:advance(now)
  local driver = rawget(self.scope, "_driver")
  if not driver then
    return false
  end
  return driver:advance(now)
end

--- Is anything mid-animation? The host loop asks before deciding whether to wake
--- on a timer or block on the next event.
function Root:animating()
  local driver = rawget(self.scope, "_driver")
  return driver ~= nil and driver:busy()
end

--- One frame. Returns the number of blit calls it took, which is the number the
--- specs and the bench assert on.
---
--- Returns 0 immediately when nothing is dirty, so calling this every time round
--- an event loop costs a table lookup on a settled screen.
function Root:render()
  if not self._dirty then
    return 0
  end

  local relayout = self._relayout

  -- Re-measure the nodes whose size-affecting properties changed, and promote to
  -- a full re-solve only if a measurement actually moved. This is the step that
  -- keeps a heartbeat cheap: the same eight characters in a different order
  -- measure the same, so nothing below here happens.
  if next(self._measure) then
    for node in pairs(self._measure) do
      local wasW, wasH = node._measuredW, node._measuredH
      layout.measure(node)
      if node._measuredW ~= wasW or node._measuredH ~= wasH then
        relayout = true
      end
      self._measure[node] = nil
    end
  end

  local width, height = self.frame:size()

  -- Any clip left over from a component that threw halfway through painting is
  -- dropped here rather than being carried into the next frame, where it would
  -- mask unrelated content and look like the missing part was never drawn.
  self.frame:resetClip()

  if relayout then
    -- Everything may have moved, so everything is repainted. The cell diff makes
    -- the parts that did not actually change free, so this is not the disaster
    -- it would be against a renderer that sends what it is told to.
    layout.solve(self.tree, 1, 1, width, height)
    self.frame:clear(0, self.background)
    paintSubtree(self.tree, self.frame, self.background)
    self._paint = {}
  else
    for node in pairs(self._paint) do
      -- A targeted repaint starts partway down the tree, so the clips its
      -- ancestors would have pushed are not in force. They have to be replayed,
      -- outermost first, or a row scrolled off the top of a panel repaints
      -- itself over whatever is above the panel.
      --
      -- This is the one place where painting a subtree in isolation is not the
      -- same as painting it in context, and it is worth the walk: without it the
      -- bug appears only when something scrolled changes, which is a long way
      -- from where anyone would look.
      local clips = {}
      local ancestor = node._parent
      while ancestor do
        if ancestor.Clip and ancestor._w > 0 and ancestor._h > 0 then
          table.insert(clips, 1, ancestor)
        end
        ancestor = ancestor._parent
      end
      for _, container in ipairs(clips) do
        self.frame:clip(container._x, container._y, container._w, container._h)
      end

      paintSubtree(node, self.frame, node._surface or self.background)

      for _ = 1, #clips do
        self.frame:unclip()
      end
      self._paint[node] = nil
    end
  end

  self._relayout = false
  self._dirty = false
  return self.frame:present()
end

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

--- Move the focus ring, repainting only the two nodes that changed.
---
--- Focus is a property of a node, not a search performed at paint time, so
--- moving it costs exactly two repaints however large the tree is. Both are
--- one-cell changes in practice - a button's leading pad - so a full pass around
--- a form's tab ring costs about what one label changing costs.
function Root:focus(node)
  if self.focused == node then
    return self.focused
  end
  if self.focused then
    runtime.set(self.focused, "Focused", false)
  end
  self.focused = node
  if node then
    runtime.set(node, "Focused", true)
  end
  return self.focused
end

--- Every focusable node, recomputed on demand rather than cached.
---
--- The ring changes whenever a button is disabled or a panel is hidden, both of
--- which are bound properties that can move at any time. Walking the tree costs
--- a few dozen table reads and happens only on a keypress, where nothing is
--- watching; a cached ring would have to be invalidated from places that have no
--- business knowing focus exists.
function Root:focusRing()
  return inputModel.focusables(self.tree)
end

function Root:moveFocus(step)
  return self:focus(inputModel.nextFocus(self:focusRing(), self.focused, step))
end

--- Fire a handler, tolerating a screen that throws.
---
--- An app's click handler is application code and may be wrong. Letting it take
--- the UI down means a typo in one button leaves a fleet dashboard frozen on a
--- wall, so the error is caught, reported through `onError` when the composition
--- root supplied one, and the frame carries on. Same reasoning as the service
--- supervisor in docs/icos-2.md section 8: one broken thing must not stop the
--- machine.
---
--- A handler that explicitly returns `false` is saying it did not want the
--- event, which lets it fall through to whatever is underneath.
function Root:_fire(handler, node, event)
  local ok, result = pcall(handler, node, event)
  if not ok then
    if self.onError then
      self.onError(result, node)
    end
    return true
  end
  return result ~= false
end

--- Route one normalised event into the tree. Returns whether anything took it.
---
--- The order is deliberate. A pointer goes to what is under it; a key goes to
--- what has focus and then bubbles up; nothing else is guessed at. Tab is
--- handled before the tree sees it, because a screen that had to implement its
--- own tab order would implement a different one on every page.
function Root:dispatch(event)
  if event.kind == "resize" then
    self:resize()
    return true
  end

  if event.kind == "pointer" then
    local node = inputModel.hit(self.tree, event.x, event.y)
    if not node then
      return false
    end

    if event.phase == "scroll" then
      local target = inputModel.bubble(node, "OnScroll")
      return target ~= nil and self:_fire(target.OnScroll, target, event)
    end

    if event.phase == "down" then
      -- Focus follows the press rather than the release, so a control looks
      -- focused while it is being held. A monitor touch produces both at once
      -- and the distinction costs nothing there.
      local focusable = inputModel.bubble(node, "Focusable")
      if focusable and not focusable.Disabled then
        self:focus(focusable)
      end
      local target = inputModel.bubble(node, "OnPress")
      return target ~= nil and self:_fire(target.OnPress, target, event)
    end

    if event.phase == "up" then
      local target = inputModel.bubble(node, "OnClick")
      if target and not target.Disabled then
        return self:_fire(target.OnClick, target, event)
      end
      return false
    end

    if event.phase == "drag" then
      local target = inputModel.bubble(node, "OnDrag")
      return target ~= nil and self:_fire(target.OnDrag, target, event)
    end
    return false
  end

  if event.kind == "key" and event.down then
    if event.key == inputModel.KEY.leftShift or event.key == inputModel.KEY.rightShift then
      self.shifted = true
      return true
    end
    if event.key == inputModel.KEY.tab then
      self:moveFocus(self.shifted and -1 or 1)
      return true
    end
    -- Enter and space activate whatever holds the ring. This is the only way a
    -- keyboard reaches a button, and it is what keeps a screen usable on a
    -- turtle, which has no mouse at all.
    local focused = self.focused
    if
      focused
      and focused.OnClick
      and not focused.Disabled
      and (event.key == inputModel.KEY.enter or event.key == inputModel.KEY.space)
    then
      return self:_fire(focused.OnClick, focused, event)
    end
    local target = inputModel.bubble(focused or self.tree, "OnKey")
    return target ~= nil and self:_fire(target.OnKey, target, event)
  end

  if event.kind == "key" then
    if event.key == inputModel.KEY.leftShift or event.key == inputModel.KEY.rightShift then
      self.shifted = false
      return true
    end
    return false
  end

  if event.kind == "char" then
    local target = inputModel.bubble(self.focused or self.tree, "OnChar")
    return target ~= nil and self:_fire(target.OnChar, target, event)
  end

  -- Everything else - a rednet message, a timer, an ICOS app event - is offered
  -- to the tree unchanged. The framework does not need to know what those are
  -- for a screen to be able to act on one.
  local target = inputModel.bubble(self.tree, "OnEvent")
  return target ~= nil and self:_fire(target.OnEvent, target, event)
end

--- Normalise a raw event from the input port and dispatch everything it became.
--- A monitor touch becomes two.
function Root:handle(name, ...)
  local handled = false
  for _, event in ipairs(inputModel.normalise(name, ...)) do
    handled = self:dispatch(event) or handled
  end
  return handled
end

--- Tear down the tree and its bindings. Closing an app calls this; not calling
--- it is the leak.
function Root:destroy()
  self.scope:destroy()
  self.focused = nil
  self.tree = nil
  self._paint = {}
  self._measure = {}
  self._dirty = false
end

runtime.STRUCTURAL = STRUCTURAL

return runtime
