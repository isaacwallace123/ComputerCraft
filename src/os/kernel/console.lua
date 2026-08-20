--- Chrome for the three programs that run before the framework does.
---
--- The splash, the updater and setup all need a header, a progress bar and a
--- list of lines - and none of them may depend on the component tree, for the
--- same reason `os/kernel/splash.lua` does not: they run before anything has
--- been checked, and on a machine whose files an updater replaced ten seconds
--- ago. A boot-time program that could not draw because a component was broken
--- would be a machine that cannot tell you what is wrong with it.
---
--- So this is the buffer and nothing else. One require, no reactive graph, no
--- layout solver, no registry.
---
--- ## It is not a second UI framework
---
--- Four functions, no state, no events, no components. Anything that wants a
--- button wants `ui/`, and anything that runs early enough to need this has
--- nothing for a button to do. If this file grows a control, the control is in
--- the wrong place.
---
--- ## The design tokens are shared, deliberately
---
--- It reads `ui/theme.lua` rather than naming colours, so a boot screen and the
--- Devices page cannot disagree about what "warning" looks like. That is the one
--- thing worth having in common with the framework, and it costs a table lookup.

local buffer = require("ui.render.buffer")
local format = require("ui.format")
local theme = require("ui.theme")

local T = theme.TOKENS

local console = {}

local Console = {}
Console.__index = Console

--- Attach to a screen port.
---
--- Applies the theme's palette, which `ui/host.lua` does for a mounted page and
--- nothing did for a boot-time one. Without it every token here resolves to
--- whatever CC's defaults happen to be at that index - `accent` comes out as
--- light grey rather than blue - so the splash, the updater and setup would be
--- the three screens in the system that did not match the system.
---
--- Skipped on a terminal that cannot show colour, because `setPalette` on a
--- basic computer is a call that does nothing and the check is cheaper than the
--- call.
function console.new(screen, palette)
  local width, height = screen.size()
  local self = setmetatable({}, Console)
  self.frame = buffer.new(screen, width, height)
  self.width = width
  self.height = height

  if screen.isColour and screen.isColour() then
    theme.apply(screen, palette or theme.dark)
  end

  return self
end

function Console:size()
  return self.width, self.height
end

function Console:clear()
  self.frame:clear(T.foreground, T.background)
  return self
end

--- Title on the left, status on the right, a rule underneath.
---
--- The same anatomy `ui/components/page.lua` draws, deliberately - a machine
--- that looked different while updating would look like a different machine at
--- the one moment somebody is checking whether it is the right one.
---
--- No filled bar. D0-era ICOS painted a solid strip across row 1, which on a
--- wall monitor is fifty cells of saturated grey competing with the data.
function Console:header(title, status)
  self.frame:write(2, 1, title, T.foreground, T.background)
  if status then
    local at = math.max(2 + #title + 1, self.width - #status)
    self.frame:write(at, 1, status, T.mutedFg, T.background)
  end
  self.frame:write(1, 2, string.rep("\140", self.width), T.mutedFg, T.background)
  return self
end

--- One line of text, clipped to the screen.
---
--- Through `format.pad` rather than `string.format`, because Lua's has no
--- dynamic width specifier and caps a literal one at two digits - so a wide
--- monitor is a runtime error rather than a typo a linter catches.
function Console:line(row, text, tone)
  self.frame:write(
    2,
    row,
    format.pad(text or "", self.width - 2),
    tone or T.foreground,
    T.background
  )
  return self
end

---------------------------------------------------------------------------
-- Chrome
---------------------------------------------------------------------------

--- The full treatment: a title bar, a panel, and a footer.
---
--- `header` above is the *quiet* anatomy - a line of text and a rule - and the
--- updater keeps it, because an updater is something you glance at while it
--- works and a coloured frame around a progress bar is decoration on a machine
--- that is busy.
---
--- Setup is the opposite. It is the first thing anybody sees of this system, it
--- is a sequence of decisions rather than a status, and a screen that looks like
--- a shell prompt with the words changed does not read as a program you are
--- being walked through. So it gets a bar, a body it sits inside, and a footer
--- that always says what the keys do.
---
--- Three bands rather than one border, deliberately. A drawn box costs two
--- columns and two rows of a 26x20 Pocket Computer for an outline, and CC has no
--- line-drawing glyphs that survive a monochrome terminal - whereas a filled
--- band is one colour and reads at any size.
function Console:chrome(title, status, footer)
  -- Body first, so the bars paint over its edges rather than the other way
  -- round and there is no seam to get the order wrong about.
  self.frame:fill(1, 1, self.width, self.height, " ", T.foreground, T.card)

  self.frame:write(
    1,
    1,
    format.pad(" " .. tostring(title or ""), self.width),
    T.primaryFg,
    T.primary
  )
  if status then
    self.frame:write(
      math.max(2, self.width - #status - 1),
      1,
      tostring(status),
      T.primaryFg,
      T.primary
    )
  end

  self.frame:write(
    1,
    self.height,
    format.pad(" " .. tostring(footer or ""), self.width),
    T.foreground,
    T.muted
  )
  return self
end

--- One line inside the panel.
---
--- Separate from `line` because the panel has a background and `line` writes on
--- `background`. Two functions rather than a parameter, so a caller cannot draw
--- half a screen on the wrong ground and get a stripe.
function Console:panelLine(row, text, tone)
  self.frame:write(
    2,
    row,
    format.pad(tostring(text or ""), self.width - 2),
    tone or T.foreground,
    T.card
  )
  return self
end

--- A full-width band, for a row that is selected or highlighted.
---
--- The whole width rather than the text's width, because a selection that only
--- covers the label looks like a mistake - the eye reads the highlight as the
--- row, and a row that stops halfway reads as a row that is half broken.
function Console:band(row, text, tone, background)
  local body = format.pad(" " .. tostring(text or ""), self.width)
  self.frame:write(1, row, body, tone or T.foreground, background or T.muted)
  return self
end

--- Text against the right edge.
---
--- Here rather than in a caller, because the arithmetic is `width - #text` and a
--- caller doing it needs `width` in scope - which is how `update.lua` came to
--- reach into `screen.frame` directly and then reference a `width` that a later
--- edit had taken away.
function Console:right(row, text, tone)
  text = tostring(text or "")
  self.frame:write(math.max(1, self.width - #text), row, text, tone or T.foreground, T.background)
  return self
end

--- A proportion, drawn as a filled rule.
---
--- Two characters rather than one: a bar drawn in spaces with a background
--- colour disappears on a monochrome terminal, and half the fleet's turtles have
--- one. Solid and light blocks read as full and empty on both.
function Console:bar(row, done, total, tone)
  local fraction = total and total > 0 and math.max(0, math.min(1, done / total)) or 0
  local inner = math.max(1, self.width - 12)
  local filled = math.floor(inner * fraction + 0.5)

  self.frame:write(2, row, string.rep("\127", filled), tone or T.accent, T.background)
  self.frame:write(2 + filled, row, string.rep("\183", inner - filled), T.mutedFg, T.background)

  local label = ("%d/%d"):format(done or 0, total or 0)
  self.frame:write(self.width - #label, row, label, T.foreground, T.background)
  return self
end

--- Push everything drawn to the screen.
---
--- Explicit rather than after every call, so a screen is composed and then shown
--- once. An updater that presented per line would flicker through forty
--- repaints for one frame of progress.
function Console:present()
  self.frame:present()
  return self
end

console.TOKENS = T

return console
