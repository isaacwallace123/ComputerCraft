# AI and maintainer handoff

This document is the quickest safe entry point for a new coding agent or maintainer.
It is deliberately operational: read it before relying on earlier chat context.

## First five minutes

Run these read-only commands from the repository root:

```powershell
git status --short
git branch --show-current
git remote -v
rg --files
rg -n "TODO|FIXME|HACK" . -g '!types/**'
```

Then read:

1. The user's latest request and open IDE files.
2. Root `AGENTS.md`.
3. `docs/architecture.md` and the domain document relevant to the task.
4. The actual files being changed.

Never assume a dirty worktree belongs to a previous agent and can be discarded. It
belongs to the user unless proven otherwise.

## Repository facts

- Remote: `https://github.com/isaacwallace123/ComputerCraft.git`
- Default/deployment branch: `master`
- Installed source root: `src/`
- Public bootstrap:

  ```text
  wget run https://raw.githubusercontent.com/isaacwallace123/ComputerCraft/master/bootstrap.lua
  ```

- Runtime: CC: Tweaked 1.113.1, Lua 5.2-style environment, Minecraft 1.20.1/Forge.
- Main target pack: Valhelsia 6.
- Current architectural feature level: five mining modes, persistent Devices roster,
  remote OTA control, coordinated quarry, secondary Fleet monitor.

## High-risk invariants

Before changing turtle behavior, preserve these unless the user explicitly chooses a
different tradeoff:

- Update `.nav` only after the game confirms movement.
- Never mine lava, another computer/turtle, chest, or barrel through navigation.
- A prospecting sector shaft is open only while a turtle is inside it. Treat a block
  placement as successful only after the block is observed in position.
- Evaluate the exact planned route home before outward movement.
- Count both tank and carried known fuel; retain fuel during unload.
- Always unload below the home block.
- Save mining progress after completed work so crashes repeat rather than skip.
- Network loss must not stop local safety or mining.
- Remote configuration and job assignment require a parked turtle.
- Readers must tolerate old snapshots and missing fields during rolling OTA updates.

## Where to make changes

**One system lives in this tree.** ICOS 1 is deleted. What a running fleet executes
today. Everything else is ICOS 2, which is built but, for the turtle and server
composition roots, not yet what a machine boots into. Where both exist the live one is
marked, because changing the wrong one produces a passing build and no change in the world
(D039).

