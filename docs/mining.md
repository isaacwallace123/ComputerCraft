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
9. Another turtle blocking the way is a delay, never a reason to abandon a trip.
10. A cycle that ends early saves enough state to resume the same ground, not to pick
    new ground.
11. A sector shaft is open only while a turtle is physically inside it. Mining below an
    exposed vertical shaft is a failure, not a trade-off.

## The shared mine

Prospecting jobs do not choose where to dig. `mine/plan.lua` divides the world once into
a grid of square sectors centred on the base, enumerated ring by ring outward, skipping
the centre cell where the base sits. Every number below is derived from the plan by pure
arithmetic on both the base and the turtle, so only the plan is ever transmitted.

| Concept | Meaning |
| --- | --- |
| sector | one `cellSize` square of ground, with one shaft at its centre |
| shaft | the single reusable vertical hole into that sector, kept capped when idle |
| cap | the block sealing a shaft head flush with the ground it was cut through |
| trunk | a tunnel spanning the sector along world X at the shaft's Z |
| ribs | perpendicular branches every `branchSpacing`, reaching each sector edge without crossing it |
| frontier | how far one profile/depth has completed the sector trunk |
| lane | one of eight staggered cruise altitudes used to reduce shared airspace |

Depth is deliberately **not** part of the plan: Rare wants Y -59 and Resources wants
Y 16, and both should be able to share a shaft. Each job keeps its own `targetY` and
extends the shaft vertically if it needs to go higher or lower. Frontiers and exhaustion
are keyed by job and target Y, so completing Rare never skips Resources ground at a
different depth.

`mine/registry.lua` runs on the base and owns leases and frontiers. `mine/site.lua` runs
on the turtle, caches the plan, and asks for a sector at each redeploy. A turtle that
gets no answer within three seconds keeps the sector it already held, or falls back to
one derived from its computer ID. Its per-job fallback advances only after a sector is
fully exhausted, so offline operation does not stall at the completed frontier or open
a new hole per ordinary cycle. An explicit refusal from a reachable base remains
authoritative, preventing an exhausted or replaced grid from being reopened. Losing
the base costs coordination, never local safety or return behavior.

The base service starts with ICOS and answers claims even when Fleet is closed. The
Fleet app is now only a dashboard.

## Surface safety

One shaft per sector bounds how many holes exist. It does **not** make the surface
safe, and it was never sufficient on its own: four sectors meant four unmarked
hundred-block drops in ground people walk across, and a small number of death traps is
not a safe worksite. Hole count and hole danger are separate problems.

`turtle/access.lua` closes the second one. A sector shaft is open only while a turtle is
inside it:

1. Descending, the turtle finds the real top of the ground in the shaft column, steps
   below it, and immediately places a block overhead.
2. The whole underground trip — transit, mining, veins, ribs — happens under a sealed
   surface.
3. Returning, it breaks that block from underneath, climbs through, and replaces it
   from above before flying to the cruise lane.

The ground is measured, never assumed. The plan's `surfaceY` is the *base's* surface;
terrain at a sector rings out is a different height, so the head is located by
inspection: the first trusted solid block downward, or — for a shaft an older build left
open, which never reports ground downward at all — the level at which the one-block
column becomes enclosed on all four sides. Leaves, snow, crops, logs, and carpets are
explicitly not trusted as ground or as a cap.

Cap material comes from a conservative allow list of worthless stone and dirt, filtered
against the running profile's own ore matcher and against fuel, so a turtle never walls
a shaft up with something it was sent to collect. Gravity blocks are excluded for a
structural reason: sand placed over a shaft falls down it and reopens the hole. Slot 16
is reserved for the cap, junk dropping skips that slot, and unloading retains it, so the
block needed to close the surface cannot be thrown away during the transition. As a last
resort the turtle mines one block out of the shaft wall below the surface.

Placement counts only once the block is observed in position; `placeUp`/`placeDown`
returning true is not taken as proof. The cap move is persisted as a named transition —
`opening`, `below`, `reopening`, `resealing`, `sealed` — because breaking and replacing
a block cannot be atomic. A reboot in the middle resolves from the turtle's own
position: below the opening it seals upward and continues the trip, at or above it seals
downward and the descent begins again.

