--- Buttons, badges, and meters.
---
--- Between them these carry most of what a fleet dashboard says, and all three
--- follow the same two rules from docs/ui-design.md: a variant is a named
--- intent rather than a set of properties, and anything that recesses or raises
--- takes the surface it sits on so it can pick a shade that contrasts with it.

local runtime = require("ui.runtime")
local theme = require("ui.theme")
local util = require("ui.util")

local T = theme.TOKENS

---------------------------------------------------------------------------
-- Button
---------------------------------------------------------------------------

--- Four variants, which turns out to be enough.
---
--- `primary` in dark is a near-white slab with dark text - the brightest thing
--- on the screen, so the eye goes to it, which is what a primary action is for.
--- `destructive` is the only variant allowed to be a colour, and that is what
--- makes it read as a warning: put three coloured buttons on a page and none of
--- them means anything.
---
--- A `nil` background means "whatever you are sitting on", which is what makes
--- `ghost` disappear into a dense row.
local VARIANTS = {
  primary = { fg = T.primaryFg, bg = T.primary },
  secondary = { fg = T.foreground, bg = T.muted },
  ghost = { fg = T.mutedFg, bg = nil },
  destructive = { fg = T.primaryFg, bg = T.destructive },
}

--- One cell of padding each side. There is no `lg`: on fifty-one columns a large
--- button is a full-width button, which is a layout decision (`Grow = 1`) rather
--- than a size.
local SIZES = {
  sm = 1,
  md = 2,
}

runtime.define({
  kind = "Button",
  layout = { Text = true, Size = true },

  measure = function(node)
    local pad = SIZES[node.Size] or SIZES.md
    return #tostring(node.Text or "") + pad * 2, 1
  end,

  paint = function(node, frame, surface)
    local x, y, width, height = node._x, node._y, node._w, node._h
    if width <= 0 or height <= 0 then
      return
    end

    local variant = VARIANTS[node.Variant] or VARIANTS.secondary
    local background = variant.bg or surface
    local colour = variant.fg

    -- Disabled is a state, not a variant: any variant can be disabled, and it
    -- always looks the same - recessed and muted - so that "cannot be pressed"
    -- reads identically wherever it appears.
    if node.Disabled then
      background = surface == T.muted and T.border or T.muted
      colour = T.mutedFg
    end

    frame:write(x, y, util.pad(node.Text, width, "center"), colour, background)

    -- The focus ring, one cell in the leading pad rather than an outline.
    --
    -- An outline would cost a row above and below and two columns, which on a
    -- 51-cell screen is most of a button. Reusing the padding cell costs nothing
    -- and - the property that matters - **moving focus never changes any node's
    -- size**, so tabbing through a form cannot re-solve the layout.
    if node.Focused and not node.Disabled then
      frame:write(x, y, " ", T.accentFg, T.accent)
    end
  end,
})

---------------------------------------------------------------------------
-- Badge
---------------------------------------------------------------------------

--- A short status word on a recessed chip.
---
--- The word is the message and the colour is reinforcement, never the other way
--- round. A non-advanced terminal flattens the palette to greyscale, so a badge
--- that said only "green" would say nothing at all there - which is why every
--- badge in ICOS carries text and why `Tone` has no default meaning attached.
runtime.define({
  kind = "Badge",
  layout = { Text = true },

  measure = function(node)
    return #tostring(node.Text or "") + 2, 1
  end,

  paint = function(node, frame, surface)
    if node._w <= 0 or node._h <= 0 then
      return
    end
    local background = node.Background or (surface == T.muted and T.border or T.muted)
    frame:write(
      node._x,
      node._y,
      util.pad(" " .. tostring(node.Text or "") .. " ", node._w, "center"),
      node.Tone or T.mutedFg,
      background
    )
  end,
})

---------------------------------------------------------------------------
-- Meter
---------------------------------------------------------------------------

--- A horizontal bar, 0 to 1. No border, no percentage: the width is the number.
---
--- The track colour is picked from the surface rather than fixed, and this is
--- the rule elevation-instead-of-outline makes mandatory. A `muted` track on a
--- `muted` selected row is invisible - the first version of the design preview
--- had exactly that bug and the selected turtle silently lost its fuel bar. On
--- the web there is always another shade of grey to reach for. With sixteen
--- slots there is not, so every component that recesses is told what it is
--- sitting on.
---
--- `Value` is not layout-affecting: a meter takes whatever width it is given, so
--- a fuel reading ticking down repaints one node and moves nothing.
runtime.define({
  kind = "Meter",
  layout = {},

  measure = function()
    return 0, 1
  end,

  paint = function(node, frame, surface)
    local x, y, width = node._x, node._y, node._w
    if width <= 0 or node._h <= 0 then
      return
    end

    local track = node.Track or (surface == T.muted and T.border or T.muted)
    local fraction = math.max(0, math.min(1, tonumber(node.Value) or 0))
    local filled = math.floor(fraction * width + 0.5)

    -- A non-zero reading always shows at least one cell. Rounding a 2% fuel
    -- level down to nothing draws an empty track, which looks exactly like a
    -- turtle reporting nothing at all - and those two need to be told apart at a
    -- glance more than the bar needs to be proportionally honest.
    if filled == 0 and fraction > 0 then
      filled = 1
    end

    frame:fill(x, y, width, 1, " ", T.foreground, track)
    if filled > 0 then
      frame:fill(x, y, filled, 1, " ", T.foreground, node.Tint or T.accent)
    end
  end,
})