| Goal | Start here |
| --- | --- |
| boot, role detection, what a machine runs on power-up | `src/startup.lua`, `src/os/kernel/boot.lua`, `src/os/kernel/roles.lua`, `src/os/kernel/splash.lua` |
| giving a machine a role, a name and a job | `src/commands/setup.lua`, `src/os/kernel/node.lua` |
| desktop/page/taskbar/input surfaces | `src/os/client/shell.lua`, `src/os/kernel/console.lua` |
| monitor selection/scaling | `src/adapters/cc/display.lua` |
| which surface an event belongs to, on a machine with two screens | `src/adapters/cc/input.lua` (`terminal`, `monitor`) |
| the base station's own two screens | `server.desktop` and `server.wall` in `src/os/server/main.lua` |
| telling a machine where it is | `src/commands/locate.lua`, `src/adapters/cc/locator.lua` |
| the Fleet dashboard | `src/apps/fleet/app.lua`, `src/apps/fleet/view.lua` |
| the operator console, and placing a mine | `src/apps/console/commands.lua`, `src/apps/console/app.lua` |
| a text input on any page | `Field` in `src/ui/components/controls.lua` |
| what a turtle is doing, and changing its settings | `src/apps/job/app.lua` |
| validating a job's settings, and rendering them as a form | `src/domain/turtle/settings.lua` |
| device list/detail/configuration | `src/apps/fleet/app.lua`, `src/apps/fleet/view.lua` |
| console command | `src/apps/console/app.lua` |
| Rednet transport | `src/ports/transport.lua`, `src/adapters/cc/transport.lua`, `src/domain/protocol/message.lua` |
| a message shape, the protocol name, the wire version | `src/domain/protocol/message.lua` |
| keeping ICOS 1 devices working under an ICOS 2 server | `src/os/server/services/bridge.lua` |
| turtle command or heartbeat | `src/os/turtle/main.lua`, `src/os/turtle/agent.lua`, `src/os/turtle/context.lua` |
| park/deploy/update lifecycle | `src/domain/turtle/lifecycle.lua` (the decisions), `src/os/turtle/runner.lua` (the effects), `src/os/turtle/control.lua` |
| what an ICOS 2 turtle actually runs as its job | `src/os/turtle/engine.lua`, wired from `boot.WIRING` |
| the job loop itself - park, deploy, cycle, recall | `src/os/turtle/runner.lua` (shared by both) |
| new prospecting profile | `src/os/turtle/jobs/prospecting/profiles.lua` plus a small definition |
| mining route/safety | `src/os/turtle/jobs/`, `src/os/turtle/jobs/common/safety.lua` |
| shaft caps and surface safety | `src/os/turtle/device/access.lua`, `src/os/turtle/jobs/prospecting/surface.lua` |
| unloading and depot overflow | `src/os/turtle/device/depot.lua` |
| movement/protected blocks | `src/os/turtle/device/nav.lua` |
| turtle-to-turtle awareness | `src/os/turtle/device/peers.lua` |
| fuel values/selection | `src/os/turtle/device/fuel.lua`, `src/os/turtle/device/fuel/catalog.lua` |
| which jobs exist and what they need | `src/domain/turtle/jobs.lua` |
| shared mine geometry | `src/domain/mine/plan.lua` |
| sector leases and frontiers | `src/domain/mine/registry.lua` (pure); `src/os/server/services/leases.lua` |
| chunk maths - coordinates, footprints, connectivity | `src/domain/chunk/grid.lua` |
| which general holds which chunk, and which miner works where | `src/domain/fleet/coverage.lua` (pure), `src/os/server/services/coverage.lua` |
| a turtle that holds a chunk loaded | `src/os/turtle/jobs/support/general.lua` |
| turtle sector claiming | `src/os/turtle/site.lua` (shared by both, protocol injected) |
| device roster, last known position | `src/domain/fleet/registry.lua` |
| what a device should be doing | `src/domain/fleet/desired.lua`, `src/os/server/services/reconcile.lua` |
| drop-offs and which one to use | `src/domain/depot/list.lua`, `src/domain/depot/select.lua` |
| auto-recovery rules | `src/domain/fleet/policy.lua`, `src/os/server/services/policy.lua` |
| accounts, balances, and the audit trail | `src/domain/bank/ledger.lua` (pure), `src/os/server/services/bank.lua`, `src/apps/bank/app.lua` |
| what is plugged in, and which mods are reachable | `src/ports/peripherals.lua`, `src/adapters/cc/peripherals.lua`, `src/domain/hardware/kinds.lua`, `src/apps/hardware/app.lua` |
| disk drives and floppies | `src/apps/disks/app.lua` |
| how a page asks for something to change | `src/os/kernel/request.lua` |
| a server-side service, or a new one | `src/os/server/main.lua`, `src/os/server/services/` |
| running services, restarts, health | `src/os/kernel/supervisor.lua`, `src/os/kernel/service.lua`, `src/apps/services/app.lua` |
| the log, and what reads it | `src/ports/log.lua`, `src/adapters/cc/log.lua`, `src/apps/logs/app.lua` |
| a new port, or a CC implementation of one | `src/ports/`, `src/adapters/cc/` |
| simulated-world tests | `tests/`, `tools/spec.ps1` |
| the simulated world itself | `src/adapters/sim/world.lua` |
| cell rendering, the diff, blit batching | `src/ui/render/buffer.lua`, `tests/ui/buffer_spec.lua` |
| state, bindings, and what gets repainted | `src/ui/state/reactive.lua`, `src/ui/runtime.lua` |
| how a screen is measured and placed | `src/ui/render/layout.lua` |
| a component, or a new one | `src/ui/components/`, then register it with `ui.define` |
| clicks, touches, focus, the tab ring | `src/ui/input.lua`, `Root:dispatch` in `src/ui/runtime.lua` |
| the event loop a screen runs in | `src/ui/host.lua` |
| springs, tweens, easings, the frame gate | `src/ui/state/anim.lua` |
| clipping, scrolling, overlays | `Buffer:clip` in `src/ui/render/buffer.lua`, `Scroll`/`Absolute` in `src/ui/render/layout.lua` |
| 2×3 pixel drawing and indexed sprites | `src/ui/render/canvas.lua`, `src/ui/render/sprite.lua`, `src/ui/components/graphics.lua` |
| a screen built on the framework | `src/apps/<id>/view.lua` |
| renderer performance numbers | `tools/bench.lua`, `tools/bench.ps1`, `docs/ui-framework.md` section 12 |
| how we compare to Basalt | `tools/compare.lua`, `tools/compare.ps1`, `docs/ui-framework.md` sections 12 and 16 |
| a colour, a token, or the theme | `src/ui/theme.lua`, `docs/ui-design.md`, `tools/preview.lua` |
| what a screen should look like | `docs/ui-design.md`, then `tools/preview.ps1` |
| trying the OS in a local world | `tools/link-world.ps1`, `tools/build.ps1`, `docs/operations.md` |
| the 1 MB disk limit, and what fits under it | `tools/build.ps1`, the `size` section of `tools/check.ps1` |
| seeing the new UI on real hardware | `src/apps/showcase/main.lua`, then run apps/showcase in game |
| updater/bootstrap | `bootstrap.lua`, `src/update.lua`, `tools/make-manifest.ps1` |
| what an update deletes, and what it must not | `src/lib/prune.lua`, `tests/lib/prune_spec.lua` |
| which apps a machine offers, and what they are called | `src/apps/registry.lua` |
| which files a role needs, and taking ICOS off a machine | the `roles` block in `tools/make-manifest.ps1`, `icos uninstall` in `src/icos.lua` |
| version automation | `.github/workflows/icos-version.yml`, `src/lib/version.lua` |

