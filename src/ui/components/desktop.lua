--- The tile a desktop is made of: an app you can see and open.
---
--- Everything before this was a page filling a screen with a row of words under
--- it. That is a launcher, not a desktop, and the difference is not decoration:
--- a launcher tells you what exists, a desktop tells you what you have open and
--- lets you leave it.
---
--- ## Four rows, and none of them wasted
---
--- A picture, a blank line, and a name. The blank line is the one that looks
--- like padding and is not: without it the label's cap-height sits directly
--- against the sprite's bottom pixel row and the two read as one smudged shape,
--- which is exactly how the first version looked in world.
---
--- The picture is centred by a pair of spacers rather than by arithmetic. A
--- `Sprite` paints at its own origin inside whatever box it is given, so a
--- stretched one lands hard against the left edge - which is what put every icon
--- off-centre in a tile that was itself trying to look centred.
---
--- ## Three states, three grounds
---
--- Idle is `card`, selected is `accent`, and being carried is `warn`. Three
--- backgrounds rather than a background and a caption, because a caption costs a
--- row this screen does not have and because a colour is legible from across a
--- room, which is where a wall monitor is read from.
---
--- Selecting changes the text colour too. One token would leave the label at
--- whatever contrast it had, which on a monochrome terminal is no change at all.
---
--- ## There is no `Window` here any more
---
--- There was, and it drew a title bar and a "Q or backspace close" hint around
--- whatever was inside it. On screen that came out as three stacked headers -
--- the machine's bar, the window's bar, and the page's own title - on a screen
--- that has nineteen rows in total.
---
--- The chrome now lives in one place, `os/client/desktop.lua`, as a single bar
--- carrying the open apps and the time; and an open app is the only thing the
--- desktop builds, so there is nothing left for a frame to be drawn around.

local runtime = require("ui.runtime")
local theme = require("ui.theme")

local T = theme.TOKENS

--- One app on the desktop.
---
---     scope:Icon({ Sprite = icons.fleet, Label = "Fleet", Selected = isOn })
---
--- `Selected` and `Held` are bindings rather than values, because the desktop
--- moves both and every tile has to hear about it - a tile that read a boolean
--- once would be a tile that never un-highlights.
runtime.compose("Icon", function(scope, props)
  props = props or {}

  local selected = props.Selected
  local held = props.Held

  --- Pick between three values by what this tile is doing.
  ---
  --- Bound when either input is, constant when neither is, so a static tile
  --- costs nothing in the graph.
  local function tone(idle, chosen, carried)
    if selected == nil and held == nil then
      return idle
    end
    return scope:Computed(function(use)
      if held ~= nil and use(held) then
        return carried
      end
      if selected ~= nil and use(selected) then
        return chosen
      end
      return idle
    end)
  end

  local ground = tone(T.card, T.accent, T.warn)

  return scope:Card(runtime.layoutProps(props, {
    Width = props.Width or 11,

    -- Four rows: two of picture, one of air, one of name. See the header for
    -- why the empty one is not padding.
    Height = props.Height or 4,

    -- No side padding, deliberately. A tile eleven cells wide with a cell of
    -- padding each side centres a name in nine, and `floor((9 - 8) / 2)` is
    -- zero - so an eight-letter app sat flush left inside a tile that looked
    -- like it was trying to centre it. The gap between tiles does the
    -- separating instead, which is what a gap is for.
    Padding = { left = 0, right = 0, top = 0, bottom = 0 },

    Focusable = true,
    Background = ground,
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
      scope:Row({
        Height = 2,
        Children = {
          scope:Spacer({ Grow = 1 }),
          scope:Sprite({
            Sprite = props.Sprite,
            -- The tile's own ground, so a transparent pixel shows the card
            -- rather than a hole - and bound, because that ground moves.
            Background = ground,
          }),
          scope:Spacer({ Grow = 1 }),
        },
      }),
      scope:Spacer({ Height = 1 }),
      scope:Text({
        Height = 1,
        TextAlign = "center",
        Text = props.Label or "",
        Color = tone(T.foreground, T.accentFg, T.primaryFg),
      }),
    },
  }))
end)

return true
