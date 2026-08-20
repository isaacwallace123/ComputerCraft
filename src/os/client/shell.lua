--- The desktop: which app is open, and how you get to another one.
---
--- `os/client/main.lua` supervises a `screen` service and takes a `draw`
--- function; this is that function. It is the composition root for the *screen*
--- in the same way `main.lua` is the composition root for the machine.
---
--- ## One event loop, two loops that look like one
---
--- `ui/host.lua` runs its own loop pulling from the input port, and the
--- supervisor runs its own loop resuming coroutines. That reads like a collision
--- and is not: the input port's `pull` is `os.pullEvent`, which is
--- `coroutine.yield` with a filter, so a supervised `host.run` parks on exactly
--- the yield the supervisor is built to resume. `boot.run` pulls the event, the
--- supervisor hands it to the coroutine, and `host.run` receives it as the
--- return value of its own `pull`. Nothing had to change on either side.
---
--- ## The taskbar is a consequence of D006, not a decoration
---
--- D006 learned once that when each page owns its chrome, the chrome diverges.
--- So the shell owns the app switcher and the app owns nothing above its own
--- content - an app cannot draw a title bar, because `Page` draws it and the
--- shell decides what is around it.
---
--- ## Switching apps rebuilds, and that is correct
---
--- Each app gets a fresh scope, and closing one destroys it. The alternative -
--- keeping every app mounted and hiding all but one - would mean ten pages of
--- `Computed` recalculating on every heartbeat so that nine of them could be
--- invisible. `reactive.live()` exists to catch exactly that, and the shell is
--- the most likely place to leak it.

local host = require("ui.host")
local registry = require("apps.registry")
local reactive = require("ui.state.reactive")
local ui = require("ui.init")

local shell = {}

--- The event a ticking machine queues to wake its screen.
---
--- Every page derives what it shows from a `tick` value, and nothing advanced
--- it - so a page computed once and held that picture for as long as it was
--- open. The symptom was not "the screen is slow": it was a server whose Fleet
--- page said one turtle while the client beside it said four. The server had
--- rendered once, when one turtle was known, and never again.
---
--- ## Why an event and not a timeout
---
--- The first attempt gave `host.run` a timeout and bumped the tick from
--- `onIdle`. That works on a real terminal, where `pull` waits a second before
--- returning nothing - and spins at full speed on one whose input port returns
--- instantly, which is a null port, a scripted one that has run out, and a
--- machine whose keyboard has died. A refresh mechanism that turns a broken
--- input into a hot loop is worse than no refresh.
---
--- So the clock lives in a service, where sleeping is what services do, and it
--- queues an event. `host.run` is already an event loop: it wakes, the tree
--- ignores an event it has no handler for, and the render at the bottom of the
--- loop is the repaint. Nothing in the framework had to change, and a dead
--- input port stays dead rather than becoming busy.
--- Named by the service that queues it, not copied here. Two spellings of one
--- constant is the failure `domain/protocol/message.lua` describes: both sides
--- work perfectly and never hear each other, with nothing to hear.
shell.TICK_EVENT = require("os.kernel.services.ticker").EVENT

--- Build the shell's own state.
---
--- Separated from `mount` so a spec can drive app switching without a screen,
--- and because "which app is open" is the only state the shell has - everything
--- else belongs to the app that is open.
function shell.state(scope, entries)
  return {
    entries = entries,
    index = scope:Value(1),
    tick = scope:Value(0),
  }
end

--- Move to another app.
---
--- Wraps, because a taskbar you can fall off the end of is a taskbar somebody
--- has to look at to use. Returns the new index so a caller can tell whether
--- anything moved without reading the state back.
function shell.switch(state, delta)
  local count = #state.entries
  if count == 0 then
    return nil
  end
  local current = reactive.peek(state.index)
  local next_ = ((current - 1 + delta) % count) + 1
  state.index:set(next_)
  return next_
end