Every path in this table is checked by `tools\check-docs.ps1`. It was allowed to rot to
thirty-three broken rows out of forty — every one of them pointing at a file the D039
restructure moved — which made the first thing `AGENTS.md` tells an agent to read the
least reliable thing in the repository.

## ICOS 1 is gone

`src/legacy/` is deleted. It went in the order §14 set out: the turtle runtime first
because it was the piece most likely to need a second attempt, then the apps and commands,
then setup, then `startup.lua` last because every other step made it smaller.

**What that does and does not mean.** The tree has one architecture in it and no file is
waiting to be replaced. It does **not** mean ICOS 1 has stopped existing: every turtle in
the world is still running the build that was installed on it, and will be until it takes
an update. Two things in this repository exist only for those devices and must not be
tidied away as dead code:

- `os/server/services/bridge.lua` — a second inbox on `ccfleet`, so an ICOS 2 server can
  hear an ICOS 1 fleet.
- `os/turtle/legacy.lua` — the same in reverse, because §12 says turtles update before the
  base does, so a new turtle talking to an old base is the ordinary case.

Both carry a wire constant fixed by what is *deployed*, not by anything here: the hostname
`base` on the protocol `ccfleet`. Changing either is a deployment, not a rename.

They are deleted when every device reports a build that no longer needs them — which is a
thing to check on the Devices page, not to assume.

## Change checklist

1. Inspect status and preserve unrelated edits.
2. Trace callers and persisted/networked fields before renaming anything.
3. Keep entrypoints thin; put reusable behavior in the owning domain folder.
4. Add backward-compatible defaults for new persisted or snapshot fields.
5. Update the relevant document and decision log when behavior or rationale changes.
6. Regenerate the manifest for additions, deletions, or renames under `src/`.
7. Run checks.
8. Summarize changed behavior, verification, migration, and worktree state.

Verification commands:

```powershell
.\tools\make-manifest.ps1
.\tools\spec.ps1
.\tools\check.ps1
git diff --check
git status --short
```

`tools\check.ps1` runs `tools\check-docs.ps1` as its last section, so a moved file
that leaves the handoff map behind fails the same run that would have let it through.

`tools\spec.ps1` runs the turtle logic against a simulated world
(`src/adapters/sim/world.lua`, driven from `tests/`). Run it after any change to
`turtle/`, `jobs/`, `mine/`, `domain/`, or `ui/`. It is fast, needs nothing installed, and
it is the only thing in this repository that can actually execute a mining cycle —
including cutting power at every step of one and checking the ground afterwards.

