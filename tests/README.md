# Specs

Run them with `.\tools\spec.ps1`, or filter to a subset:

```powershell
.\tools\spec.ps1            # everything
.\tools\spec.ps1 chunk      # cases whose name contains "chunk"
```

There is no Lua interpreter on the development machine. The runner uses the Lua
language server binary `tools\check.ps1` already locates, so the suite needs
nothing installed that the repository did not already require.

## Layout

`tests/` mirrors `src/`, so the spec for a file is where you would look for it:

```
tests/
  run.lua                 the runner
  support/                fakes and helpers, not tests
  adapters/               the cc and sim adapters
  apps/                   one file per page
  domain/                 pure logic - the largest and fastest part
  lib/
  os/
    kernel/  server/  client/  mobile/  turtle/
  ui/
```

## Two rules

**Spec files are discovered, not listed.** `tools\spec.ps1` globs
`tests\**\*_spec.lua` and passes the paths to `run.lua`. There is no registry to
update, because a spec that nobody remembered to register is a spec that reports
green by never running — which is the one failure a test suite must not have.

**Nothing here ships.** `tools\make-manifest.ps1` walks `src/` and the updater
deploys every file in `src/manifest.json` to every machine in the fleet. A turtle
has a one-megabyte disk and no use for a spec, so the suite lives outside `src/`
and is never deployed.

## Writing one

Cases register themselves through `support.spec`:

```lua
local expect = require("support.expect")
local it = require("support.spec").it

it("says what should be true, in a sentence", function()
  expect.equal(actual, wanted, "what this particular assertion is about")
end)
```

Two kinds of helper are worth knowing before writing a new fake:

- **`support.fleet`** — clocks, ports, server and turtle contexts, and the
  messages devices send. For anything that drives a machine without a world.
- **`support.scenario`** — a turtle in a simulated world, for the mining logic.
  `support.world` is an alias for `src/adapters/sim/world.lua`.

**Anything that blocks must yield.** A service body is a `while true` parked on a
receive or a sleep. A fake that returns instantly spins inside `coroutine.resume`,
which never returns — so the supervisor never regains control and the suite hangs
rather than fails. A hung test is worse than a failing one.
