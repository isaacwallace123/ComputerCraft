--- Checking that a table satisfies a port.
---
--- Lua has no interfaces, so a "port" here is nothing more than an agreed set of
--- function names. That agreement is worth exactly as much as the thing that
--- enforces it, and the failure it prevents is a nasty one: an adapter missing a
--- method does not fail where it was built, it fails hours later at the one call
--- site that happened to need it, on a machine nobody is standing in front of.
---
--- So every adapter is checked once, at construction, against the port's own
--- list of method names. The error names the port and the missing method, which
--- is the whole of the diagnostic a person needs.
---
--- Deliberately not a class system. `check` takes a table and returns the same
--- table; there is no wrapping, no metatable, and no dispatch cost at call time.
--- A port implementation is an ordinary table of ordinary functions, and calling
--- one is an ordinary table lookup.

local contract = {}

--- Verify `impl` provides every name in `methods`, and return it unchanged.
---
--- `name` is the port's name and appears in the error, because "missing method
--- `blit`" without it is unactionable when four ports are being wired at once.
function contract.check(name, methods, impl)
  if type(impl) ~= "table" then
    error(("port %s: expected a table of functions, got %s"):format(name, type(impl)), 2)
  end
  for _, method in ipairs(methods) do
    if type(impl[method]) ~= "function" then
      error(("port %s: missing method %s"):format(name, method), 2)
    end
  end
  return impl
end

--- Build a null implementation from `methods`, where every method returns the
--- value `answers[method]` (or nothing).
---
--- Null implementations exist so a composition root can be wired and exercised
--- before its adapters are written, and so a test can silence a port it does not
--- care about. They answer rather than raise on purpose: a null port that threw
--- would only be usable by code that never called it, which is not the code
--- worth testing.
function contract.null(methods, answers)
  answers = answers or {}
  local impl = {}
  for _, method in ipairs(methods) do
    local answer = answers[method]
    if type(answer) == "function" then
      impl[method] = answer
    else
      impl[method] = function()
        return answer
      end
    end
  end
  return impl
end

return contract
