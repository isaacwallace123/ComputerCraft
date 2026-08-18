--- Containers, and the two ways of showing depth.
---
--- docs/ui-design.md argues the case for elevation over outline at length; the
--- short version is that a drawn `+---+` border is a full cell wide, which is
--- the same size as a letter, so it reads as heavier than the content it
--- surrounds. On the web a card edge is thinner than its text and that is what
--- makes it quiet. There is no thinner here.
---
--- So `Card` is a rectangle one step lighter than the page with no edge at all,
--- and `Separator` is a single row of `border` used where a change of elevation
--- would be too strong. Between them they are the whole vocabulary of depth, and
--- neither costs a cell of chrome.

local runtime = require("ui.core.runtime")
local theme = require("ui.theme")

local T = theme.TOKENS

--- Fill a node's box, or do nothing when it has no background.
---
--- A container with no `Background` is transparent, which matters more than it
--- sounds: a `Row` that filled its box would erase the surface underneath it and
--- every nested row would repaint the same cells. Transparent by default means
--- structure is free and only the components that mean to show something pay.
local function fill(node, frame)
  local background = node.Background
  if not background then
    return
  end
  if node._w <= 0 or node._h <= 0 then
    return
  end
  frame:fill(node._x, node._y, node._w, node._h, " ", node.Color or T.foreground, background)
end

--- The generic container. Everything else here is this with a default applied.
runtime.define({
  kind = "Box",
  defaults = { Direction = "column" },
  paint = fill,
})

runtime.define({
  kind = "Row",
  defaults = { Direction = "row" },
  paint = fill,
})

runtime.define({
  kind = "Column",
  defaults = { Direction = "column" },
  paint = fill,
})

--- An overlay: a dialog, a toast, a menu.
---
--- `Absolute` takes it out of the flow, so it is laid out over its parent's whole
--- inner box and contributes nothing to its parent's size. That second half
--- matters more than it sounds: a modal that made its page as tall as the dialog
--- inside it would shove the page's own content around every time one opened.
---
--- It clips, because a dialog whose contents overflow should be a dialog with
--- something missing rather than a dialog leaking over the page behind it.
runtime.define({
  kind = "Overlay",
  defaults = { Direction = "column", Absolute = true, Clip = true, Background = T.card },
  paint = fill,
})

--- A raised surface: one step lighter than the page, no drawn edge.
---
--- The elevation is a default rather than something the caller supplies, so that
--- every card in ICOS is the same card. A caller that passes `Background`
--- explicitly gets what it asked for, which is how a card nested inside another
--- steps up again to `muted`.
runtime.define({
  kind = "Card",
  defaults = { Direction = "column", Background = T.card },
  paint = fill,
})

--- Flexible empty space. Paints nothing and grows by default, which is what
--- makes `Row { Text, Spacer, Button }` push the button to the right without
--- anybody computing a width.
runtime.define({
  kind = "Spacer",
  measure = function()
    return 0, 0
  end,
  paint = function() end,
})

--- A hairline. One row of `border` as a background - the closest a cell grid
--- gets to the 1-pixel rule it is standing in for.
---
--- Its height is fixed at 1 and not exposed, because a two-row separator is not
--- a heavier hairline, it is a stripe, and there is no design in ICOS that wants
--- one.
runtime.define({
  kind = "Separator",
  measure = function()
    return 0, 1
  end,
  paint = function(node, frame)
    if node._w <= 0 then
      return
    end
    frame:fill(node._x, node._y, node._w, 1, " ", T.border, node.Color or T.border)
  end,
})

--- A panel whose contents can be taller than it is.
---
--- `Scroll` is how far the contents have been pushed up, in cells. The children
--- keep their sizes and the container keeps its box; only the origin moves. So a
--- scroll costs no re-measure and cannot put the layout into a state that the
--- unscrolled version would not also reach - which is the same reasoning D033
--- records for a table's slot offset, applied to arbitrary content instead of
--- rows.
---
--- Clipping is the part a table did not need. A table only ever draws the rows
--- it means to; a scrolled column genuinely has content above and below its box
--- and would paint over its neighbours without a mask.
runtime.define({
  kind = "ScrollView",
  defaults = { Direction = "column", Clip = true },
  paint = fill,
})