`tools\bench.ps1` measures the renderer: blit calls and milliseconds per frame for an idle
screen, a dashboard update, and a full repaint. Run it after any change to `src/ui/` and
put the numbers in `docs/ui-framework.md` section 12. Hold changes to the **blit counts**,
which are properties of the algorithm; the times come from a desktop interpreter, not from
Cobalt, and are a floor rather than a prediction.

`tools\compare.ps1` runs the same workload through the dirty-rectangle design Basalt 2
uses, which is the standing answer to "why not just use Basalt". If a change to `src/ui/`
narrows that gap, it has probably broken the property the framework exists for. D029
records why row spans beat rectangles here; section 16 records what Basalt is better at
and what is worth taking from it.

`tools\check.ps1` also enforces the layering rule: nothing under `src/domain`, `src/ports`,
or `src/ui` may reference a CC global. D027 records the single allowed exception and why
it is there. If you need `fs`, `os`, or `term` in one of those folders, you need a port.

`tools/deploy.ps1` also commits and pushes. Use it only when the user explicitly asks
for publication. Documentation-only root files do not belong in `src/manifest.json`.

## Testing limitations

Static checks cannot simulate Minecraft blocks, peripherals, chunk unloading, or
Rednet range. For movement changes, recommend an in-world smoke test with:

- one turtle
- a small area
- a chest below home
- enough disposable fuel
- no nearby infrastructure
- observation of recall, unload, reboot resume, and depot-full behavior

Fleet-wide quarrying should be tested with two workers on a tiny rectangle before a
large AFK run.

## Current migrations and compatibility

- `.node.job = "expedition"` migrates to `rare`.
- Rare retains the `.expedition` file path for existing settings.
- Prospecting job files from the random-bearing builds keep their old `distance`,
  `cruise`, `tunnelLength`, `tunnelDone`, and `bearing*` keys harmlessly. Phase `shaft`
  migrates to `descend`; any other unknown phase restarts the route. A job file with
  `sector = 0` will not move: the runner walks home and asks for a sector first, because
  the unset shaft coordinates are `0,0` and that is a real place in the world.
- Prospecting now requires a world origin (`where`), as the coordinated quarry already
  did. `ready()` refuses to deploy without one. Where declares the current block as
  both relative home and world origin in one save; run it again after moving or turning
  a parked turtle.
- Ender modems are valid and recommended GPS hosts in CC: Tweaked 1.113.1. GPS still
  requires four loaded hosts and cannot determine a stationary turtle's heading, so
  `where` saves the origin and facing for durable dead reckoning.
- The `gps` role is available to non-Pocket computers with a wireless/Ender modem and
  is always visible on turtles so a dedicated Chunky Turtle can be assigned before
  its upgrades are arranged. Setup warns if the turtle has no wireless/Ender modem;
  the host cannot serve until one is equipped. Setup saves the advertised block
  coordinates in `.gps`; startup runs only `legacy/apps/gps_host.lua`. A Chunky Turtle may be
  one host and load the shared host chunk.
- ICOS v1.2.5 GPS setup used a greedy separator that could swallow a negative sign on
  Y or Z. Existing `.gps` values cannot be corrected automatically because their
  intended sign is unknowable. After updating, re-run GPS Setup on affected hosts and
  verify the explicit X/Y/Z confirmation screen. Coordinate inputs must use
  `core.util.coordinates`, never a `%D+` separator between signed numbers.
- The base needs a shared mine configured once, through Mine Control or `mine here`.
  `legacy/fleet/service.lua` leases sectors at boot; Fleet is only a view and need not stay
  open. Prospecting frontiers are keyed by job and target Y; do not collapse them into
  one sector-wide completion value.
- Pocket Computers use role `controller`, run `legacy/shell/handheld.lua`, and mirror the
  authoritative base. They must never host the base name or answer `mine` requests.
  Setup offers this role without a modem, but fleet traffic remains offline until a
  wireless or ender modem is attached.
- A peripheral can have multiple types. Use `peripheral.hasType(name, "modem")`; an
  exact comparison with the first `peripheral.getType` result can miss combined Ender
  Pocket upgrades and incorrectly disable the handheld role and Rednet.
