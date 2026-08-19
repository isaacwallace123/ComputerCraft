--- Testing an app without asserting on pixels.
---
--- An app's job is to turn state into the arguments its view draws from, so
--- these two helpers are what let a page be checked at that seam rather than by
--- rendering it and reading cells back.

local ui = require("ui.init")

local page = {}

--- Capture what an app hands its view, rather than what the view built.
---
--- `mount` returns a node tree, so asserting `result.onDeploy` on its return is
--- always nil and always passes - which is exactly how the first version of the
--- D020 test missed the very bug it was written for. The callbacks live in what
--- the app *passed*, so that is what this intercepts.
function page.optionsPassedTo(appModule, viewModule, ctx, options)
  local captured = nil
  local real = viewModule.build
  viewModule.build = function(scope, passed)
    captured = passed
    return real(scope, passed)
  end

  local scope = ui.scoped()
  appModule.mount(scope, ctx, options)
  scope:destroy()
  viewModule.build = real
  return captured
end

--- An app with a manifest and nothing behind it, for testing the shell's
--- filtering rather than any particular page.
function page.fake(id, name, roles, surfaces)
  return {
    manifest = { id = id, name = name, roles = roles, surfaces = surfaces },
    mount = function(scope)
      return scope:Text({ Text = name })
    end,
  }
end

return page
