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
| shared mine geometry | `src/mine/plan.lua` |
| sector leases and frontiers | `src/mine/registry.lua`, `src/fleet/coordinator.lua` |
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
.\tools\check.ps1
git diff --check
git status --short
```

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
- The `gps` role is available to non-Pocket devices with a wireless/Ender modem. Setup
  saves the advertised block coordinates in `.gps`; startup runs only
  `apps/gps_host.lua`. A Chunky Turtle may be one host and load the shared host chunk.
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
- `core/config.lua` replaces state through a completed `.tmp` file. Its load fallback is
  part of crash-safe navigation; do not revert `.nav` to in-place overwrite.
- A standard mining turtle cannot carry pickaxe, modem, and Geo Scanner at once.
- The updater deploys only `src/manifest.json`; documentation remains repository-side.

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