The route geometry is unchanged. Capping costs digs and placements, which are free;
`ACCESS_RESERVE` covers only the bounded detour a crash recovery may take to get back
under its own opening, so the exact return-route fuel reserve still describes the route
the turtle actually flies.

Known limits:

- A shaft head under water or lava, or blocked by a protected block, aborts the cycle
  with a message naming the sector and coordinates rather than digging on below an
  opening it cannot close.
- If the head sits under a cliff overhang, the cap closes the top of the column; a
  secondary opening where the shaft passes through ground under the ledge is possible.
- A shaft that was already open when a turtle rebooted underground, with a job file from
  before caps existed, is sealed by probing for the head on the way out. If that probe
  disagrees with the plan's surface by more than 16 blocks it refuses to guess and asks
  for the shaft to be capped by hand.

Configure the mine from Mine Control on the base or Pocket controller, or from Fleet
Console on the base desktop:

For the normal case, choose **Mine Control → Start diamond mining**. If the mine has
not been placed yet, choose GPS or enter the base coordinates once. The single base
operation atomically creates 48-block sectors with a requested 64-block base keepout,
sets every connected parked miner to Rare at Y -59, and queues deployment. Existing
mine geometry is respected. The controls and commands below are advanced tuning.

```text
mine here              centre it on the base computer, using GPS
mine at <x> <y> <z>    centre it explicitly
mine size <blocks>     sector edge length, default 48
mine rings <1-8>       how far out sectors may be opened, default 3
mine keepout <blocks>  never dig within this radius of the centre
mine                   show the plan and every opened sector
```

The mine surface must be Y -63..310; the upper bound leaves room for all eight
cruise lanes below the build limit.

There are two ways to keep the digging away from where you live, and they are not the
same. `mine at` moves the whole worksite somewhere else — the turtles still fly home to
their own chests, so the commute is paid every cycle. `mine keepout` leaves the mine
centred on base but refuses the inner rings, which costs a longer commute for the same
reason but keeps the sector grid anchored to something you can find.

Sectors are leased inner-ring-first, so the cheapest allowed ground is always used
before anything further out.

Moving the centre, changing the sector size, or changing the keep-out radius clears all
recorded progress, because sector N then refers to different ground.

Every prospecting turtle needs a world origin from the `where` tool, the same
prerequisite the coordinated quarry has. `ready()` refuses to deploy without one.
Run `where` again after physically moving or turning a parked turtle; it resets the
relative home frame and world heading together before another absolute route is used.

## Job contract

Jobs are registered in `src/apps/miner.lua`. A job module provides:

| Member | Purpose |
| --- | --- |
| `name`, `label`, `PATH` | stable identity, UI label, and persistence file |
| `load()` / `save(job)` | persistent configuration and progress |
| `setup(ui)` | local interactive configuration |
| `configure(job, settings)` | remote configuration validation |
| `ready(job)` | launch-time preflight |
| `prepare(job)` | optional; acquire route/assignment state needed by preflight |
| `restart(job)` | prepare a fresh deployment or cycle |
| `status(job)` | progress, haul, delivered count, and public settings |
| `status().standing` | optional; progress to report while parked, see below |
| `minimumFuel(job)` | safe launch threshold shown in Devices |
| `run(job, ctx)` | perform work and return a result kind |
| `settingFields` | schema rendered by Devices |

`ctx.report(phase, detail)` updates telemetry. `ctx.aborted()` returns the recall reason
or nil. Result kinds used by runtime are `cycle`, `complete`, `fuel`, and `recalled`.
Set `continuous = true` only for jobs where choosing a fresh route after unloading is
useful.

### Progress while parked

A job whose `progress` tracks the current route — as prospecting does, mapping each of
`travel`/`descend`/`transit`/`mining`/`home` to a fraction — must also return
`standing`: what remains true when the turtle is not on a route at all. Prospecting
returns its sector completion.

Without it a recalled turtle reports the `home` phase's 95% for as long as it stays
parked, which reads as a turtle stuck on the way back and cannot be told apart from one
that genuinely is. Quarry and Hollow track durable cell counts rather than route phase,
so they correctly omit `standing` and keep reporting `progress`.

`parkKind == "complete"` still overrides everything to 100%.

## Current jobs

### Quarry

