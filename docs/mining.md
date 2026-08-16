# Mining system

## Invariants

These rules are more important than any one mining pattern:

1. Home is relative coordinate `0,0,0` for the current deployment.
2. Navigation state is saved only after a movement succeeds.
3. A potentially outward move is allowed only while all fuel aboard covers the exact
   planned return route plus a safety margin.
4. Fuel is retained during unloading and consumed lazily.
5. Every mining job unloads into a chest below its home block.
6. Lava, computers, turtles, chests, and barrels are not deliberately mined.
7. Recall unwinds through the normal return route and is not reported as a failure.
8. Unexpected modded drops are kept; unknown items are not treated as junk by default.

## Job contract

Jobs are registered in `src/apps/miner.lua`. A job module provides:

| Member | Purpose |
| --- | --- |
| `name`, `label`, `PATH` | stable identity, UI label, and persistence file |
| `load()` / `save(job)` | persistent configuration and progress |
| `setup(ui)` | local interactive configuration |
| `configure(job, settings)` | remote configuration validation |
| `ready(job)` | launch-time preflight |
| `restart(job)` | prepare a fresh deployment or cycle |
| `status(job)` | progress, haul, delivered count, and public settings |
| `minimumFuel(job)` | safe launch threshold shown in Devices |
| `run(job, ctx)` | perform work and return a result kind |
| `settingFields` | schema rendered by Devices |

`ctx.report(phase, detail)` updates telemetry. `ctx.aborted()` returns the recall reason
or nil. Result kinds used by runtime are `cycle`, `complete`, `fuel`, and `recalled`.
Set `continuous = true` only for jobs where choosing a fresh route after unloading is
useful.

## Current jobs

### Quarry

`jobs/quarry.lua` excavates an absolute X/Z rectangle from `topY` through `bottomY`.
Workers need a world origin and heading from the Where tool. The coordinator converts
the rectangle to a serpentine flat cell sequence and gives each available turtle a
balanced contiguous range. Every pass occupies one layer and clears the block below,
so two vertical blocks are completed per cell.

Quarry is finite. Progress is saved as `layer` plus `cell`. An old relative
width/length/depth `.quarry` file is marked unconfigured rather than interpreted as
absolute coordinates.

### Rare, Fuel, and Resources

These jobs are definitions built by `jobs/prospecting/factory.lua` and executed by the
shared runner:

- Rare excludes coal, iron, copper, zinc, and andesite, then accepts `_ore` blocks and
  ancient debris. Default target is Y -59.
- Fuel accepts coal ore only. Default target is Y 96.
- Resources accepts iron, copper, zinc, and andesite. Default target is Y 16.

Each cycle chooses an independent random bearing, travels at cruise altitude, sinks to
the configured Y, and mines roughly outward from base. The branch grid has ribs every
three blocks. Inspecting each tunnel cell and following adjacent veins covers the
space between ribs without excavating every stone block.

Vein following is recursive, capped by both depth and block budget, and always unwinds
to its starting cell and facing. This is what lets the main runner continue without
reconstructing its path.

If a compatible miner exposes a Geo Scanner, the runner may take short targeted routes
to matching blocks before the ordinary branch grid. Scanner coordinates are bounded by
the requested radius before navigation. Scanner failure, cooldown, or absence falls
back to normal mining.

### Hollow

`jobs/hollow.lua` travels to a configurable rectangle and sweeps it serpentine at the
middle Y, default -30. Entering each cell clears the middle block; `digUp` and `digDown`
clear the other two. A failed vertical dig does not advance the cell checkpoint.

Hollow is finite and saves its current cell.

## Fuel accounting

`turtle/fuel.lua` separates three concepts:

- tank fuel from `turtle.getFuelLevel()`
- known inventory potential from `turtle/fuel/catalog.lua`
- total available movement = tank + carried potential

Known fuel includes coal, charcoal, coal blocks, lava buckets, blaze rods, and dried
kelp blocks. Unknown modded fuel is detected with `turtle.refuel(0)` and retained.
When an item must be consumed, its observed value can be learned for the running
session. Smaller fuels are preferred when they avoid overshoot; large compact fuels
remain inventory reserve as long as possible.

`jobs/common/safety.lua` asks the active job for its planned return cost. This matters
because a safe shaft route may be longer than raw Manhattan distance home. Two extra
fuel units and the job margin cover the proposed move and local uncertainty.

## Inventory policy

Prospecting drops common tunnel waste in place. The junk list is intentionally an
item-name list because inspection sees block names while inventory sees drop names.
Resources removes andesite from the junk policy. All unloading uses
`inv.dropAllExcept` with the fuel predicate, so burnable reserves remain aboard.

If the chest cannot accept all non-fuel items, the job reports `depot full` rather
than parking as healthy.

## Adding a mining job

1. Prefer a small definition over copying a runner. Use the prospecting factory when
   only targets and defaults differ.
2. Define persisted defaults and a stable path.
3. Validate every remotely configurable value and expose the same fields in status.
4. Calculate the route the job will actually use to return, not a straight-line guess.
5. Check recall and fuel before every movement that can increase return cost.
6. Save progress after confirmed work, never before it.
7. Return home and unload on success, recall, fuel reserve, and recoverable stops.
8. Register the job in `apps/miner.lua` and `apps/devices.lua`.
9. Document the mode here and regenerate `src/manifest.json`.
10. Test a tiny area with one turtle before attempting a fleet-scale run.