- The base computer terminal and attached monitor run separate desktops. App metadata
  `requiresInput` is the safety boundary: the monitor receives only display-only
  variants, while configuration and command apps stay on keyboard-capable surfaces.
- Legacy relative quarry files are intentionally invalidated and require a new
  absolute assignment.
- Partial Quarry and Hollow runs resume their saved cells after recall/fuel/error;
  configuration changes and completed redeploys reset them.
- Prospecting persists a world coordinate beside an unfinished vein. Do not remove it
  or advance the sector frontier until that pending vein has been revisited.
- Prospecting job files now carry `access = { state, y }`, the shaft cap record. A file
  from v1.2.7 or earlier has none; `factory.load` normalises a missing or unusable
  record rather than trusting a coordinate that was never written. A turtle that reboots
  underground with no record is marked `legacy` and probes for the shaft head on the way
  out instead of guessing at it, and never re-runs the descent from below ground where
  every block downward looks like a surface. `restart` clears the record because a
  restart happens on the home block, above ground, and a stale `below` would make the
  next descent skip opening the surface and sink an uncapped shaft.
- Slot 16 (`access.SLOT`) is reserved for cap material. `inv.dropJunk` takes a slot to
  skip, unloading retains it, and the depot-full check excludes it. Removing any one of
  those three lets the turtle throw away the block it needs to close the surface.
- Shafts opened before v1.2.7 are sealed on the next visit to that sector. Since v1.2.9
  the base records which sectors have an open head and leases those out first, so a
  known hole is repaired by the next turtle that asks for work rather than only when the
  fleet happens to return there.
- `job.shaftOffset` slides a sector's head along its trunk when the nominated column
  cannot be sealed. Every route cost that mentions the shaft must use
  `shaftX + shaftOffset`, not `shaftX`; `factory.routeCost` and the runner's
  `returnDistance` both do.
- `job.stalls` counts consecutive cycles that mined nothing and moved no frontier. Two
  hands the sector back, four parks the turtle. It is the safety net for the route-around
  tolerance in `nav.ROUTE_AROUND`; do not relax one without the other.
- `.mine` sector records written before v1.2.9 have no `surface` key. `registry` fills in
  `unknown` on read, which must never be confused with `sealed`.
- Anything a turtle is not certain it closed is reported `open`, deliberately. Making
  that report optimistic would turn a missed seal into a silent hole.
- Fuel is a closed list in `turtle/fuel/catalog.lua`: coal and charcoal, loose or in
  block form. Do not restore the `turtle.refuel(0)` fallback. It answers yes for sticks,
  saplings, planks, and wooden tools, and anything counted as fuel is retained at every
  unload, so a permissive answer silently fills a turtle with canopy litter forever.
  Lava buckets and blaze rods are no longer fuel and are now delivered like any haul.
- `adapters/cc/config.lua` replaces state through a completed `.tmp` file. Its load fallback is
  part of crash-safe navigation; do not revert `.nav` to in-place overwrite.
- A standard mining turtle cannot carry pickaxe, modem, and Geo Scanner at once.
- The updater deploys only `src/manifest.json`; documentation remains repository-side.
- ICOS 2 phase 1 moved `domain/mine/plan.lua` and `domain/mine/registry.lua` to `domain/mine/`, with no
  logic changes. `src/mine/plan.lua` and `src/mine/registry.lua` are one-line aliases that
  return the moved module, and every caller in `src/` already uses the new path. The
  aliases exist so the spec suite resolved unchanged — which is the only evidence that a
  live fleet's sector bookkeeping came through the move unaltered — and are deleted when
  the specs are rewritten. Do not add new code against `mine.plan` or `mine.registry`.
- `world.reboot()` drops `package.loaded` for the code a simulated turtle runs. **Only add
  a pattern to that list if nothing outside the reboot set holds a reference across the
  boundary.** Re-requiring a module makes a fresh copy of every table in it, metatables
  included, so a value built by the old copy fails an identity test in the new one -
  silently. `^ui%.` was on the list and had to come off: an animation built through the old
  runtime asked a freshly required `ui/state/reactive.lua` whether its goal was a state object,
  was told no, and quietly animated a table.