`jobs/quarry.lua` excavates an absolute X/Z rectangle from `topY` through `bottomY`.
Workers need a world origin and heading from the Where tool. The coordinator converts
the rectangle to a serpentine flat cell sequence and gives each available turtle a
balanced contiguous range. Every pass occupies one layer and clears the block below,
so two vertical blocks are completed per cell.

Quarry is finite. Progress is saved as `layer` plus `cell`. An old relative
width/length/depth `.quarry` file is marked unconfigured rather than interpreted as
absolute coordinates. Recall, fuel, and recoverable error redeploys resume those saved
counters; a completed run or a changed assignment starts from zero.

### Rare, Fuel, and Resources

These jobs are definitions built by `jobs/prospecting/factory.lua` and executed by the
shared runner:

- Rare excludes coal, iron, copper, zinc, and andesite, then accepts `_ore` blocks and
  ancient debris. Default target is Y -59.
- Fuel accepts coal ore only. Default target is Y 96.
- Resources accepts iron, copper, zinc, and andesite. Default target is Y 16.

All three work the shared mine described above. A cycle is five phases:

| Phase | What happens |
| --- | --- |
| `travel` | fly to the sector shaft at this sector's cruise lane altitude |
| `descend` | find and open the shaft head, seal it overhead, drop to the target Y |
| `transit` | walk the trunk tunnel out to the sector's saved frontier |
| `mining` | extend the trunk, cut ribs, follow veins, advance the frontier |
| `home` | back along the trunk, out through the shaft head, reseal it, then home |

Telemetry reports `opening` and `sealing` while the cap is being moved, so a turtle
paused at the surface can be told apart from one paused on a route.

The branch grid has ribs every three blocks. Inspecting each tunnel cell and following
adjacent veins covers the space between ribs without excavating every stone block.

Vein following is recursive and always unwinds to its starting cell and facing, which is
what lets the runner continue without reconstructing its path. It is bounded by a block
budget and a radius from the entry cell — deliberately not by recursion depth, which
stops part-way along a long vein in whichever direction the recursion happened to try
first. A small separate gap budget lets it step through one block of waste, because
large 1.20 ore veins are noisy enough that a strict six-face fill abandons most of one.
Gap probes begin only after the turtle has entered a wanted block; ordinary trunk and
rib cells are inspected without excavating exploratory pockets into empty rock.

Running out of budget sets a `truncated` flag. The runner then holds the sector frontier
where it is and saves a reachable coordinate beside the remaining ore. The next cycle
revisits that coordinate before advancing; merely returning to the trunk is insufficient
because the mined portion of the vein is now an air path rather than adjacent ore.
On reboot, a miner in the `mining` phase first returns to that durable frontier cell;
this also recovers safely if power was lost part-way through a rib or recursive vein.

If a compatible miner exposes a Geo Scanner, the runner may take short targeted routes
to matching blocks before the ordinary branch grid. Scanner coordinates are bounded by
the requested radius before navigation. Scanner failure, cooldown, or absence falls
back to normal mining.

### Hollow

`jobs/hollow.lua` travels to a configurable rectangle and sweeps it serpentine at the
middle Y, default -30. Entering each cell clears the middle block; `digUp` and `digDown`
clear the other two. A failed vertical dig does not advance the cell checkpoint.

Hollow is finite and saves its current cell. Like Quarry, a partial deploy resumes that
cell, while changed settings or redeploying a completed room starts a fresh sweep.

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

Prospecting adds `ACCESS_RESERVE` to that return cost while the route runs through a
shaft, and twice over to `minimumFuel`/`estimateFuel`. Moving a cap is digs and
placements, which cost no fuel; the reserve exists so the short detour a crash recovery
takes to get back underneath its own opening can never be the move the turtle could not
afford.

## Inventory policy

Prospecting drops common tunnel waste in place. The junk list is intentionally an
item-name list because inspection sees block names while inventory sees drop names.
Resources removes andesite from the junk policy. All unloading uses
`inv.dropAllExcept` with the fuel predicate, so burnable reserves remain aboard.

Slot 16 is reserved for shaft cap material and is exempt from both. Cap material and
tunnel waste are the same blocks — cobblestone is the cheapest cap and the first thing
the junk policy throws away — so `inv.dropJunk` takes the reserved slot and skips it,
and unloading keeps it aboard for the next cycle. A retained cap slot is not counted as
an undelivered load, so it cannot be mistaken for `depot full`.

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
