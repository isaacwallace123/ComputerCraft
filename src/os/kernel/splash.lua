--- The boot screen, and the escape hatch behind it.
---
--- ## It is not built on components, and that is deliberate
---
--- Every other screen in ICOS 2 is a tree of components over a reactive graph.
--- This one is a buffer and six `write` calls, because it runs at the one moment
--- a machine can least afford a failure: before anything has been checked, on a
--- computer whose files were replaced by an updater ten seconds ago.
---
--- A splash built on the component tree would load the runtime, the layout
--- solver, the theme and every registered component in order to draw a word in
--- the middle of the screen - and any one of them failing would leave a machine
--- that cannot boot far enough to tell you why. The buffer is one require with
--- no dependencies of its own, and `os/kernel/boot.lua` is what pulls in the
--- rest, after this has already put something on screen.
---
--- ## The escape hatch is the point of the whole file
---
--- Holding a key during the splash opens setup instead of the autorun. That is
--- not a convenience: it is the only thing standing between a bad deploy and a
--- machine that boots straight into a broken program forever, on a turtle you
--- cannot reach without breaking it.
---
--- So the interrupt is checked *while* drawing rather than after. A splash that
--- animated first and read the keyboard afterwards would have a window - short,
--- but exactly as long as the animation - in which holding a key does nothing,
--- and somebody who pressed too early would conclude the hatch does not work.
---
--- ## The animation is a function of time, not a sequence of sleeps
---
--- `splash.frame` says what the screen looks like at a given moment. The loop
--- decides when moments happen. That is what lets the whole thing be rendered
--- into a recording buffer and asserted, and it is why the animation can be
--- skipped on a slow machine without special-casing anything: ask for the last
--- frame and draw it once.

local buffer = require("ui.render.buffer")
local theme = require("ui.theme")

local splash = {}

splash.NAME = "ICOS"

--- How long the whole animation takes, in seconds.
---
--- Short. A boot screen is a progress indicator, not a title sequence, and every
--- tenth of a second here is a tenth of a second a base station is not answering
--- turtles after a chunk reload.
splash.DURATION = 0.9

--- What the screen looks like at `progress`, from 0 to 1.
---
--- Returns a list of `{ x, y, text, tone }`. Pure, so the whole animation can be
--- rendered into a recording buffer and asserted frame by frame with no screen
--- and no clock.
---
--- The name types out and a rule sweeps under it. Both are derived from the same
--- `progress`, so they cannot fall out of step - which is what happened in the
--- ICOS 1 version, where each had its own `sleep` and a slow machine drew the
--- rule before the word it belonged to.
function splash.frame(progress, options)
  options = options or {}
  local width = options.width or 51
  local height = options.height or 19
  local name = options.name or splash.NAME

  progress = math.max(0, math.min(1, progress))

  local middle = math.max(2, math.floor(height / 2))
  local left = math.max(1, math.floor((width - #name) / 2) + 1)

  local typed = math.floor(#name * math.min(1, progress / 0.6) + 0.5)
  local rule = math.floor((#name + 4) * math.max(0, (progress - 0.4) / 0.6) + 0.5)

  local parts = {}

  if typed > 0 then
    parts[#parts + 1] = {
      x = left,
      y = middle,
      text = name:sub(1, typed),
      tone = theme.TOKENS.foreground,
    }
  end

  if rule > 0 then
    parts[#parts + 1] = {
      x = math.max(1, left - 2),
      y = middle + 1,
      text = string.rep("\140", math.min(rule, width - 2)),
      tone = theme.TOKENS.accent,
    }
  end

  -- The subtitle and version arrive last, so the screen settles rather than
  -- appearing all at once. They are also the only two things somebody actually
  -- reads, which is why they are not competing with the animation for attention.
  if progress >= 0.7 then
    if options.subtitle then
      parts[#parts + 1] = {
        x = math.max(1, math.floor((width - #options.subtitle) / 2) + 1),
        y = middle + 3,
        text = options.subtitle,
        tone = theme.TOKENS.mutedFg,
      }
    end
    if options.version then
      local label = "v" .. options.version
      parts[#parts + 1] = {
        x = math.max(1, math.floor((width - #label) / 2) + 1),
        y = height,
        text = label,
        tone = theme.TOKENS.mutedFg,
      }
    end
  end

  return parts
end

--- Draw one frame.
function splash.draw(frame, progress, options)
  frame:clear(theme.TOKENS.foreground, theme.TOKENS.background)
  for _, part in ipairs(splash.frame(progress, options)) do
    frame:write(part.x, part.y, part.text, part.tone, theme.TOKENS.background)
  end
  frame:present()
end

--- Run the splash, returning true if somebody held a key.
---
--- `options.pull` is the event source, so a spec drives this with a list. In
--- production it is `os.pullEvent` with a timer, which is the only shape that
--- can watch a keyboard and animate at the same time without `parallel` - and
--- `parallel` is what the supervisor exists to replace.
function splash.run(screen, options)
  options = options or {}
  local width, height = screen.size()
  local frame = buffer.new(screen, width, height)

  options.width, options.height = width, height

  local pull = options.pull
  local clock = options.clock
  local steps = options.steps or 12
  local interrupted = false

  for step = 0, steps do
    splash.draw(frame, step / steps, options)

    if pull then
      -- One timer per frame rather than one long sleep, because the keyboard has
      -- to be readable throughout. This is the escape hatch; a frame in which it
      -- is deaf is a frame in which a machine cannot be rescued.
      local timer = os.startTimer(splash.DURATION / steps)
      while true do
        local event, id = pull()
        if event == "key" or event == "char" or event == "monitor_touch" then
          interrupted = true
          break
        end
        if event == "timer" and id == timer then
          break
        end
      end
      if interrupted then
        break
      end
    elseif clock then
      clock.sleep(splash.DURATION / steps)
    end
  end

  -- Settled, whether it was interrupted or not. A machine that stopped
  -- mid-animation and then printed over half a word looks broken at exactly the
  -- moment somebody is deciding whether it is.
  splash.draw(frame, 1, options)
  return interrupted
end

return splash
