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

| Goal | Start here |
| --- | --- |
| desktop/page/taskbar/input surfaces | `src/core/desktop.lua`, `src/core/apps.lua` |
| monitor selection/scaling | `src/core/display.lua`, `src/apps/fleet.lua` |
| device list/detail/configuration | `src/apps/devices.lua`, `src/fleet/roster.lua` |
| console command | `src/core/console.lua` |
| Rednet transport | `src/core/net.lua` |
| turtle command or heartbeat | `src/miner/network.lua`, `src/miner/context.lua` |
| park/deploy/update lifecycle | `src/miner/runtime.lua` |
| new prospecting profile | `src/jobs/prospecting/profiles.lua` plus a small definition |
| mining route/safety | `src/jobs/`, `src/jobs/common/safety.lua` |
| shaft caps and surface safety | `src/turtle/access.lua`, `src/jobs/prospecting/surface.lua` |
| unloading and depot overflow | `src/turtle/depot.lua` |
| shared mine geometry | `src/domain/mine/plan.lua` |
| simulated-world tests | `tools/spec/`, `tools/spec.ps1` |
| the simulated world itself | `src/adapters/sim/world.lua` |
| a new port, or a CC implementation of one | `src/ports/`, `src/adapters/cc/` |
| cell rendering, the diff, blit batching | `src/ui/buffer.lua`, `tools/spec/buffer_spec.lua` |
| state, bindings, and what gets repainted | `src/ui/reactive.lua`, `src/ui/runtime.lua` |
| how a screen is measured and placed | `src/ui/layout.lua` |
| a component, or a new one | `src/ui/components/`, then register it with `ui.define` |
| clicks, touches, focus, the tab ring | `src/ui/input.lua`, `Root:dispatch` in `src/ui/runtime.lua` |
| the event loop a screen runs in | `src/ui/host.lua` |
| a screen built on the framework | `src/apps/<id>/view.lua` |
| renderer performance numbers | `tools/bench.lua`, `tools/bench.ps1`, `docs/ui-framework.md` section 12 |
| how we compare to Basalt | `tools/compare.lua`, `tools/compare.ps1`, `docs/ui-framework.md` sections 12 and 16 |
| a colour, a token, or the theme | `docs/ui-design.md`, `tools/preview.lua` |
| what a screen should look like | `docs/ui-design.md`, then `.\tools\preview.ps1` |
| sector leases and frontiers | `src/domain/mine/registry.lua`, `src/fleet/coordinator.lua` |
| turtle sector claiming | `src/mine/site.lua` |
| movement/protected blocks | `src/turtle/nav.lua` |
| turtle-to-turtle awareness | `src/turtle/peers.lua` |
| fuel values/selection | `src/turtle/fuel.lua`, `src/turtle/fuel/catalog.lua` |
| updater/bootstrap | `bootstrap.lua`, `src/update.lua`, manifest tool |
| version automation | `.github/workflows/icos-version.yml`, `src/core/version.lua` |

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

`tools\spec.ps1` runs the turtle logic against a simulated world
(`src/adapters/sim/world.lua`, driven from `tools/spec/`). Run it after any change to
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
  coordinates in `.gps`; startup runs only `apps/gps_host.lua`. A Chunky Turtle may be
  one host and load the shared host chunk.
- ICOS v1.2.5 GPS setup used a greedy separator that could swallow a negative sign on
  Y or Z. Existing `.gps` values cannot be corrected automatically because their
  intended sign is unknowable. After updating, re-run GPS Setup on affected hosts and
  verify the explicit X/Y/Z confirmation screen. Coordinate inputs must use
  `core.util.coordinates`, never a `%D+` separator between signed numbers.
- The base needs a shared mine configured once, through Mine Control or `mine here`.
  `fleet/service.lua` leases sectors at boot; Fleet is only a view and need not stay
  open. Prospecting frontiers are keyed by job and target Y; do not collapse them into
  one sector-wide completion value.
- Pocket Computers use role `controller`, run `core/handheld.lua`, and mirror the
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
- `core/config.lua` replaces state through a completed `.tmp` file. Its load fallback is
  part of crash-safe navigation; do not revert `.nav` to in-place overwrite.
- A standard mining turtle cannot carry pickaxe, modem, and Geo Scanner at once.
- The updater deploys only `src/manifest.json`; documentation remains repository-side.
- ICOS 2 phase 1 moved `mine/plan.lua` and `mine/registry.lua` to `domain/mine/`, with no
  logic changes. `src/mine/plan.lua` and `src/mine/registry.lua` are one-line aliases that
  return the moved module, and every caller in `src/` already uses the new path. The
  aliases exist so the spec suite resolved unchanged — which is the only evidence that a
  live fleet's sector bookkeeping came through the move unaltered — and are deleted when
  the specs are rewritten. Do not add new code against `mine.plan` or `mine.registry`.
- `tools/spec/support/world.lua` is likewise an alias for `src/adapters/sim/world.lua`.
  The world keeps `install()`, which writes CC's APIs onto `_G`, beside its new `ports()`.
  Both are correct for now: modules written before ports existed read those globals, and
  rewriting them all at once is the flag day the plan exists to avoid.
- `domain/mine/registry.lua` still reads `os.epoch` and persists through `core/config`, so
  it is not yet pure domain code. It is the one entry in the layering check's allow list.
  Threading a clock and a storage port through `fleet/coordinator.lua` and
  `core/console.lua` is what empties it; see D027.

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