- One 2×3 glyph can show only two colours. `ui/render/canvas.lua` keeps the two most frequent and
  maps any others through the active theme palette; do not replace that with distances
  between CC's default colours, because ICOS redefines every palette slot. Sprite assets
  are immutable hex rows with `.` transparency — replace a reactive asset rather than
  mutating its rows in place.
- `tests/support/world.lua` is likewise an alias for `src/adapters/sim/world.lua`.
  The world keeps `install()`, which writes CC's APIs onto `_G`, beside its new `ports()`.
  Both are correct for now: modules written before ports existed read those globals, and
  rewriting them all at once is the flag day the plan exists to avoid.
- `domain/fleet/registry.lua` is built but **nothing writes through it yet**. The live path
  is still `legacy/fleet/roster.lua`, which replaces a device's whole record on every heartbeat -
  so a turtle reporting no position erases the last one known. That is the bug the new
  module fixes, and swapping them over is a base-side change wanting an in-world test.
- `domain/mine/registry.lua` is pure: `now` is a **required** argument to everything that
  stamps or compares a time, and it neither reads nor writes a file. ICOS 1 gets its clock
  and its `.mine` back from `legacy/mine/registry.lua`. `util.since` requires its `now` for
  the same reason. **The layering check's allow list is empty and should stay that way** -
  an entry in it is a declaration that a pure folder is not pure. D027 and D041.
- **Never write `x and nil or y` as a guard.** It always evaluates to `y`, and it had left
  D020's display-only boundary open in three apps for as long as they had existed. Use a
  block. D045 also records why the first spec for it passed vacuously: a test for a
  boundary is worth nothing until it has been seen to fail.
- Do not give a clock a default. An optional `now` is how a second clock gets into the
  system without anybody declaring one, and it has already cost this fleet two turtles in
  one shaft: stamps taken from a clock port, compared against `os.epoch`, so every lease
  looked fifteen minutes stale the instant it was written. A comparison is as much a use
  of the clock as a stamp is.
- A **general** is a turtle whose job is holding one chunk loaded, not a role. The
  Chunky Turtle upgrade loads exactly the chunk it stands in and has no Lua API, so
  `grid.RADIUS` is 0 and a footprint is one chunk - but the rule enforced is **no two
  footprints intersect**, not "no two turtles in one chunk", because a radius-1 loader
  makes those two rules disagree and only the first stays correct. D046.
- **An expired chunk claim is not reassigned.** Unlike a sector lease, handing a stale
  chunk to a second general puts two loaders in one chunk - the exact waste the feature
  exists to avoid. Staleness stops a chunk counting as coverage; only an operator
  (`coverage.vacate`) or a general physically reporting from that chunk frees it.
- Coverage is only usable where it is **joined to the base chunk**. An island is held,
  reported as an island, and never assigned work: a miner sent into one would fly home
  through chunks nobody is loading and freeze part way with a full inventory.
- `coverage.PER_CHUNK` slices are a property of the **chunk**, never of the live
  headcount. `quarry` splits its area by `workerIndex` of `workerCount`, so a divisor
  that moved when a turtle went quiet would re-cut the area under every other turtle in
  that chunk. An absent miner leaves an unworked slice, which the next one picks up.
- `adapters/cc/machine.lua` is now called for real, from `os/kernel/boot.lua`, and its
  `chunkLoaded` is what reaches the job catalogue as the `chunky` capability. It is the
  one capability in `jobs.NEEDS` that can be *observed* rather than declared, because
  the upgrade is a peripheral.
- Specs live in **`tests/`**, mirroring `src/`, and are **discovered rather than listed** -
  `tools\spec.ps1` globs `tests\**\*_spec.lua`. There is no registry to update, because a
  spec nobody remembered to register is one that reports green by never running. They are
  outside `src/` deliberately: the updater deploys every file in `src/manifest.json` to
  every machine, and a turtle's one-megabyte disk has no use for a spec. See
  `tests/README.md`.
- **Any fake that blocks must yield.** A service body is a `while true` parked on a receive
  or a sleep, so a stub that returns instantly spins inside `coroutine.resume` - which
  never returns, so the supervisor never regains control and the suite hangs rather than
  fails. `tests/support/fleet.lua` follows this rule; copy it when writing a new fake.
