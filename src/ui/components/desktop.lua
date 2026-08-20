--- The two shapes a desktop is made of: an icon you open, and a window it opens into.
---
--- Everything before this was a page filling a screen with a row of words under
--- it. That is a launcher, not a desktop, and the difference is not decoration:
--- a launcher tells you what exists, a desktop tells you what you have *open*
--- and lets you leave it.
---
--- ## An icon is a tile, not a line of text
---
--- Three rows: a glyph, a name, and a gap. It is a `Card`, so it sits on its own
--- ground rather than on the wallpaper, and selecting one changes both its
--- background and its text - one token would leave the label at whatever
--- contrast it had, which on a monochrome terminal is no change at all.
---
--- The picture is a sprite where one exists - see `ui/icons.lua` - and a
--- character where one does not. Characters were the whole of the first version
--- and a desktop of them reads as punctuation, not as objects.
---
--- ## A window is a frame with a way out
---
--- Title bar, body, and a hint that says how to close it. The hint is not
--- optional furniture: a full-screen page with no visible exit is the single
--- most common way somebody concludes a program has hung, and this system has
--- already produced that impression twice for other reasons.

local runtime = require("ui.runtime")
local theme = require("ui.theme")

local T = theme.TOKENS

---------------------------------------------------------------------------
-- Icon
---------------------------------------------------------------------------

--- One app on the desktop.
---
---     scope:Icon({ Glyph = "\7", Label = "Fleet", Selected = isOpen, OnOpen = fn })
---
--- `Selected` is a binding rather than a value, because the desktop moves the
--- selection and every tile has to hear about it - a tile that read a boolean
--- once would be a tile that never un-highlights.
runtime.compose("Icon", function(scope, props)
  props = props or {}

  local selected = props.Selected

  local function tone(onSelected, otherwise)
    if selected == nil then
      return otherwise
    end
    return scope:Computed(function(use)
      return use(selected) and onSelected or otherwise
    end)
  end

  return scope:Card(runtime.layoutProps(props, {
    Width = props.Width or 11,
    Height = props.Height or 5,
    Padding = { left = 1, right = 1, top = 0, bottom = 0 },
    Focusable = true,
    Background = tone(T.accent, T.card),
    OnClick = props.OnOpen,

    -- Enter opens, because a keyboard user has already arrowed onto it and
    -- pressing the obvious key should not be a second decision.
    OnKey = props.OnOpen and function(_, event)
      local KEY = require("ui.input").KEY
      if event.key == KEY.enter or event.key == KEY.space then
        props.OnOpen()
        return true
      end
      return false
    end or nil,

    Children = {
      -- A picture when there is one, a letter when there is not.
      --
      -- The first version was only ever a character, and it read as exactly
      -- that: a desktop of punctuation standing in for objects. A sprite is
      -- 8x6 pixels through the 2x3 canvas - four cells wide, two tall - which
      -- is small enough to fit above a label on a 26-column Pocket Computer and
      -- large enough to be a shape rather than a symbol.
      props.Sprite and scope:Sprite({
        Height = 2,
        Sprite = props.Sprite,
        -- The tile's own ground, so a transparent pixel shows the card rather
        -- than a hole - and bound, because that ground changes with selection.
        Background = tone(T.accent, T.card),
      }) or scope:Text({
        Height = 2,
        TextAlign = "center",
        Text = props.Glyph or "\7",
        Color = tone(T.accentFg, T.accent),
      }),
      scope:Text({
        Height = 1,
        TextAlign = "center",
        Text = props.Label or "",
        Color = tone(T.accentFg, T.foreground),
      }),
      scope:Muted({
        Height = 1,
        TextAlign = "center",
        Text = props.Detail or "",
        Color = tone(T.accentFg, T.mutedFg),
      }),
    },
  }))
end)

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

--- A framed app, with a title bar and a way out.
---
--- `Absolute` on the outer node, so a window sits over the desktop rather than
--- pushing it around - which is what makes closing one leave the wallpaper
--- exactly as it was rather than reflowing everything underneath.
runtime.compose("Window", function(scope, props)
  props = props or {}

  local bar = {
    scope:Text({
      Text = props.Title or "",
      Color = T.primaryFg,
      Grow = 1,
    }),
  }

  if props.Status ~= nil then
    bar[#bar + 1] = scope:Text({ Text = props.Status, Color = T.primaryFg })
  end

  return scope:Overlay(runtime.layoutProps(props, {
    Background = T.background,
    Children = {
      scope:Row({
        Height = 1,
        Padding = { left = 1, right = 1, top = 0, bottom = 0 },
        Background = T.primary,
        Children = bar,
      }),

      scope:Box({
        Grow = 1,
        Children = props.Children or {},
      }),

      -- Always there, even when the app below has its own actions. A window
      -- whose exit is sometimes visible is a window somebody has to look for.
      scope:Row({
        Height = 1,
        Padding = { left = 1, right = 1, top = 0, bottom = 0 },
        Background = T.muted,
        Children = {
          scope:Muted({
            Text = props.Hint or "Q or backspace  close",
            Color = T.foreground,
            Grow = 1,
          }),
        },
      }),
    },
  }))
end)

return true