--- The taskbar: which apps exist and which one you are looking at.
---
--- Rendered as text rather than as buttons, and that is not laziness. A wall
--- monitor has no keyboard and no mouse, so a row of buttons there is a row of
--- things that cannot be pressed - and D020 says a display-only surface gets no
--- controls. The same row on a desktop tells somebody which key to press.
function shell.taskbar(scope, state)
  local children = {}
  for index, entry in ipairs(state.entries) do
    local manifest = entry
    local active = scope:Computed(function(use)
      return use(state.index) == index
    end)
    children[#children + 1] = scope:Text({
      Text = ("%d %s"):format(index, manifest.name or manifest.id),
      Color = scope:Computed(function(use)
        return use(active) and ui.tokens.foreground or ui.tokens.mutedFg
      end),
    })
    children[#children + 1] = scope:Spacer({ Width = 2 })
  end
  return scope:Row({ Height = 1, Children = children })
end

--- Mount the shell and run it until it stops.
---
--- This is the `draw` that `os/client/main.lua` supervises. It returns when the
--- screen ends, which the supervisor treats as a fault - correctly, because a
--- client whose screen loop has ended is a client with a dead screen, and it
--- should back off and remount rather than sit there showing the last frame.
function shell.run(context, options)
  options = options or {}
  local entries = options.apps
    or registry.available(options.role or "client", options.surface or "desktop")

  -- Rebuilt on every switch, so an app that is closed is destroyed rather than
  -- hidden. Ten pages of Computed recalculating on every heartbeat so that nine
  -- can be invisible is exactly what `reactive.live()` exists to catch.
  local function open(index)
    local entry = entries[index]
    if entry == nil then
      return nil
    end

    -- Loaded here rather than at boot. `registry.available` returns names, and
    -- the module behind one is read off disk the first time somebody looks at
    -- it - which on a wall monitor is one page out of eight.
    local app = entry.mount and entry or registry.load(entry)
    if app == nil then
      return nil
    end

    local scope = ui.scoped()
    local state = shell.state(scope, entries)
    state.index:set(index)

    local root = host.mount({
      screen = context.screen,
      scope = scope,
      palette = options.palette,
      build = function(inner)
        return inner:Column({
          Children = {
            app.mount(inner, context, {
              readOnly = options.readOnly,
              capacity = options.capacity,

              -- The machine's clock, not one the shell invents. Every app
              -- defaulted to `scope:Value(0)` and nothing anywhere incremented
              -- it, so every page computed once and held that picture for as
              -- long as it was open.
              --
              -- `context.tick` is advanced by the ticker service, which is the
              -- only thing in the system that knows what time it is.
              tick = context.tick or state.tick,
            }),
            inner:Separator({}),
            shell.taskbar(inner, state),
          },
        })
      end,
    })

    return { root = root, scope = scope, state = state }
  end

  local index = options.index or 1
  while true do
    local session = open(index)
    if session == nil then
      return
    end

    local wanted = nil

    host.run(session.root, context.input, {
      clock = context.clock,

      timeout = options.timeout,
      onEvent = function(name, key)
        -- The shell sees every event before the tree does, which is how it
        -- keeps its own bookkeeping without the app having to forward anything.
        -- Number keys switch; everything else falls through to the page, so an
        -- app that wants `1` for something of its own is not fighting the shell
        -- for it - it simply never sees a bare number, which is the trade a
        -- taskbar costs and is worth stating.
        if name == "key" and key ~= nil and key >= 2 and key <= 10 then
          local target = key - 1
          if entries[target] and target ~= index then
            wanted = target
            -- Ends the session so the loop below can rebuild. Returning `true`
            -- only consumed the key: the choice was recorded and the old app
            -- kept drawing, because nothing read `wanted` until `host.run`
            -- returned and `host.run` had no reason to return.
            return host.STOP
          end
        end
        return false
      end,
    })

    session.scope:destroy()

    if wanted == nil then
      return
    end
    index = wanted
  end
end

return shell
