--- The spec runner.
---
--- Run with `tools\spec.ps1`. There is no Lua interpreter on the development
--- machine, but the Lua language server binary the checks already use is one, so
--- this needs nothing installed that the repository did not already require.
---
--- ## The files are discovered, not listed
---
--- This used to hold a hand-written list of every spec module, which meant a new
--- spec file did not run until somebody remembered to add it - and a spec that
--- does not run is worse than one that does not exist, because the suite reports
--- green either way.
---
--- Plain Lua cannot read a directory, so `tools\spec.ps1` globs
--- `tests\**\*_spec.lua` and passes the paths in. Nothing to forget, and the
--- order is the tree's own: `adapters`, `apps`, `domain`, `lib`, `os`, `ui`.
---
--- ## Why `tests/` and not `src/`
---
--- `tools\make-manifest.ps1` walks `src/` and the updater deploys **every** file
--- in the manifest to every machine in the fleet. Specs under `src/` would ship
--- to turtles with a one-megabyte disk - the disk that has already filled once -
--- to be read by nothing. They are not part of what a machine runs, so they are
--- not part of what a machine receives.

-- Captured before any spec installs a simulated CC environment over `os`.
local exit = os.exit

package.path = table.concat({
  "src/?.lua",
  "tests/?.lua",
  package.path,
}, ";")

local spec = require("support.spec")

--- The first argument is the filter, and every argument after it is a file.
---
--- Positional rather than an environment variable, because a spec run has to
--- behave identically whether it was started by `spec.ps1`, by CI, or by hand.
--- `*` means "everything", and it is a real token rather than an empty string
--- because PowerShell drops an empty argument on its way to a native executable
--- - which slid the first spec path into the filter slot, ran one file fewer,
--- matched nothing, and reported `0 passed` as a pass.
local arguments = { ... }
local filter = arguments[1]
if filter == "*" or filter == "" then
  filter = nil
end

local files = {}
for index = 2, #arguments do
  files[#files + 1] = arguments[index]
end

if #files == 0 then
  print("no spec files given - run tools\\spec.ps1")
  exit(1)
end

for _, path in ipairs(files) do
  local chunk, loadError = loadfile(path)
  if not chunk then
    error("could not load " .. path .. ": " .. tostring(loadError))
  end
  chunk()
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

print(("%d passed, %d failed"):format(passed, failed))
exit(failed == 0 and 0 or 1)
