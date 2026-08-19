--- Buttons, badges, and meters.
---
--- Between them these carry most of what a fleet dashboard says, and all three
--- follow the same two rules from docs/ui-design.md: a variant is a named
--- intent rather than a set of properties, and anything that recesses or raises
--- takes the surface it sits on so it can pick a shade that contrasts with it.

local inputModel = require("ui.input")
local reactive = require("ui.state.reactive")
local runtime = require("ui.runtime")
local theme = require("ui.theme")
local format = require("ui.format")

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

--- A button is focusable unless it is disabled, which is decided per node rather
--- than here: `Disabled` is usually a `Computed`, so a button can drop out of
--- the tab ring the moment nothing is selected without anybody rebuilding the
--- ring. `input.focusables` re-reads it on every keypress for exactly that
--- reason.
runtime.define({
  kind = "Button",
  defaults = { Focusable = true },
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

    frame:write(x, y, format.pad(node.Text, width, "center"), colour, background)

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
-- Field
---------------------------------------------------------------------------

--- One line of typed text.
---
--- The framework went without one for a long time and that was defensible while
--- every screen was a dashboard. It stopped being defensible the moment ICOS 2
--- needed a console, a setup flow, and a coordinate prompt: **every remaining
--- interactive app is blocked on being able to type**, and without this each
--- would have grown its own `read()` loop over the top of a running page.
---
--- ## It holds no text, and that is why it works
---
--- `Value` is the current string, bound like any other property, and `OnChange`
--- is called with what it should become. The caller owns the state.
---
--- That is not a stylistic choice - it is forced, and the reason is worth
--- knowing. `runtime.define` resolves *every* property that is a state object
--- before paint, so a field handed a `Value` state would see the string and
--- never the object, and could not write back to it. Rather than carve an
--- exception into the binding graph for one component, the data flows the way
--- it already does everywhere else: down as a value, back as a call.
---
--- ## No cursor movement, and that is a decision
---
--- Left, right, home and end are not bound. A monitor has no keyboard at all
--- (D032: a touch is a whole tap, and hover does not exist), and the surfaces
--- that do have one are typing a coordinate or a one-word command, not editing
--- prose. Backspace and Enter are the whole interaction, which keeps this
--- usable on a turtle - and adding arrows later costs nothing, because the
--- caller's state does not change shape.
---
--- Enter reaches `OnSubmit`, never `OnClick`. The runtime fires `OnClick` on the
--- focused node for enter **and space**, so a field that submitted through it
--- would be a field that cannot type a space.
runtime.define({
  kind = "Field",
  defaults = {
    Focusable = true,

    --- Typing. Every printable character arrives here, one at a time.
    OnChar = function(node, event)
      if node.Disabled or type(node.OnChange) ~= "function" then
        return false
      end
      local text = tostring(node.Value or "")
      local limit = tonumber(node.MaxLength)
      if limit and #text >= limit then
        return true
      end
      node.OnChange(text .. tostring(event.char or ""))
      return true
    end,

    --- Backspace and enter. Everything else is left alone so that a screen can
    --- still bind its own keys while a field has focus.
    OnKey = function(node, event)
      if node.Disabled then
        return false
      end
      local text = tostring(node.Value or "")

      if event.key == inputModel.KEY.backspace then
        if type(node.OnChange) == "function" and #text > 0 then
          node.OnChange(text:sub(1, #text - 1))
        end
        return true
      end

      if event.key == inputModel.KEY.enter then
        if type(node.OnSubmit) == "function" then
          node.OnSubmit(text)
        end
        return true
      end

      return false
    end,
  },
  layout = { Size = true },

  measure = function(node)
    -- Fields grow. A width in cells would be a guess about a screen this does
    -- not know the size of, so the floor is small and the row decides.
    return tonumber(node.Width) or 8, 1
  end,

  paint = function(node, frame, surface)
    local x, y, width = node._x, node._y, node._w
    if width <= 0 or (node._h or 0) <= 0 then
      return
    end

    local text = tostring(node.Value or "")
    local background = surface == T.muted and T.border or T.muted
    local colour = node.Disabled and T.mutedFg or T.foreground

    -- The tail, not the head. A line longer than the field scrolls so what is
    -- being typed stays visible; showing the first N characters would hide it.
    local room = node.Focused and width - 1 or width
    if #text > room then
      text = text:sub(#text - room + 1)
    end

    local shown = text
    if #text == 0 and not node.Focused and node.Placeholder then
      shown = tostring(node.Placeholder)
      colour = T.mutedFg
    end

    frame:write(x, y, format.pad(shown, width, "left"), colour, background)

    -- The caret is a filled cell rather than a character, so it reads the same
    -- on a monitor that cannot blink and in a screenshot.
    if node.Focused and not node.Disabled then
      frame:write(x + math.min(#text, width - 1), y, " ", T.accentFg, T.accent)
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
      format.pad(" " .. tostring(node.Text or "") .. " ", node._w, "center"),
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

---------------------------------------------------------------------------
-- Stepper
---------------------------------------------------------------------------

--- The shape the three settings controls share.
---
--- `Stepper`, `Select` and `Toggle` are one family and look like it: a label
--- that takes the slack, a value in `accent`, and small ghost controls on the
--- right. Written once so that a settings page reads as one thing rather than as
--- three components that happen to be adjacent - which is the entire argument
--- for a design system over a widget collection.
---
--- **One tab stop, two ways to use it.** The row is focusable and the buttons
--- are deliberately not. A person with a mouse presses them; a person on a
--- turtle tabs to the row and uses left and right. Focus still lands on the row
--- when a button is clicked, because `Focusable` bubbles: the button answers
--- falsy and the row above it answers true.
---
--- Making the buttons focusable would put three stops on every setting, so a
--- page of six would take eighteen presses to cross.
local function controlRow(scope, props, value, adjust, glyphs)
  local function onKey(_, event)
    local KEY = require("ui.input").KEY
    if event.key == KEY.left then
      return adjust(-1)
    end
    if event.key == KEY.right then
      return adjust(1)
    end
    return false
  end

  local function arrow(text, direction)
    return scope:Button({
      Text = text,
      Size = "sm",
      Variant = "ghost",
      Focusable = false,
      Disabled = props.Disabled,
      OnClick = function()
        return adjust(direction)
      end,
    })
  end

  return scope:Row(runtime.layoutProps(props, {
    Height = 1,
    Gap = 1,
    Focusable = true,
    Disabled = props.Disabled,
    OnKey = onKey,
    Children = {
      scope:Muted({ Text = props.Label or "", Grow = 1 }),
      value,
      arrow(glyphs[1], -1),
      arrow(glyphs[2], 1),
    },
  }))
end

--- A labelled number with minus and plus.
---
--- The whole of the fleet's configuration UI is this: vein budget, scan
--- interval, target depth, branch spacing. `src/apps/devices.lua` draws it by
--- hand and carries a `compact = width < 42` branch that recomputes four column
--- positions - which is the "does this fit on a pocket computer" arithmetic
--- section 1 of docs/ui-framework.md says the framework exists to delete. There
--- is none of it here; the label grows and the rest is fixed.
---
--- `Value` is read for display and `OnChange` is the intent. The stepper never
--- writes the value itself, because in the real app changing a setting sends a
--- `configure` message to a parked turtle and the screen decides whether to
--- apply it optimistically.
runtime.compose("Stepper", function(scope, props)
  props = props or {}
  local step = props.Step or 1

  local function adjust(direction)
    -- `peek`, not a bare truth test. A composite receives the raw props, so
    -- `props.Disabled` is usually a `Computed` - a table, and therefore truthy
    -- whether it currently reads true or false. `if props.Disabled then` looked
    -- right, passed review, and disabled every stepper on the page permanently.
    --
    -- The rule for any composite: a prop read imperatively goes through
    -- `reactive.peek`. A prop handed to a node does not, because the binding
    -- resolves it.
    if reactive.peek(props.Disabled) then
      return false
    end

    local current = tonumber(reactive.peek(props.Value)) or 0
    local wanted = current + direction * step
    if props.Min and wanted < props.Min then
      wanted = props.Min
    end
    if props.Max and wanted > props.Max then
      wanted = props.Max
    end
    if wanted == current then
      return false
    end
    if props.OnChange then
      props.OnChange(wanted)
    end
    return true
  end

  local value = scope:Text({
    Width = props.ValueWidth or 6,
    TextAlign = "right",
    Text = scope:Computed(function(use)
      return tostring(use(props.Value) or 0)
    end),
    Color = scope:Computed(function(use)
      return use(props.Disabled) and T.mutedFg or T.accent
    end),
  })

  return controlRow(scope, props, value, adjust, { "-", "+" })
end)

---------------------------------------------------------------------------
-- Select
---------------------------------------------------------------------------

--- One of a fixed list, cycled rather than dropped down.
---
--- `src/apps/devices.lua` changes a turtle's job by cycling through `JOB_ORDER`
--- on each press, and that is the right shape here rather than a shortcut it
--- took. A dropdown needs somewhere to drop: on a 51-column screen it covers the
--- thing being configured, and on a monitor it is a floating panel a touch can
--- miss entirely, with no hover to hint that it opened. Cycling is
--- discoverable, needs no space, and works identically on all three surfaces.
---
--- The cost is that a long list is tedious. Four or five options is the working
--- limit; past that the list wants a page of its own.
runtime.compose("Select", function(scope, props)
  props = props or {}

  local function adjust(direction)
    if reactive.peek(props.Disabled) then
      return false
    end
    local list = reactive.peek(props.Options) or {}
    if #list == 0 then
      return false
    end

    local current = reactive.peek(props.Value)
    local index = 1
    for position, option in ipairs(list) do
      if option == current then
        index = position
        break
      end
    end

    -- Wraps, like the focus ring and for the same reason: a person cycling a
    -- four-item list should not have to know which end they are at, and a
    -- monitor touch has only the two buttons to work with.
    local wanted = list[(index - 1 + direction) % #list + 1]
    if wanted == current then
      return false
    end
    if props.OnChange then
      props.OnChange(wanted)
    end
    return true
  end

  local value = scope:Text({
    Width = props.ValueWidth or 10,
    TextAlign = "right",
    Text = scope:Computed(function(use)
      local current = use(props.Value)
      if current == nil then
        return props.Empty or "none"
      end
      return tostring(current)
    end),
    Color = scope:Computed(function(use)
      return use(props.Disabled) and T.mutedFg or T.accent
    end),
  })

  return controlRow(scope, props, value, adjust, { "<", ">" })
end)

---------------------------------------------------------------------------
-- Toggle
---------------------------------------------------------------------------

--- A boolean, shown as a word on a coloured chip.
---
--- The five fleet policy flags are these: auto-recovery enabled, resume after
--- refuel, retry the depot, retry setup preflight, update parked turtles. Every
--- one of them changes what a fleet does unattended, so the state has to be
--- readable across a room - which rules out the usual switch drawn from two
--- cells, where on and off differ by which end is lit and neither reads at
--- distance.
---
--- So it says "on" or "off". `accent` when on, recessed when off, and the word
--- carries it on a non-advanced terminal where both are grey - see
--- docs/ui-design.md on never encoding meaning in colour alone.
---
--- Left and right both flip it rather than one meaning on and the other off. A
--- toggle has no direction, and mapping the two arrows onto two states would
--- make repeated presses do nothing half the time.
runtime.compose("Toggle", function(scope, props)
  props = props or {}

  local function adjust()
    if reactive.peek(props.Disabled) then
      return false
    end
    if props.OnChange then
      props.OnChange(not reactive.peek(props.Value))
    end
    return true
  end

  local value = scope:Text({
    Width = 5,
    TextAlign = "center",
    Text = scope:Computed(function(use)
      return use(props.Value) and "on" or "off"
    end),
    Color = scope:Computed(function(use)
      if use(props.Disabled) then
        return T.mutedFg
      end
      return use(props.Value) and T.accentFg or T.mutedFg
    end),
    Background = scope:Computed(function(use)
      if use(props.Disabled) then
        return T.muted
      end
      return use(props.Value) and T.accent or T.muted
    end),
  })

  return controlRow(scope, props, value, adjust, { "<", ">" })
end)
