--- Hosting a screen: mount it against a pair of ports, then pull, dispatch,
--- render, repeat.
---
--- Named `host` rather than `shell` for two reasons, and the second is the one
--- that matters. CC already has a `shell` global, so a local of that name shadows
--- it and reads as a mistake even where it is not; and docs/icos-2.md section 4
--- reserves `src/shell/` for the thing that hosts *apps* - the desktop, the
--- handheld - which is a layer above this and would have been confused with it
--- forever.
---
--- Small on purpose. Everything interesting already happened - the bindings
--- decided what is dirty, the diff decided what to send - so this is the twenty
--- lines that join them to a pair of ports.
---
--- ## Why it renders after every event and that is still cheap
---
--- `Root:render` returns immediately when nothing is dirty, so an event that
--- changed nothing costs a table lookup. That is what makes "render every time
--- round the loop" the right shape rather than a waste: there is no need for the
--- loop to reason about whether a repaint is due, because the thing that knows
--- already knows.
---
--- Contrast Basalt, which also renders after every event and has no cheap
--- answer, so it grew a render throttle to stop a busy machine from repainting
--- constantly. A throttle trades latency for cost; a dirty check costs nothing
--- and adds no latency, so there is nothing to trade.
---
--- ## It does not own the machine
---
--- `run` returns when `stop` is called or the input port is exhausted, and it
--- does not install a signal handler, clear the screen, or reset the palette on
--- the way out. A shell that tidied up after itself would be wrong on the base
--- station, where this is one of several coroutines sharing a terminal and the
--- desktop owns what happens next.

local host = {}

--- Run `root` against an input port until it stops.
---
--- `options.onEvent` sees every raw event before the tree does, which is how a
--- host - the desktop, a supervisor - keeps its own bookkeeping without the
--- screen having to forward anything. Returning `true` from it consumes the
--- event.
function host.run(root, input, options)
  options = options or {}
  local running = true

  local function stop()
    running = false
  end

  -- The first frame happens before the first event, because a screen that
  -- appeared only once somebody pressed something would look broken for as long
  -- as nobody did.
  root:render()

  while running do
    local event = { input.pull(options.timeout) }
    local name = event[1]

    if name == nil then
      -- The port timed out, or a scripted input ran out. Both mean "nothing
      -- more is coming"; a loop that kept spinning on nil would be a busy-wait
      -- in production and a hang in a test.
      if options.timeout == nil then
        break
      end
      if options.onIdle and options.onIdle(root) == false then
        break
      end
    else
      if name == "terminate" then
        break
      end
      local consumed = options.onEvent and options.onEvent(name, table.unpack(event, 2))
      if not consumed then
        root:handle(table.unpack(event))
      end
    end

    root:render()
  end

  return stop
end

--- Everything a screen needs, wired from ports, in one call.
---
--- This is the composition root for a page, and it is deliberately the only
--- place in the framework that knows a screen and an input belong together.
--- Below it nothing takes both; above it an app hands over two ports and a
--- builder and gets something it can run.
function host.mount(options)
  local ui = require("ui.init")
  local theme = require("ui.theme")

  local palette = options.palette or theme.dark
  if options.applyPalette ~= false then
    theme.apply(options.screen, palette)
  end

  local scope = options.scope or ui.scoped()
  local root = ui.mount({
    scope = scope,
    screen = options.screen,
    build = options.build,
    onError = options.onError,
    background = theme.TOKENS.background,
  })
  root.palette = palette

  -- Focus starts on the first focusable control rather than nowhere, so that a
  -- keyboard-only surface - a turtle - can act without a mouse click it has no
  -- way to make.
  if options.autoFocus ~= false then
    root:focus(root:focusRing()[1])
  end

  return root
end

return host