- `tests/support/fleet.lua` passes `boot.machine` an explicit capability table. The real
  probe reads `peripheral`, `term` and `os.getComputerID`, and the only reason it ever
  worked in a spec was that some earlier file had installed a simulated world into `_G` and
  left it there - so a result depended on which other specs had run first.
- **Reading `.node` is forgiving; writing it is not.** `roles.roleOf` maps anything it
  cannot place to `client`, which is right for a machine whose record is damaged and wrong
  for setup - it would turn a typo into a base station that comes up as a client with no
  error attached. `os/kernel/node.lua` refuses a role nothing can boot, at the moment it is
  chosen. It also keeps every field it was not asked about, so re-running setup to rename a
  turtle does not discard its job.
- `domain/mine/registry.lua`'s `entry` is get-**or-create**. Scan loops must go through
  `peek`/`peekWork` instead: four of them did not, so the first claim on a fresh mine wrote
  a record for every sector in the plan. A live base's `.mine` was 10,626 bytes of 48
  records with zero holders, re-written whole on every claim and surface report.
- `settingFields` is now read by exactly one module, `domain/turtle/settings.lua`, and
  every `configure` goes through it. What stays in each job is only its own rule: quarry's
  corners may not cross and its worker index must fit its worker count, prospecting forgets
  a pending vein when `targetY` moves (**only** `targetY` - that vein is a real hole it
  promised to return to), hollow and quarry restart their cell walk. `settings.merge`
  reports whether anything actually moved, and every one of those resets depends on it:
  `reconcile` re-sends a goal until a device converges, so treating an identical re-send as
  a change would discard a part-finished layer every six seconds.
- `quarry.settingFields` is what a **person** is shown; `quarry.fields()` adds
  `workerIndex`/`workerCount`, which the base assigns and nobody hand-picks. They were
  previously validated by a private table that listed the visible ranges a second time.
- `setup(ui)` still exists because ICOS 1's runtime calls it. **Nothing in ICOS 2 does** -
  `apps/job/app.lua` renders the same declaration - so it dies with `legacy/miner/`.
- **A logger may not take down its caller.** `adapters/cc/logfile.lua` trimmed once at
  require time, which is fine for a turtle that reboots daily and useless on a base
  station that never does - a live base filled its disk and threw `Out of space` out of
  `log.info` into the app that called it. It now trims on a counter and drops a line it
  cannot write. `adapters/cc/storage.lua` returns `false` rather than raising for the
  same reason: `logrotate` guards on that `false` and the guard was unreachable, while
  `persist` and `leases` are critical services that were being given up on permanently.
  `world:fillDisk()` in the simulated world is what makes all of this testable - it is
  `fillDisk` and not `fill` because `world:fill` already places blocks.
- **ICOS 1 and ICOS 2 are on different rednet protocols** (`ccfleet` and `icos`), so they
  are mutually deaf without a translator. `os/server/services/bridge.lua` is that
  translator and it is **not optional**: every turtle in the live fleet is ICOS 1, and a
  server without it receives no heartbeats, leases no sectors, and cannot be addressed by
  an unupgraded handheld. §12's dual-run `events` flag does *not* cover this — it sends the
  old message shape on the new protocol, so it only ever reaches devices that already
  speak ICOS 2. D042.
- Every ICOS 2 message carries `v` and `build`, stamped by `domain/protocol/message.lua`,
  which is also the only place that spells the protocol name `icos`. The version gate is
  `discovery.dispatch` on the server and `agent.receive` on a device - one per side, never
  per handler. **A message from a newer build is accepted, not refused:** the updater
  upgrades machines one at a time, so a device running ahead of the machine reading its
  message is the normal case during a rollout. What makes that safe is the compatibility
  rule - a version bump may add fields and kinds, never change what an existing field
  means - so a change that cannot obey it needs a new `kind`, not a new version. D040.

## Handoff note template

Use this shape when handing unfinished work to another agent:

```text
Goal:
Branch and worktree:
Completed:
Still needed:
Files changed:
Persisted/protocol changes:
Migration concerns:
Checks run and results:
In-world tests still needed:
Do not disturb:
```

Update this document when a new sharp edge, invariant, or recurring handoff problem is
discovered. Chat history is temporary; this file is not.
