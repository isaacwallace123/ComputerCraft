--- A flexbox subset, solved into integer cell rectangles.
---
--- Pure arithmetic over plain tables. It knows nothing about reactivity, nodes,
--- painting, or the screen - hand it a tree of sizes and it hands back boxes,
--- which is what makes it the easiest part of the framework to test and the part
--- most likely to still be correct in a year.
---
--- ## Two passes
---
--- `measure` walks bottom-up and asks every node how big it wants to be.
--- `arrange` walks top-down and tells every node how big it actually is. That is
--- the standard shape and it is the only one that works when a container's size
--- depends on its children and a child's size depends on its container, which is
--- exactly what `Grow` is.
---
--- ## Integers, and where the remainder goes
---
--- There are no fractional cells. Three columns sharing 51 cells is 17 each;
--- three columns sharing 50 is 17, 17, 16. The rule is **the remainder goes to
--- the leftmost growing children, one cell each**, and it is written down
--- because the alternative is a column that changes width by one depending on
--- rounding luck, which on a table with a border looks like the border is
--- broken.
---
--- Determinism matters more than fairness here: the same tree in the same space
--- must always produce the same boxes, or a repaint that should have been a
--- no-op becomes a full-screen change.
---
--- ## What is deliberately missing
---
--- No wrapping, no grid, no percentages, no shrink below the measured size
--- except by clipping. A dashboard and a card table do not need them, and each
--- one is a solver of its own. See section 6 of docs/ui-framework.md.

local layout = {}

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if high and value > high then
    return high
  end
  return value
end

--- Padding is one number, or a table of the four edges. One number is the common
--- case by a wide margin, and on a 51-column screen the number is almost always
--- 1, so the short form is the one that keeps a component definition readable.
local function padding(node)
  local value = node.Padding
  if type(value) == "number" then
    return value, value, value, value
  end
  if type(value) == "table" then
    return value.left or 0, value.right or 0, value.top or 0, value.bottom or 0
  end
  return 0, 0, 0, 0
end

local function isRow(node)
  return node.Direction ~= "column"
end

---------------------------------------------------------------------------
-- Measure
---------------------------------------------------------------------------

--- How big does this node want to be, ignoring what it will be given?
---
--- A leaf answers through `Measure`, which the component supplies - a label
--- measures its own text, a meter has no opinion and takes what it is given.
--- A container answers by summing its children along the main axis and taking
--- the largest across it.
---
--- `Width` and `Height` override the answer entirely. A fixed size is a promise,
--- not a preference; a column that says it is 12 wide is 12 wide whatever the
--- text inside it does, because that is what makes a table's columns line up.
function layout.measure(node)
  local children = node.Children
  local left, right, top, bottom = padding(node)

  local intrinsicW, intrinsicH = 0, 0

  if children and #children > 0 then
    local gap = node.Gap or 0
    local row = isRow(node)
    local mainTotal, crossMax = 0, 0
    local counted = 0

    for _, child in ipairs(children) do
      layout.measure(child)
      -- An absolute child is measured but contributes nothing to its parent's
      -- size, because it is not in the flow. A modal that made its page as tall
      -- as the dialog inside it would push the page's own content around every
      -- time the dialog opened.
      if not child.Absolute then
        local childMain = row and child._measuredW or child._measuredH
        local childCross = row and child._measuredH or child._measuredW
        counted = counted + 1
        mainTotal = mainTotal + childMain
        if counted > 1 then
          mainTotal = mainTotal + gap
        end
        if childCross > crossMax then
          crossMax = childCross
        end
      end
    end

    -- How tall the children actually are, kept for scrolling: a container needs
    -- to know how far past its own box its contents run in order to clamp.
    node._contentW, node._contentH = row and mainTotal or crossMax, row and crossMax or mainTotal

    if row then
      intrinsicW, intrinsicH = mainTotal, crossMax
    else
      intrinsicW, intrinsicH = crossMax, mainTotal
    end
  elseif node.Measure then
    intrinsicW, intrinsicH = node.Measure(node)
  end

  intrinsicW = intrinsicW + left + right
  intrinsicH = intrinsicH + top + bottom

  node._measuredW = math.floor(node.Width or intrinsicW)
  node._measuredH = math.floor(node.Height or intrinsicH)
  return node._measuredW, node._measuredH
end

---------------------------------------------------------------------------
-- Arrange
---------------------------------------------------------------------------

--- Hand out the free space along the main axis.
---
--- Growing children divide what is left after the fixed ones. The division is
--- integer, and the remainder is handed out one cell at a time from the left -
--- see the note at the top of the file about why the rule is written down rather
--- than left to `math.floor`.
local function distribute(children, sizes, free)
  local totalGrow = 0
  for _, child in ipairs(children) do
    totalGrow = totalGrow + (child.Grow or 0)
  end
  if totalGrow <= 0 or free <= 0 then
    return free
  end

  local handed = 0
  for index, child in ipairs(children) do
    local grow = child.Grow or 0
    if grow > 0 then
      local share = math.floor(free * grow / totalGrow)
      sizes[index] = sizes[index] + share
      handed = handed + share
    end
  end

  local remainder = free - handed
  for index, child in ipairs(children) do
    if remainder <= 0 then
      break
    end
    if (child.Grow or 0) > 0 then
      sizes[index] = sizes[index] + 1
      handed = handed + 1
      remainder = remainder - 1
    end
  end

  return free - handed
