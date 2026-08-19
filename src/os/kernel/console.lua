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
function console.new(screen)
  local width, height = screen.size()
  local self = setmetatable({}, Console)
  self.frame = buffer.new(screen, width, height)
  self.width = width
  self.height = height
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
