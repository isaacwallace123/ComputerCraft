--- Spec runner for the ICOS turtle logic.
---
--- Run with `tools\spec.ps1`. There is no Lua interpreter on the development
--- machine, but the Lua language server binary the checks already use is one, so
--- this needs nothing installed that the repository did not already require.

-- Captured before any spec installs a simulated CC environment over `os`.
local exit = os.exit

package.path = table.concat({
  "src/?.lua",
  "tools/spec/?.lua",
  package.path,
}, ";")

local spec = require("support.spec")

local SPECS = {
  "nav_spec",
  "access_spec",
  "surface_spec",
  "hazard_spec",
  "depot_spec",
  "registry_spec",
}

local filter = ...

local skipped = {}
for _, name in ipairs(SPECS) do
  local path = "tools/spec/" .. name .. ".lua"
  local handle = io.open(path, "r")
  if not handle then
    skipped[#skipped + 1] = name
  else
    handle:close()
    local chunk, loadError = loadfile(path)
    if not chunk then
      error("could not load " .. path .. ": " .. tostring(loadError))
    end
    chunk()
  end
end

local passed, failed = 0, 0
local failures = {}

for _, case in ipairs(spec.cases) do
  if not filter or case.name:find(filter, 1, true) then
    local ok, err = pcall(case.body)
    if ok then
      passed = passed + 1
      io.write(".")
    else
      failed = failed + 1
      failures[#failures + 1] = { name = case.name, err = tostring(err) }
      io.write("F")
    end
    io.flush()
  end
end

print("")
print("")
for _, failure in ipairs(failures) do
  print("FAIL  " .. failure.name)
  print("      " .. failure.err:gsub("\n", "\n      "))
  print("")
end

if #skipped > 0 then
  print("not written yet: " .. table.concat(skipped, ", "))
end
print(("%d passed, %d failed"):format(passed, failed))
exit(failed == 0 and 0 or 1)
