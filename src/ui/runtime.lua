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

--- Properties that change geometry whatever the component is. A component adds
--- its own - `Text` for a label, `Value` for nothing at all - through
--- `definition.layout`.
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
}

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
        local layoutAffecting = STRUCTURAL[key] or definition.layout[key]
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
          if layoutAffecting then
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
  local own = node.Background
  local here = own or surface
  node._surface = here

  local definition = node._def
  if definition.paint then
    definition.paint(node, frame, here)
  end

  for _, child in ipairs(node.Children) do
    paintSubtree(child, frame, here)
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
      paintSubtree(node, self.frame, node._surface or self.background)
      self._paint[node] = nil
    end
  end

  self._relayout = false
  self._dirty = false
  return self.frame:present()
end

--- Tear down the tree and its bindings. Closing an app calls this; not calling
--- it is the leak.
function Root:destroy()
  self.scope:destroy()
  self.tree = nil
  self._paint = {}
  self._measure = {}
  self._dirty = false
end

runtime.STRUCTURAL = STRUCTURAL

return runtime