end

--- Where the content starts, and how much extra sits between each child, once
--- the growers have taken their share. Only meaningful when nothing grew: a
--- single `Grow = 1` consumes the free space and every justification collapses
--- to `start`, which is usually what a caller wanted anyway.
local function justify(mode, free, count)
  if free <= 0 or count <= 0 then
    return 0, 0
  end
  if mode == "center" then
    return math.floor(free / 2), 0
  end
  if mode == "end" then
    return free, 0
  end
  if mode == "between" and count > 1 then
    return 0, math.floor(free / (count - 1))
  end
  return 0, 0
end

local function alignOffset(mode, free)
  if free <= 0 then
    return 0
  end
  if mode == "center" then
    return math.floor(free / 2)
  end
  if mode == "end" then
    return free
  end
  return 0
end

--- Place `node` and everything under it inside the given rectangle.
---
--- The box is assigned even when it is empty or negative in one dimension, and
--- clamped to zero rather than dropped. A component asked to paint a zero-width
--- box paints nothing, which is the correct behaviour for a column squeezed off
--- the edge of a pocket computer - and much easier to reason about than a node
--- with no box at all, which every painter would then have to test for.
function layout.arrange(node, x, y, width, height)
  node._x, node._y = math.floor(x), math.floor(y)
  node._w, node._h = math.max(0, math.floor(width)), math.max(0, math.floor(height))

  local children = node.Children
  if not children or #children == 0 then
    return
  end

  local left, right, top, bottom = padding(node)
  local innerX = node._x + left
  local innerY = node._y + top
  local innerW = math.max(0, node._w - left - right)
  local innerH = math.max(0, node._h - top - bottom)

  local row = isRow(node)
  local gap = node.Gap or 0
  local mainSpace = row and innerW or innerH
  local crossSpace = row and innerH or innerW

  -- Absolute children are laid out over the parent's whole inner box and take
  -- no part in the flow. This is what a modal, an overlay and a toast all need,
  -- and it is deliberately the only escape from the flow the solver offers.
  local flow = {}
  for _, child in ipairs(children) do
    if child.Absolute then
      layout.arrange(child, innerX, innerY, innerW, innerH)
    else
      flow[#flow + 1] = child
    end
  end
  if #flow == 0 then
    return
  end

  local sizes = {}
  local used = 0
  for index, child in ipairs(flow) do
    sizes[index] = row and child._measuredW or child._measuredH
    used = used + sizes[index]
  end
  used = used + gap * math.max(0, #flow - 1)

  local free = mainSpace - used
  free = distribute(flow, sizes, free)

  local offset, spacing = justify(node.Justify, free, #flow)
  -- Scrolling shifts where the children start and nothing else. The container
  -- keeps its box, the children keep their sizes, and only the origin moves -
  -- which is why a scroll costs no re-measure and cannot put the layout into a
  -- state the unscrolled version would not also have reached.
  local cursor = (row and innerX or innerY) + offset - (node.Scroll or 0)

  for index, child in ipairs(flow) do
    local main = clamp(sizes[index], 0)
    -- Cross-axis sizing. `stretch` is the default because it is what a row of
    -- table cells wants, and a component that does not want it says so with an
    -- explicit size on the cross axis.
    --
    -- Which axis that is depends on the direction, and the two have to be tested
    -- separately. Folding them into one `and`/`or` expression reads fine and is
    -- wrong: in a row it would find a child's `Width`, conclude the cross axis
    -- was pinned, and leave the height at its measured zero. A one-cell selection
    -- gutter then painted nothing at all, which looked like a reactivity bug and
    -- was not.
    local cross, fixedCross
    if row then
      cross, fixedCross = child._measuredH, child.Height
    else
      cross, fixedCross = child._measuredW, child.Width
    end

    local align = child.Align or node.Align or "stretch"
    if align == "stretch" and not fixedCross then
      cross = crossSpace
    end
    cross = clamp(cross, 0, crossSpace)
    local crossOffset = align == "stretch" and 0 or alignOffset(align, crossSpace - cross)

    if row then
      layout.arrange(child, cursor, innerY + crossOffset, main, cross)
    else
      layout.arrange(child, innerX + crossOffset, cursor, cross, main)
    end

    cursor = cursor + main + gap + spacing
  end
end

--- Measure then arrange, which is what a caller almost always wants.
function layout.solve(node, x, y, width, height)
  layout.measure(node)
  layout.arrange(node, x, y, width, height)
  return node
end

--- The rectangle a node ended up with. Separate from the private fields so a
--- component painter has one documented way to ask, and so the internals can
--- change without every component changing with them.
function layout.box(node)
  return node._x or 1, node._y or 1, node._w or 0, node._h or 0
end

return layout
