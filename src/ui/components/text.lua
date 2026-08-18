--- Text, and the two things every screen writes with it.
---
--- `Text` is a single line. There is no wrapping, on purpose: a wrapped label
--- changes height, a changed height re-solves the layout, and a layout that
--- re-solves when a fuel reading gets a digit longer is the thing this framework
--- exists to avoid. Multi-line content is a `Column` of `Text`, which makes the
--- cost visible at the call site where somebody can decide whether to pay it.

local runtime = require("ui.runtime")
local theme = require("ui.theme")
local util = require("ui.util")

local T = theme.TOKENS

--- One line, measured by its own content.
---
--- `Text` is declared layout-affecting, so changing it re-measures - but the
--- runtime only re-solves the layout if the measurement actually moved. That is
--- what makes "miner-3" becoming "miner-4" cost one repaint of one node rather
--- than a full screen.
runtime.define({
  kind = "Text",
  layout = { Text = true },

  measure = function(node)
    return #tostring(node.Text or ""), 1
  end,

  paint = function(node, frame, surface)
    local x, y, width, height = node._x, node._y, node._w, node._h
    if width <= 0 or height <= 0 then
      return
    end
    local background = node.Background or surface
    local colour = node.Color or T.foreground
    -- The whole box is written, not just the text. A shorter string than last
    -- frame would otherwise leave its own tail behind, and the cell diff makes
    -- the padding free when it has not changed.
    frame:write(x, y, util.pad(node.Text, width, node.TextAlign), colour, background)
  end,
})

--- A page or section title. Same painting as `Text`; a separate component so
--- that what a heading looks like is decided once, here, rather than at every
--- call site that happens to want a title.
---
--- On a character grid a heading cannot be larger, so it is distinguished by
--- being `foreground` where everything around it is `mutedFg`, and by the
--- whitespace a `Page` puts around it. Restraint is not a style choice at this
--- resolution; it is the only tool available.
runtime.define({
  kind = "Heading",
  layout = { Text = true },

  measure = function(node)
    return #tostring(node.Text or ""), 1
  end,

  paint = function(node, frame, surface)
    if node._w <= 0 or node._h <= 0 then
      return
    end
    frame:write(
      node._x,
      node._y,
      util.pad(node.Text, node._w, node.TextAlign),
      node.Color or T.foreground,
      node.Background or surface
    )
  end,
})

--- Secondary text: hints, units, column headings, a parked turtle's status.
--- Exactly `Text` in `mutedFg`, named so that "this is less important" is a
--- thing a screen says rather than a colour it picks.
runtime.define({
  kind = "Muted",
  layout = { Text = true },

  measure = function(node)
    return #tostring(node.Text or ""), 1
  end,

  paint = function(node, frame, surface)
    if node._w <= 0 or node._h <= 0 then
      return
    end
    frame:write(
      node._x,
      node._y,
      util.pad(node.Text, node._w, node.TextAlign),
      node.Color or T.mutedFg,
      node.Background or surface
    )
  end,
})
