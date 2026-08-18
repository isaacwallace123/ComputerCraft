--- The flex solver, over plain tables.
---
--- No nodes, no reactivity, no screen - the solver takes sizes and returns
--- boxes, so every one of these is arithmetic with an expected answer. The
--- rounding cases are the ones worth having: a column that changes width by one
--- depending on rounding luck looks like a broken border, and it is the sort of
--- thing that is invisible until somebody builds a monitor of an awkward size.

local expect = require("support.expect")
local it = require("support.spec").it

local layout = require("ui.layout")

--- A leaf of a fixed intrinsic size.
local function leaf(width, height, extra)
  local node = {
    Measure = function()
      return width, height
    end,
  }
  for key, value in pairs(extra or {}) do
    node[key] = value
  end
  return node
end

local function boxOf(node)
  local x, y, w, h = layout.box(node)
  return ("%d,%d %dx%d"):format(x, y, w, h)
end

---------------------------------------------------------------------------
-- Measuring
---------------------------------------------------------------------------

it("a leaf measures itself and a container sums its children", function()
  local row = {
    Children = { leaf(4, 1), leaf(6, 1), leaf(2, 1) },
  }
  local width, height = layout.measure(row)
  expect.equal(width, 12, "widths add along a row")
  expect.equal(height, 1, "height is the tallest")
end)

it("gap and padding are part of the measurement", function()
  local row = {
    Gap = 2,
    Padding = 1,
    Children = { leaf(4, 1), leaf(6, 1) },
  }
  local width, height = layout.measure(row)
  expect.equal(width, 14, "4 + 6, one gap of 2, one cell of padding each side")
  expect.equal(height, 3, "one row plus padding above and below")
end)

it("a column stacks instead of adding", function()
  local column = {
    Direction = "column",
    Children = { leaf(4, 1), leaf(9, 2) },
  }
  local width, height = layout.measure(column)
  expect.equal(width, 9, "width is the widest")
  expect.equal(height, 3, "heights add")
end)

it("an explicit size is a promise, not a preference", function()
  -- A table column that says it is 12 wide has to be 12 wide whatever the text
  -- inside it does, or the columns below it stop lining up.
  local node = leaf(40, 1, { Width = 12 })
  local width = layout.measure(node)
  expect.equal(width, 12, "the declared width wins over the measured one")
end)

---------------------------------------------------------------------------
-- Arranging
---------------------------------------------------------------------------

it("children are placed in order with the gap between them", function()
  local a, b, c = leaf(4, 1), leaf(6, 1), leaf(2, 1)
  local row = { Gap = 1, Children = { a, b, c } }
  layout.solve(row, 1, 1, 20, 1)

  expect.equal(boxOf(a), "1,1 4x1", "first")
  expect.equal(boxOf(b), "6,1 6x1", "after a gap")
  expect.equal(boxOf(c), "13,1 2x1", "and another")
end)

it("padding moves the content in and shrinks the space", function()
  local child = leaf(0, 0, { Grow = 1 })
  local box = { Padding = 2, Children = { child } }
  layout.solve(box, 1, 1, 20, 5)
  expect.equal(boxOf(child), "3,3 16x1", "inset on every edge")
end)

it("grow takes what is left", function()
  local fixed, flexible = leaf(6, 1), leaf(0, 1, { Grow = 1 })
  local row = { Children = { fixed, flexible } }
  layout.solve(row, 1, 1, 20, 1)

  expect.equal(boxOf(fixed), "1,1 6x1", "fixed keeps its size")
  expect.equal(boxOf(flexible), "7,1 14x1", "the rest goes to the grower")
end)

it("two growers split evenly and the remainder goes leftmost", function()
  -- 51 cells across three growers is 17 each. 50 is 17, 17, 16 - and which
  -- child loses the cell has to be decided, not discovered.
  local a, b, c = leaf(0, 1, { Grow = 1 }), leaf(0, 1, { Grow = 1 }), leaf(0, 1, { Grow = 1 })
  local row = { Children = { a, b, c } }

  layout.solve(row, 1, 1, 51, 1)
  expect.equal(
    boxOf(a) .. " " .. boxOf(b) .. " " .. boxOf(c),
    "1,1 17x1 18,1 17x1 35,1 17x1",
    "51 divides"
  )

  layout.solve(row, 1, 1, 50, 1)
  expect.equal(boxOf(a), "1,1 17x1", "the leftmost keeps the odd cell")
  expect.equal(boxOf(c), "35,1 16x1", "the rightmost gives it up")
end)

