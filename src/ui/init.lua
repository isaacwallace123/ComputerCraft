--- The framework's front door.
---
--- One require pulls in the runtime, the theme, the helpers, and every
--- component, so a screen begins with `local ui = require("ui.init")` and
--- nothing else. Components register themselves as a side effect of being
--- loaded, which is why they are required here for effect rather than for a
--- value: a screen must not have to remember which file `Badge` lives in.
---
--- Named `init.lua` under `ui/` rather than `ui.lua` beside it so that the whole
--- framework is one directory. CC's `require` resolves `ui.init` directly, and
--- the spec runner's package path does the same, so nothing depends on
--- `?/init.lua` being on the path - which it is not, on either.

require("ui.components.text")
require("ui.components.layout")
require("ui.components.controls")
require("ui.components.page")
require("ui.components.table")

local runtime = require("ui.runtime")

local ui = {
  anim = require("ui.anim"),
  buffer = require("ui.buffer"),
  input = require("ui.input"),
  layout = require("ui.layout"),
  reactive = require("ui.reactive"),
  runtime = runtime,
  host = require("ui.host"),
  theme = require("ui.theme"),
  util = require("ui.util"),
}

ui.tokens = ui.theme.TOKENS

--- A lifetime that can make both state and nodes. Everything a screen creates
--- goes through it, and closing the screen destroys it.
ui.scoped = runtime.scoped

--- Attach a tree to a screen port. See `runtime.mount`.
ui.mount = runtime.mount

--- Wire a screen and an input port into something runnable. The composition
--- root for a page; see `ui/host.lua`.
ui.page = function(options)
  return require("ui.host").mount(options)
end

ui.run = function(root, input, options)
  return require("ui.host").run(root, input, options)
end

--- Set a node property from outside the binding graph. Focus uses it; a screen
--- should reach for a `Value` instead.
ui.set = runtime.set

--- Register a component. Apps may do this; it is how a game or a one-off view
--- adds a shape without editing the framework.
ui.define = runtime.define
ui.compose = runtime.compose

--- Live binding count, for the leak check in section 15 of the framework plan.
--- A screen that has been opened and closed ten times should report the same
--- number as one that has been opened and closed once.
ui.live = ui.reactive.live

return ui
