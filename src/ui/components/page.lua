--- The anatomy every ICOS screen shares.
---
--- `Page` is the component with no equivalent in Basalt, and it carries most of
--- the consistency in the design system. It owns the title, the status line, the
--- separators, and the action row, so every screen in ICOS has the same shape
--- without every screen re-deciding it. An app supplies `Title`, `Children`, and
--- `Actions`; it does not get to draw its own header.
---
--- That is a deliberate removal of freedom. D006 already learned this lesson
--- once with nested app frames and duplicate title bars: when each page owns its
--- own chrome, the chrome diverges, and a dashboard read at a glance from across
--- a room cannot afford three different ideas of where the title goes.
---
--- ## No filled title bar
---
--- The current UI paints a solid `headerBg` strip across row 1. On a wall
--- monitor that is fifty-one cells of saturated grey competing with the data,
--- and it is the single most dated thing about how ICOS looks. Here the title is
--- simply the only `foreground` text in a region of `mutedFg`, and a `Separator`
--- does the dividing - which costs one row instead of one row plus the visual
--- weight.

local runtime = require("ui.runtime")
local theme = require("ui.theme")

local T = theme.TOKENS

runtime.compose("Page", function(scope, props)
  props = props or {}

  local header = {
    scope:Heading({ Text = props.Title or "" }),
    scope:Spacer({ Grow = 1 }),
  }
  -- The status line is optional and right-aligned. It is `Muted` rather than
  -- `Text` because it is always context - "4 of 6 online", a sector count, a
  -- clock - and never the thing the page is about.
  if props.Status ~= nil then
    header[#header + 1] = scope:Muted({ Text = props.Status })
  end

  local children = {
    scope:Row({ Padding = { left = 2, right = 2, top = 1, bottom = 0 }, Children = header }),
    scope:Separator({}),
    scope:Column({
      Grow = 1,
      Padding = { left = 2, right = 2, top = 1, bottom = 1 },
      Gap = props.Gap or 0,
      Children = props.Children or {},
    }),
  }

  -- The action row only exists if there are actions. An empty one would still
  -- cost its separator and its row, and a page with nothing to do should give
  -- those two rows back to the content rather than reserve them for symmetry.
  if props.Actions and #props.Actions > 0 then
    children[#children + 1] = scope:Separator({})
    children[#children + 1] = scope:Row({
      Padding = { left = 2, right = 2, top = 0, bottom = 0 },
      Gap = 2,
      Children = props.Actions,
    })
  end

  return scope:Column(runtime.layoutProps(props, {
    Background = props.Background or T.background,
    Children = children,
  }))
end)