it("weighted growers divide in proportion", function()
  local one, three = leaf(0, 1, { Grow = 1 }), leaf(0, 1, { Grow = 3 })
  layout.solve({ Children = { one, three } }, 1, 1, 40, 1)
  expect.equal(boxOf(one), "1,1 10x1", "one part")
  expect.equal(boxOf(three), "11,1 30x1", "three parts")
end)

it("the same tree in the same space always gives the same boxes", function()
  -- Determinism matters more than fairness: a layout that drifted by a cell
  -- between solves would turn a no-op repaint into a full-screen change.
  local function build()
    return { Gap = 1, Children = { leaf(0, 1, { Grow = 2 }), leaf(5, 1), leaf(0, 1, { Grow = 1 }) } }
  end
  local first, second = build(), build()
  layout.solve(first, 1, 1, 37, 1)
  layout.solve(second, 1, 1, 37, 1)
  for index = 1, 3 do
    expect.equal(boxOf(first.Children[index]), boxOf(second.Children[index]), "child " .. index)
  end
end)

---------------------------------------------------------------------------
-- Justify and align
---------------------------------------------------------------------------

it("justify positions the content when nothing grows", function()
  local function row(mode)
    local a, b = leaf(4, 1), leaf(4, 1)
    layout.solve({ Justify = mode, Children = { a, b } }, 1, 1, 20, 1)
    return a, b
  end

  local a = row("start")
  expect.equal(boxOf(a), "1,1 4x1", "start")

  a = row("center")
  expect.equal(boxOf(a), "7,1 4x1", "center")

  a = row("end")
  expect.equal(boxOf(a), "13,1 4x1", "end")

  local first, second = row("between")
  expect.equal(boxOf(first), "1,1 4x1", "between puts the first at the start")
  expect.equal(boxOf(second), "17,1 4x1", "and the last at the end")
end)

it("align positions across the axis", function()
  local child = leaf(4, 1, { Align = "center" })
  layout.solve({ Children = { child } }, 1, 1, 20, 5)
  expect.equal(boxOf(child), "1,3 4x1", "centred vertically in a row")
end)

it("stretch is the default across the axis", function()
  local child = leaf(4, 1)
  layout.solve({ Children = { child } }, 1, 1, 20, 5)
  expect.equal(boxOf(child), "1,1 4x5", "a table cell fills its row's height")
end)

it("a fixed size on the main axis does not pin the cross axis", function()
  -- The two axes are tested separately, and folding them into one expression is
  -- wrong in a way that reads as correct. A `Width` in a row says nothing about
  -- height; treating it as if it did left a one-cell selection gutter at zero
  -- height, painting nothing, which looked like a reactivity bug for a while.
  local inRow = leaf(0, 0, { Width = 1 })
  layout.solve({ Children = { inRow } }, 1, 1, 20, 3)
  expect.equal(boxOf(inRow), "1,1 1x3", "a fixed width still stretches in height")

  local inColumn = leaf(0, 0, { Height = 1 })
  layout.solve({ Direction = "column", Children = { inColumn } }, 1, 1, 20, 3)
  expect.equal(boxOf(inColumn), "1,1 20x1", "and a fixed height still stretches in width")
end)

it("an explicit cross-axis size is respected", function()
  local child = leaf(4, 1, { Height = 1 })
  layout.solve({ Children = { child } }, 1, 1, 20, 5)
  expect.equal(boxOf(child), "1,1 4x1", "a declared height is not stretched away")
end)

---------------------------------------------------------------------------
-- Degenerate cases, which a dashboard on a pocket computer hits constantly
---------------------------------------------------------------------------

it("a box too small for its children clamps rather than going negative", function()
  local a, b = leaf(20, 1), leaf(20, 1)
  layout.solve({ Children = { a, b } }, 1, 1, 10, 1)

  local _, _, widthA = layout.box(a)
  local _, _, widthB = layout.box(b)
  expect.truthy(widthA >= 0 and widthB >= 0, "no negative widths")
  expect.equal(widthA, 20, "the first keeps its measured size and the second is pushed off")
end)

it("a zero-width box is assigned, not dropped", function()
  -- A component asked to paint nothing paints nothing. A node with no box at
  -- all would make every painter test for it.
  local child = leaf(0, 0)
  layout.solve({ Children = { child } }, 1, 1, 0, 0)
  expect.equal(boxOf(child), "1,1 0x0", "still has a box")
end)

it("an empty container is laid out without complaint", function()
  local node = { Children = {} }
  layout.solve(node, 1, 1, 10, 3)
  expect.equal(boxOf(node), "1,1 10x3", "and takes the space it was given")
end)
