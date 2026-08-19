# Decision log

This is a lightweight architecture decision record. Add an entry when a future
maintainer might otherwise “simplify” something and reintroduce an old failure.

## D001 — Repository is the source of truth

**Status:** accepted

In-game files are deployment artifacts and contain per-device state. Editing source in
the repository keeps changes reviewable and recoverable. The updater installs only
manifest-listed `src/` files; it does not overwrite operational dotfiles.

## D002 — Pin updater downloads to a commit SHA

**Status:** accepted

Raw GitHub branch URLs were observed serving stale content despite query-string and
cache-control attempts. The updater resolves `master` through the GitHub API and uses
immutable SHA URLs. Falling back to a branch is allowed only when resolution fails and
is surfaced to the user.

## D003 — Generate the deployment manifest

**Status:** accepted

CC: Tweaked cannot discover repository files remotely. `src/manifest.json` is generated
from `src/` by `tools/make-manifest.ps1`. Hand-editing it risks omissions, stale files,
or a BOM that breaks JSON parsing. The updater intentionally does not delete paths that
fall out of the manifest; removing a module means first removing every live reference.

## D004 — Rednet is best-effort

**Status:** accepted

Wireless turtles naturally leave range. Job correctness therefore cannot depend on
an acknowledgement or active base. Turtles own navigation, fuel safety, and progress;
the base observes and commands when reachable.

## D005 — Park instead of exiting

**Status:** accepted

A completed, recalled, or fuel-limited turtle stays in the miner runtime. This keeps
it visible and remotely deployable, configurable, and updateable. Park reason and kind
are persisted so reboot does not erase the explanation.

## D006 — One desktop page, one title bar

**Status:** accepted

Fleet, Devices, and other apps are maximized pages managed by the desktop taskbar.
Apps own their header when focused; Home is the only permanent page. Nested app frames
created duplicate title bars and wasted monitor space.

## D007 — Fleet overview and Devices details are separate

**Status:** accepted

Fleet stays dense enough for 10–20 miners. Selecting a row opens Devices for controls,
settings, version, and detail. This prevents per-miner detail panels from crowding the
overview and gives every connected device one consistent control surface.

## D008 — Every mining depot is below home

**Status:** accepted

A turtle placed by another turtle may face an unpredictable direction. Dropping down
is orientation-independent, while “behind” is not. All jobs retain fuel and unload
non-fuel inventory downward. Protected-block navigation prevents mining the depot.

## D009 — Fuel reserve follows the planned return route

**Status:** accepted

Tank fuel alone is not the turtle's actual range; coal, blocks, lava, and other fuel in
inventory matter. Conversely, Manhattan distance is not always the real return cost
because jobs unwind through known shafts. The safety check therefore uses total
available fuel and a job-specific return path plus margin.

## D010 — Prospecting uses profiles over copied jobs

**Status:** accepted

Rare, Fuel, and Resources differ mainly in target selection and defaults. A shared
factory and runner keep movement, recall, unloading, and safety behavior consistent.
Profiles can evolve without maintaining three near-identical state machines.

## D011 — Quarry uses absolute coordinates and balanced cell ranges

**Status:** accepted

Independent relative quarries overlap and cannot guarantee an entire requested area.
The base assigns one absolute rectangle and partitions its serpentine cell sequence.
This supports differently oriented/home-positioned turtles and balances skinny as well
as square areas. World origin calibration is required.

## D012 — Unknown items are valuable until proven otherwise

**Status:** accepted

Modpacks add drops the code does not know. Junk disposal uses a conservative explicit
list, while rare block selection recognizes generic `_ore` names. Accidentally hauling
extra material is preferable to deleting an important modded resource.

## D013 — Geo Scanner acceleration is optional

**Status:** accepted

Scanner availability, energy, cooldown, and upgrade slots vary by hardware. It can
provide targeted shortcuts, but the branch grid remains complete without it. A scanner
failure must degrade to ordinary mining instead of stopping a prospecting cycle.

## D015 — Prospecting shares a fixed grid of shafts

**Status:** accepted

Each prospecting cycle used to roll an independent random bearing, fly out, and sink a
fresh shaft. The number of holes near a base therefore grew with the number of cycles
run, without bound, and nothing was ever reused.

The world is now divided once into square sectors around the base
(`domain/mine/plan.lua`).
Each sector has one shaft at its centre, extended vertically on first use and reused thereafter, and
one trunk tunnel with ribs that stays strictly inside the sector bounds. Hole count is
now bounded by sectors opened, not cycles run, and every later trip into a sector walks
tunnels that already exist.

This bounds the number of openings and nothing else. It is not, and was never, enough to
make the surface safe; see D023 for the cap that does that.

The trade is longer commutes to outer rings and a hard requirement that every
prospecting turtle has a world origin, the same prerequisite the coordinated quarry
already had. Sectors are handed out inner-ring-first so the cheap ground is used first.

## D016 — A sector frontier is what makes work resumable

**Status:** accepted

Ending a cycle used to discard the route. A turtle that filled its inventory beside a
large vein went home, re-randomised, and never returned — the visible symptom being ore
left obviously unmined.

Each sector now stores a `frontier` for each job/depth key: how far along that trunk the
fleet has mined. This lets different profiles share a shaft without sharing completion.
It is held at the base (`domain/mine/registry.lua`) and cached on the turtle
(`legacy/mine/site.lua`), and
survives unload, reboot, recall, and fuel aborts. A cycle that ends early resumes at the
same tunnel. When a vein outlasts the vein budget the frontier is deliberately not
advanced past it, so the next cycle re-enters the same ore.

## D017 — Another turtle is a delay, not a failure

**Status:** accepted

Navigation refuses to mine computers, and every such refusal used to end the trip. Two
turtles meeting in a tunnel therefore sent at least one of them home. As a fleet grows
this becomes the dominant cause of abandoned cycles.

`nav` now classifies obstacles: hazards and protected blocks still end a route, but a
turtle is a transient obstacle. The blocked turtle waits, and `goTo` steps aside and
re-plans rather than reporting failure. Right of way goes to the lower computer ID —
derivable by both sides with no negotiation and asymmetric when both positions are
current. Peers are tracked from the status broadcasts every miner already sends; stale
or unavailable peer data falls back to bounded waits and route detours.

The refusal check also moved inside the dig retry loop. Checking only on entry meant a
turtle that arrived while its neighbour was chewing through gravel could be mined up.

## D023 — A sector shaft is capped whenever nobody is inside it

**Status:** accepted

D015 bounded how many holes the fleet opens. It did not make them safe, and the
distinction matters more than the count: four miners on four sectors immediately left
four unmarked hundred-block drops at the surface. A player walking the worksite falls
into one and dies, and being able to count them on one hand does not help.

Each shaft is therefore sealed except while a turtle is passing through it. The descent
locates the real top of the ground by inspection, steps below it, and places a block
overhead before any mining starts; the return breaks that block from underneath, climbs
through, and replaces it from above. `os/turtle/device/access.lua` owns the mechanics — block
classification, cap material selection, verified placement — and the prospecting runner
owns when they happen.

The alternative considered was a single shared access shaft for the whole fleet, which
would minimise openings to exactly one. It was rejected: it concentrates every miner
into one vertical corridor, creating head-on collisions the peer rules resolve by
waiting, a throughput ceiling that scales the wrong way with fleet size, and a
recovery problem where one stuck turtle blocks every other turtle's only way home.
It also does not solve the stated problem, because the one remaining shaft is still an
open hole and would need a cap anyway. Capping per sector keeps the existing geometry,
the existing traffic model, and the existing exact return-fuel calculation, and pays
only digs and placements — which cost no fuel.

Three properties are load-bearing and should not be "simplified" away:

- The ground height is measured, never taken from the plan's `surfaceY`. That value is
  the base's surface; terrain a few sectors out is a different height, and a cap placed
  at the wrong Y leaves the real hole open while looking finished.
- A placement counts only after the block is observed in position. `placeUp` returning
  true is not proof, and "probably sealed" is the failure this decision exists to stop.
- The transition is persisted by name, not just by endpoint. Breaking and replacing a
  block cannot be atomic, so a reboot must be able to tell "about to open" from "open"
  from "closed again", and resolve it from the turtle's own position.

Where automatic repair is not possible — a head under water, a protected block in the
way, no filler and no wall to mine — the cycle stops and reports which of those it was.
An exposed shaft is reported ahead of a full depot, because one is inconvenient and the
other is a hole somebody falls into.

## D024 — Turtle logic is tested against a simulated world

**Status:** accepted

Every claim about crash safety in this repository was an argument. The linter checks
types; nothing could execute a turtle, and the only way to reach a lava pocket, a full
inventory, or a server restart was to fly out and watch. PR #12 shipped a cap mechanism
whose correctness rested entirely on reasoning about power-loss windows.

`tests/` drives a sparse block world that with the CC: Tweaked turtle, fs, and peripheral
APIs implemented over it, refusals included. Two properties make the interesting tests
possible: the filesystem lives in the world rather than in a module, so dropping
`package.loaded` is exactly a reboot; and every world interaction ticks a counter that
can be armed to throw, so "lose power immediately after the 37th block operation" is
something a test can ask for.

The headline test cuts power after every single operation of a complete mining cycle —
one run per operation, each rebooted until it finishes — and asserts the sector shaft is
shut at the end of all of them.

There is no Lua interpreter on the development machine, but the Lua language server
binary the checks already locate is one, so the suite needs nothing new installed. The
specs are not a substitute for in-world testing: they cannot simulate chunk unloading,
Rednet range, or server tick behaviour. They retire the category of bug that used to be
found at 3am.

## D025 — Anything that must not be broken is a detour, not a failure

**Status:** accepted

D017 made another turtle a delay rather than a failure. Lava was left as a hazard that
ended the trip, which at Y -59 meant one pocket in one rib cost a whole commute and a
permanent one cost every commute. Protected blocks and bedrock had the same problem.

`nav.ROUTE_AROUND` names the move failures that mean "not this way": peer, hazard,
protected, blocked. `nav.goTo` already stepped aside and re-planned around a peer and
now does so for all of them. A rib that meets one is simply shorter. The trunk steps over
or under the obstructed cell and advances the frontier past it, because a frontier that
disagrees with where the turtle is standing would send the next cycle back into the lava.
Vein following skips the blocked face rather than abandoning the other five.

The risk this creates is an endless commute to ground that cannot be dug, so it is paired
with a counter: cycles that mine nothing and move the frontier nowhere are counted, two
in a row hands the sector back, four parks the turtle with the reason. Removing the
counter without removing the tolerance would reintroduce a fleet that mines nothing all
night and looks busy doing it.

## D026 — Sector physical state belongs to the base

**Status:** accepted

`domain/mine/registry.lua` (then `domain/mine/registry.lua`) held leases and frontiers — progress.
Where a sector's shaft head
actually was, and whether it was open, lived only in the job file of whichever turtle
last visited. Lose the turtle and nobody knew there was a hundred-block drop at those
coordinates.

The registry now also records head Y, head offset along the trunk, and a
`sealed`/`open`/`blocked`/`unknown` state per sector. A claiming turtle is told what
another turtle already found, so it does not re-probe a column established to be under
water; the state is advisory and the descent still verifies the ground beneath it.

The important consequence is that **a sector with an open head is leased out first**,
ahead of both partly worked and untouched ground, and even when its tunnel is finished.
That is the entire patrol mechanism, and it is deliberately not a separate job: the
turtle caps the head on the way in as it would on any trip, finds nothing to mine, and
comes home. A new job type would have needed its own setup, preflight, fuel model, and
recovery — all of it duplicating a route that already exists and is already tested.

Anything a turtle is not certain it closed is reported `open`. A needless patrol trip
costs a commute; a missed one costs somebody falling down a shaft.

## D027 — The layering rule is a build check, not a convention

**Status:** accepted

[`docs/icos-2.md`](icos-2.md) says `domain/` may not reference a CC global. Every previous
architectural rule in this repository has been a sentence in a document, and every one of
them has been broken by somebody in a hurry who did not read it - `legacy/fleet/service.lua`
grew discovery, leases, policy, logging and persistence for exactly that reason.

`tools/check.ps1` now strips comments from `src/domain`, `src/ports`, and `src/ui` and
fails on a reference to `fs`, `term`, `turtle`, `rednet`, `gps`, `os`, or any other CC
global. Nothing else could enforce it: the type checker is happy with a CC global and
selene is happier still, because in every other folder they are correct.

There was one entry in the allow list. `domain/mine/registry.lua` read `os.epoch` and
persisted through `core/config`, because moving the file and changing how it gets its
clock and its storage are two different changes, and doing both at once would have
destroyed the only available evidence that a live fleet's sector bookkeeping came through
the move unaltered - that the existing specs passed untouched.

The allow list is the mechanism that keeps that debt visible. A rule with an exception
nobody can see is a rule that has already been abandoned.

**Paid in full by D041.** `now` is a required argument, reading and writing `.mine`
belongs to the caller, and ICOS 1's clock and file live in `legacy/mine/registry.lua`.
The allow list is empty, and D041 records why the intermediate step - an *optional* `now`
- was worse than either end of the change.

Making `now` *required* was the obvious finish and is the wrong trade. It would change
three live call sites - `legacy/fleet/coordinator.lua`, `legacy/console.lua`, `legacy/fleet/operations.lua`
- and the unmodified spec suite in one go: a refactor of the sector bookkeeping a running
fleet depends on, in exchange for deleting one line from a check. Those callers are being
replaced by `os/server/services/leases.lua` anyway, and the entry comes off when they go.

The general rule that produced this: **debt is paid where it is cheap, not where it is
visible.** An allow-list entry that everybody can see and nobody is tripping over is
costing less than the refactor that removes it would risk.

**A comparison is as much a use of the clock as a stamp is.** The first attempt threaded
`now` through the four functions that *write* a timestamp and stopped there, because those
were the ones that named `os.epoch`. The lease-expiry test failed on the next run: `held`
and `renew` measured age with `util.since`, which reads `os.epoch` directly, so a caller
holding a clock port and the registry were on two different clocks. Every lease the server
took looked fifteen minutes stale the instant it was written, and two turtles were handed
the same shaft - the exact failure D018 exists to prevent, reintroduced by a half-finished
injection.

Grepping for the global finds the writes and misses the reads, because the reads go through
a helper. The check that actually works is "which functions here depend on what time it
is", and that set includes every function that subtracts.

## D028 — A changed row is one blit, spanning first change to last

**Status:** accepted

The obvious cell diff finds every contiguous changed run in a row and emits one terminal
call each, skipping the identical stretches between them. That is the wrong trade on this
hardware, and getting it wrong is expensive in the direction that is hard to see: the
frame looks correct and the machine is slow.

A `term.blit` costs a `setCursorPos` and a call into the game. The characters inside it
cost a memcpy. Splitting a row into three runs to avoid rewriting eight unchanged
characters buys back eight bytes and pays four extra calls into the game for them.

`ui/render/buffer.lua` therefore emits one run per changed row, spanning its first changed cell
to its last. A one-character change is a one-character run. A row where only the two ends
moved rewrites the middle, and is still cheaper than the alternative. The property that
makes the budget provable falls out for free: a frame emits at most one call per row,
whatever changed - 81 for a full repaint of the largest monitor a person can build.

Two supporting choices should not be "simplified" either:

- **A row is three strings, not a table of cells.** `text`, `fg`, and `bg` are the exact
  three arguments `blit` takes, so comparison is a memcmp and painting a run is a splice,
  both in C. A grid of `{ char, fg, bg }` tables would move 13,284 comparisons per frame
  into interpreted Lua, and would need converting at present time besides. The cost is
  that `set` rewrites a whole row to change one cell; the 2x3 canvas must build a row and
  hand it over through `row`, not call `set` three hundred times.
- **A row is only examined if something wrote to it.** Not an optimisation of the diff -
  the diff still runs, and a row repainted with identical content still emits nothing -
  but an optimisation of the walk. It is what makes an idle screen cost 0.005ms rather
  than a comparison pass over every row on the monitor.

Measured numbers are in [`ui-framework.md`](ui-framework.md) section 12. Hold future
changes to the blit counts, which are properties of the algorithm, rather than to the
times, which were taken on a desktop interpreter rather than on Cobalt.

## D029 — Row spans, not dirty rectangles

**Status:** accepted

The usual way to do this is dirty rectangles: record a rectangle for each region that was
written, merge the overlapping ones, and blit each surviving rectangle. It is what
[Basalt 2](https://github.com/Pyroxenium/Basalt2) does, it is the obvious improvement to
propose over one-span-per-row, and it is slower here. `tools/compare.ps1` runs the same
dashboard workload through both and counts the calls.

Two reasons, and the second is the one that is easy to miss.

**Rectangles record writes; a row span records changes.** A rectangle is added because a
write happened. Whether the cells afterwards differ from what is on screen is never asked,
because there is no front buffer to ask. So a page that repaints itself with the same
content pays in full - 81 calls and 13,284 characters on a large monitor, against nothing
at all for the row diff. That is not a rectangle-versus-span difference so much as a
missing comparison, but the two travel together: keeping a front buffer to diff against is
what makes the row representation worth having, and vice versa.

**Rectangles lose even when the caller is careful.** In the case where only genuinely
changed cells are written - ten turtles reporting fuel and phase - rectangles produce 21
calls and row spans produce 11. Rectangles on different rows never overlap, so they never
merge, so one write is one call. A row span coalesces every change on a row into one,
which is the shape a table actually updates in.

Merging also has a sharp edge worth knowing about before reimplementing it. Growing two
overlapping rectangles to their bounding box pulls in everything between them, so two
small changes at opposite ends of a region become one large repaint; and a single-pass
merge that stops at the first overlap never re-tests the rectangle it just grew, so
overlapping rectangles survive into the emit and blit the same cells twice.

None of this makes rectangles a bad design in general. They win when changes are genuinely
two-dimensional and sparse - a dragged window, a sprite moving across a canvas. If the 2x3
canvas layer ever makes that the dominant pattern, revisit it there, for that layer, with
a measurement. Do not revisit it for the dashboard.

## D030 — A binding marks the node, never the root

**Status:** accepted

The retained-tree frameworks in this space invalidate upwards: a property changes, the
element tells its parent, the parent tells its parent, and the root frame repaints. Basalt
2 does exactly this in `BaseElement:updateRender`. It is the simplest thing that works and
it throws away the only information that matters.

`tools/compare.ps1` measures the difference on one heartbeat over a full 164x81 page — one
turtle changing fuel and phase, everything else unchanged:

    ICOS      1 blit    the node is marked, its subtree is painted
    upwards   81 blits  the root is marked, the whole tree is painted

The sharp part is that the information was already there. Basalt 2's property system knows
which property changed and carries a per-property render flag, and then discards that
precision at the last step. So this is not a cleverness the other design lacks; it is a
step it declines to take.

Three supporting rules, each of which is load-bearing and each of which was arrived at by
getting it wrong first:

- **Re-measure before deciding to re-solve.** Classifying `Text` as layout-affecting and
  stopping there re-solves and repaints on every heartbeat, which is the behaviour being
  replaced. "miner-3" becoming "miner-4" measures the same, so the frame degrades it to a
  paint. Without this the binding is precise and the frame throws the precision away one
  layer later.
- **Invalidation is not change.** A `Computed` that reads a whole device list is
  invalidated whenever any device reports, and usually formats to the string it already
  held. The binding compares the fresh value against the node's current one before
  marking anything, which is what turns forty invalidated cells into the eleven that
  moved.
- **A repaint takes the node's whole subtree.** Children paint over their parent, so a
  parent whose background changed has to redraw what sits on it. Being cleverer would mean
  tracking overlap, and the cell diff in `ui/render/buffer.lua` already makes painting an
  unchanged cell free.

The failure mode if this is ever "simplified" is not a crash. It is a dashboard that still
looks correct and quietly costs eighty times more, on the machine that is also reconciling
ten turtles. `tools/compare.ps1` is the standing check; if the gap closes, something here
was undone.

## D031 — A table is a fixed pool of slots over a changing list

**Status:** accepted

The obvious way to render a device list is to build a row per device and rebuild when the
list changes. That is React's model, and under a fine-grained binding graph it is the worst
of both: every rebuild makes every cell a new node, every new node is dirty, and the whole
table repaints on every heartbeat whether or not anything changed. It also churns the
binding graph, which is where the leaks live.

`ui/components/table.lua` builds `Capacity` row slots once and never again. Each cell is a
`Computed` that reads the list and indexes into it, so slot 3 shows whatever is third
*now*. A device leaving the roster does not destroy a row; it changes what four cells say.
Slots past the end render blank.

This is virtualisation arrived at from the other direction — a stable pool of widgets over
a changing list is the only shape that keeps a binding graph stable, and it happens to also
be the shape that scrolls.

Two consequences to keep:

- **Capacity is given, not measured.** Deriving it from the box needs the layout solved
  before the tree is built, which is backwards; and a table that silently grew its node
  count when a monitor got taller would be a memory leak with a plausible excuse.
- **A non-text column is a column.** The fuel meter goes through the same `Columns` list
  as the text, with a `Render` function instead of a `Key`. The first version had a
  separate trailing slot, so the heading row had one fewer column than the data rows and
  every heading sat two cells left of the values underneath it. One list, one set of
  widths, one loop for both.

## D032 — A monitor touch is a whole tap, and hover does not exist

**Status:** accepted

CC gives a computer terminal four pointer events - `mouse_click`, `mouse_up`, `mouse_drag`,
`mouse_scroll`. It gives a monitor exactly one, `monitor_touch`, with no release, no drag,
and no hover ever.

`ui/input.lua` therefore normalises a touch into a press **and** a release at the same
point, and nothing above it may assume that a release follows a press after some
interesting interval, or that a drag is possible, or that anything can be known about a
pointer that is not currently pressing.

This is not a rendering detail. The fleet dashboard exists for a wall monitor, and D020
already makes the input capability of a surface a safety boundary. A component whose
behaviour needs a hover, a press-and-hold, or a double-click simply does not work on the
one surface the whole UI was built for - and it fails silently there while working
perfectly on the developer's computer terminal, which is the worst possible way for it to
fail.

So: long-press is omitted deliberately rather than by oversight, and there is no hover
event to bind. The event model is the enforcement; a rule that relied on discipline would
be broken by the first component somebody wrote at a keyboard.

The other half of the same decision is that every screen has to be operable from a
keyboard alone, because a turtle has no mouse at all. Tab moves the focus ring, enter and
space activate what holds it, and that path is exercised in the spec suite rather than
assumed.

## D033 — Scrolling is an offset into a fixed slot pool

**Status:** accepted

The obvious implementations are to build one row per item and move them, or to lay out
everything and clip to a viewport. Both fight the framework.

Moving rows is a relayout on every scroll tick, which repaints the screen. Clipping needs
a clip region in the cell buffer, which every component then has to respect, and it lays
out rows that are not visible so the cost scales with the list rather than the screen.

D031 already made a table a fixed pool of slots over a changing list. Scrolling is then
one more term in the same expression: slot `i` shows `list[i + offset]`. Moving the offset
changes what each cell computes to, the bindings turn that into one repaint per cell that
actually differs, and **the layout does not move at all**. A table can never scroll into a
state where its layout is wrong, because its layout never changes.

Two things follow, and both are the table's job rather than every screen's:

- It clamps its own scroll against the list length. A screen that had to do this would get
  it slightly wrong in a different way each time.
- A click reports the **row**, not the slot. Under an offset those are different things,
  and a screen cares which device was pressed, not which widget it happened to be in.

There is still no clip region in `ui/render/buffer.lua`. `ScrollView`, `Modal` and `Tabs` will
need one and should get it deliberately, with its own decision, rather than by somebody
adding a bounds check to `write` and discovering later that half the components ignore it.

## D034 — A spring is integrated in sub-steps, and a settled one unschedules itself

**Status:** accepted

Two rules, both about the same thing: an animation must never be able to keep a machine
awake.

**Sub-stepping is a stability limit, not a quality setting.** A frame here is 50ms, which
is enormous for a spring. At the speed section 8 of `ui-framework.md` gives as its worked
example - `Spring(goal, 25, 1)` - the term `speed² · dt²` comes to 1.56. Above 1 a
semi-implicit Euler integrator gains energy every step rather than losing it, so the value
oscillates wider and wider instead of settling. The first version of `ui/state/anim.lua` did
exactly this and reached six figures within six frames.

The consequence is worse than a visual glitch. A spring that never settles is never
removed from the driver; a driver that is never empty tells the host loop to keep waking
on a timer; and the loop then spins at 20 FPS forever on the base station that is also
running the fleet service. A runaway animation becomes a machine that never idles.

`anim.MAX_STEP` splits each frame into slices of at most 1/60s, which puts the same spring
at 0.17 and leaves headroom to about speed 50. Three sub-steps of arithmetic on four
numbers costs nothing. Removing it would reintroduce a stability limit that nobody
discovers until they pick a speed slightly too high.

**A settled animation removes itself, and an idle screen allocates no driver at all.**
Section 8 calls this a hard requirement rather than an optimisation, and it is enforced in
two places: the driver drops an animation when it settles, and `Root:animating()` answers
false without a driver existing when the scope never made one. The host loop asks before
every pull, so a screen with nothing moving blocks on the next event and costs zero.

The failure this prevents is quiet. An animation system that ticks unconditionally looks
free in a test - nothing is slow, nothing errors - and shows up in production as a base
station that competes for the 5ms scheduling slice with the fleet service beside it, which
is exactly the budget D027's section 2 note establishes.

Two smaller rules travel with these and are the same idea in miniature:

- **Both a spring and a tween land exactly on their goal.** A spring assigns its goal when
  it settles; a tween needs a tolerance, because accumulated floating point never sums to
  a round number and six 50ms steps come to 0.24999999999999997. A `Width` left a whisker
  under 24 renders as 23 cells forever, and the bug reads as an off-by-one in the layout
  solver rather than as an animation that did not quite arrive.
- **A long pause resumes rather than teleports.** A chunk unloads or the server hitches and
  the next frame is four seconds later; integrating that whole gap snaps every animation
  straight to its goal, which looks like the animation never happened. The delta is clamped
  to 100ms - two ticks.

## D035 — A structural property forces a re-solve; a content property is re-measured

**Status:** accepted

D030 established that a binding marks the node and that a size-affecting change
re-measures, promoting to a full re-solve only when the measurement actually moved. That
optimisation is what makes a heartbeat cost one blit, and it is wrong for half the
properties it was originally applied to.

`Justify` going from `start` to `end` does not change a node's size by one cell. Neither
does `Align`. Neither does `Scroll`. Sending those through measure-and-compare finds
nothing changed, skips the re-solve, and leaves the screen showing the old arrangement
while the property reports the new value.

That was a real bug and it was invisible in the way this kind of bug is: a `ScrollView`
held the right offset, re-measured to the same size, concluded nothing needed moving, and
rendered the top of the list forever. Nothing errored, nothing looked stale, and the state
was correct everywhere it was inspected.

So the two paths are separated by what the property *is*, not by what it might do:

- **Structural** - `Width`, `Height`, `Grow`, `Gap`, `Padding`, `Direction`, `Align`,
  `Justify`, `Children`, `Scroll`, `Absolute` - forces a re-solve outright. These are rare
  and a re-solve is cheap; the cell diff still makes the parts that did not move free.
- **Content** - whatever a component declares in `definition.layout`, such as `Text` -
  re-measures and promotes only if the size changed. This is the hot path, it fires on
  every heartbeat, and it is the one the optimisation exists for.

The test for adding a property to the structural list is not "can it change the size" but
"can it change where anything ends up". `Scroll` cannot change any size at all, and it is
the clearest member of the set.

## D036 — A 2×3 cell keeps its two dominant colours and reduces through the active palette

**Status:** accepted

ComputerCraft's semigraphic glyph has six pixels but only a foreground and background.
That is exact for two colours and under-specified for three. Intersecting primitives make
three-colour cells unavoidable even when every sprite is authored carefully, so rejecting
them would turn an ordinary overlap into a runtime error and choosing arbitrarily would
make the image change when iteration order changed.

`ui/render/canvas.lua` counts colours in each 2×3 cell, keeps the two most frequent, and maps each
discarded colour to the nearer survivor in the active palette's RGB values. Equal counts
use first appearance in row-major order; equal distances choose the dominant colour. The
same pixels and palette therefore always produce the same character. Without palette data,
discarded colours conservatively become the dominant one.

The active palette is load-bearing. Basalt's pixelbox plugin demonstrates the same local
reduction with a fixed distance table over ComputerCraft's default colour constants. ICOS
redefines all sixteen slots for dark and light themes, so those distances would describe
colours that are no longer on screen. A hosted Canvas inherits `root.palette`; a standalone
canvas may receive one explicitly.

The sixth pixel becomes the background and each of the first five pixels unlike it sets a
glyph bit. That foreground/background swap is how bytes 128–159 represent all 64 binary
patterns, and it is covered directly by the canvas specs.

There is deliberately no second dirty-rectangle renderer for imagery yet. Canvas encodes
one whole buffer run per character row, after which the existing cell diff emits only the
changed span. D029 already names the threshold for revisiting this: measure first, and add a
canvas-specific rectangle path only if moving sprites make two-dimensional sparse changes
the dominant workload.

## D037 — The canvas fast path allocates nothing per cell and retains its pixel rows

**Status:** accepted

The first correct phase 5 implementation rebuilt every pixel row and allocated a six-entry
pixel table, colour-count map, and sortable list for every terminal cell. On an 8×6 monitor
at scale 0.5 that is 79,704 subpixels and 13,284 cells. The full-canvas benchmark took
26.42ms per frame on desktop Lua — technically inside a 50ms tick, but with no credible
headroom for Cobalt or the fleet service sharing the machine.

Two observations remove work without changing the drawing contract:

- Nearly every cell in authored art has one or two colours, because two is the hardware
  limit. That path detects its colours in locals and encodes directly. Only a genuinely
  crowded cell allocates frequency data and performs D036's palette-aware reduction.
- A retained Canvas always starts a repaint clear, but its row tables do not have to be
  new. `components/graphics.lua` keeps the pixel surface on the node and `Canvas:clear`
  overwrites those rows. Resizing replaces it; ordinary animation does not make tens of
  thousands of tables for the garbage collector.

Together they reduce the same workload to 4.46ms while preserving the 81-blit result. This
is why `tools/bench.lua` now includes `full canvas repaint`: removing either optimisation
is easy, remains functionally correct, passes every picture spec, and would otherwise lose
the performance property silently.

**What the number still does not buy.** 4.46ms clears the stated 50ms frame budget, and it
uses 89% of the 5ms slice a computer actually gets when it shares a thread with ten turtles
(section 2 of `ui-framework.md`). Applying the same 10x Cobalt margin used everywhere else
puts a full-wall canvas at roughly 45ms - inside a tick, and nine slices deep.

So the optimisation changed what is possible, not what is advisable. A monitor wall of
pixels is something to draw once, not something to animate beside a running fleet. The
working figure is about **0.3us per terminal cell**, which after the Cobalt margin affords
roughly **1,700 cells per frame** in a slice: a full computer terminal, or a third of a
wall. That is the quantitative form of "canvas is for content, never for chrome", and it
is the number to check before putting an animated canvas on a monitor.
## D014 — Version changes happen at merge

**Status:** accepted

`src/core/version.lua` is the single installed version. The GitHub workflow serializes
merges and applies semantic version labels, avoiding conflicting manual bumps across
parallel feature branches.

## D018 — Fleet networking is a boot service, not a page

**Status:** accepted

Discovery, claim handling, and lease renewal used to live inside `legacy/apps/fleet.lua`.
Closing one dashboard silently disabled the fleet's coordination. `legacy/fleet/service.lua`
now starts beside the UI and is the sole base-side receiver. Apps read persisted state
and issue commands; their lifecycle no longer controls the fleet's lifecycle.

## D019 — A handheld is a controller, never a second base

**Status:** accepted

Pocket Computers need the full control surface but must not compete for Rednet hostname
`base` or lease sectors from a private copy of `.mine`. Role `controller` therefore
uses a touch-first shell, mirrors roster/policy/log state, and sends validated mine and
quarry operations to the stationary authority. Direct turtle commands remain
best-effort, while authoritative mutations receive request-correlated results.

## D020 — Input capability belongs to the UI surface

**Status:** accepted

An attached monitor and the base computer are outputs of the same machine but have
different input capabilities: the computer terminal receives keyboard events, while
an Advanced Monitor only reports touch coordinates. Promoting the monitor to the only
desktop therefore stranded keyboard prompts and reduced the physical computer to a
special-purpose console.

The base now runs a full desktop on its local terminal and a separate display-only
desktop on the monitor. App definitions declare `requiresInput`; monitor filtering is
deny-by-default, with explicit read-only Fleet Status and Fleet Log variants. Display
pages may accept harmless paging touches but cannot send commands or mutate settings.

## D021 — Common mining starts from intent, not grid internals

**Status:** accepted

Sector size, ring count, keepout, job selection, target depth, and deployment are
useful expert controls but poor prerequisites for the fleet's most common request:
mine diamonds. Mine Control therefore exposes one guided action that atomically
creates a safe default grid when needed, assigns Rare at Y -59 to connected parked
miners, and queues deployment. Existing mine geometry is never silently replaced;
the detailed controls remain available and are explicitly labelled advanced.

## D022 — GPS hosts are appliances, not fleet bases

**Status:** accepted

A GPS constellation needs four permanently running coordinate beacons, but those
machines do not need a desktop, roster, miner runtime, or fleet hostname. ICOS exposes
a dedicated `gps` role on stationary modem-equipped computers and turtles. Setup saves
the host block coordinates once and startup runs only the beacon, while preserving the
normal updater and held-key recovery path. This also lets a Chunky + Ender Turtle serve
as one host and keep the other three hosts' shared chunk loaded.

## D038 — The four roles are form factors, not jobs

**Status:** accepted

`server`, `client`, `mobile` are all about what a machine *is*. `miner` was about what one
*does*, and it was the odd one out - noticed only when the fleet was about to gain farming
turtles.

A mining turtle and a farming turtle are the same machine running different code: the same
heartbeat, the same recall, the same fuel and depot and dead-reckoning problems, everything
except which file drives the arms. `os/miner/` would have become `os/farmer/` differing by
one `require`, and `os/builder/` after that - three operating systems for one machine.

So the role is `turtle`, `os/miner/` is `os/turtle/`, and nothing in it knows what the
turtle is for: `context.runJob` is whatever the node selected at setup. What a turtle does
is a **job**, changeable from the base without reinstalling anything. What it is is a
turtle.

`miner` maps to `turtle` in `FROM_ROLE`, so every existing turtle migrates by renaming its
role and leaving its job alone - the record already carries the job it was running, because
mining was always the job.

**The general rule:** a role that names an activity is a role that will need a sibling.
Roles answer "what hardware is this?", and everything else is configuration.

## D039 — One architecture in the tree, and a quarantine for the other

**Status:** accepted

The source tree had grown two complete operating systems interleaved. `src/mine/` sat
beside `src/domain/mine/`; `src/miner/` beside `src/os/turtle/`; `src/fleet/` beside
`src/domain/fleet/`; one directory held both `apps/devices.lua` and `apps/devices/`. Every
pair was ICOS 2 next to the ICOS 1 thing it replaces, and **nothing in a path said which one
was live.**

That, not flatness, was why the tree read as disorganised. The directories that looked
wrong - `turtle`, `miner`, `mine`, `jobs`, `fleet` - were precisely the ICOS 1 half.

So ICOS 1 moved wholesale into `legacy/`, and the rest was deepened into folders that name
what they hold: `os/kernel/` for the parts of `os/` that are not one of the four operating
systems, `ui/core/` and `ui/draw/` under the framework, `jobs/mining/` so that
`jobs/farming/` has an obvious home, `device/` for a turtle's own hardware.

**`core/` was deleted as a concept.** It was thirteen of fourteen files touching CC globals
- a runtime, not a core - and the name attracted anything that did not obviously belong
elsewhere, which is how a folder becomes a landfill. Its contents went where they actually
belonged: `util` and `version` to `lib/`, `config` and `log` to `adapters/cc/` (both are CC
I/O wearing a friendly name), the shell and net and device detection to `legacy/`.

`lib/` is now checked for CC globals alongside `domain/`, `ports/` and `ui/`. That is the
mechanism that stops it becoming the next `core/`, and it bit immediately: `util.since`
reads `os.epoch`.

**The first fix for that was dishonest and selene caught it.** `_G["os"].epoch` passes a
grep for `os.` while being exactly the dependency the grep exists to find. A check that
makes CC dependencies visible is not served by an indirection that hides one, so
`lib/util.lua` is now the second entry in the allow list - which is what the allow list is
for. Debt is declared, not disguised.

`util.since` did gain an optional `now`, so a caller with a clock port gets a pure function.
That is the same half-fix as `domain/mine/registry.lua` and for the same reason.

**Superseded on both counts by D041**, which finished the job: `now` is required rather
than optional, the CC clock and the `.mine` file moved into `legacy/`, and the allow list
is empty.

**The general rule:** a directory name should answer "which way does this point?" - what it
knows and what knows it. `core`, `common`, `shared` and `utils` answer nothing, so they
accumulate. If a file needs to know two layers at once it is a composition root and belongs
in `os/`; if it needs to know none, it belongs in `domain/`.

**And a second question the first pass missed: who runs it?** `jobs/` and `device/` were
left at the top level, and both are turtle-only. The dependency graph says so plainly -
nothing on the base requires a job module, because the base reads `domain/turtle/jobs.lua`,
the catalogue, and `module` is a string precisely so a server with no `turtle` global can
list jobs it cannot run. `device/` is required only by jobs, `legacy/miner/` and
`legacy/apps/`.

Moving both under `os/turtle/` makes `os/` symmetric: a server is `main.lua` plus
`services/`, its long-running work; a turtle is `main.lua` plus `jobs/`, its work, and
`device/`, its hardware. Adding a farming job becomes `os/turtle/jobs/farming/` plus one
catalogue entry, which is the shape D038 was aiming at.

## D040 — One protocol name, one version field, and a rule that lets both sides be wrong

**Status:** accepted

§13 of the ICOS 2 plan promised that *"protocol messages gain a version field in phase 1"*
so a device on an old build keeps working against a new server. It was never written. In
its place the protocol *name* was inlined in seven files — `os/server/services/discovery`,
`reconcile`, `leases`, `os/turtle/main`, `os/turtle/agent`, `os/client/main`,
`apps/devices/app` — each with its own copy of the literal `"icos"`, under a comment in
`discovery.lua` explaining why that must never happen: a typo there is *a failure mode
with no error message*, because both sides work perfectly and never hear each other.

`domain/protocol/message.lua` holds the name once and adds the version field. The rule
that makes the field useful is one sentence:

> **A version bump may add fields and add kinds. It may never change what an existing
> field means.** A change that cannot obey that gets a new `kind`, not a new version.

That is what lets `accept` take a message from the future. The updater upgrades machines
one at a time, so a device running ahead of the machine reading its message is the normal
case during a rollout, not the exception — and refusing anything newer than ourselves
would strand precisely the devices that upgraded first. So `NEWER` is classified and
accepted; every field the reader knows still means what it meant, and the rest is ignored.

**Absent means version 1, not version 0.** The builds that shipped before this file
existed are real and are on the fleet. Their messages are valid version 1, so the missing
field is a default rather than a fault.

Only two things are refused: a message that is not a table, and one claiming a version
below one — which no build ever sent, so it is corruption or somebody else's traffic on
our protocol name. An unknown `kind` is deliberately *not* refused here, because
`discovery.handle` already returns nil for a message that is not its own and duplicating
the list of valid kinds would put it in two files.

The gate sits in `discovery.dispatch` rather than in each handler, and replies are stamped
there on the way out rather than at each `return`. A handler that has to remember is a
handler that can forget, and a reply that forgot its stamp does not look broken — it looks
like a pre-versioning build, which is a wrong answer wearing a right one's clothes.

Every heartbeat also carries the sender's build string, not just its protocol version.
`build` rides on every message rather than only on `hello`, because a device already known
never sends another hello — so a build carried only there would be whatever that device was
running when the server last rebooted, which is stale at exactly the moment a rollout makes
"which devices are still on the old build" the question being asked.

## D041 — A defaulted clock is a second clock nobody declared

**Status:** accepted

`domain/mine/registry.lua` and `lib/util.lua` were the two entries in the layering check's
allow list. Both were there for the same reason and both are now empty.

The registry was moved into `domain/` without being de-globalised, deliberately: doing both
at once would have destroyed the only evidence that a live fleet's sector bookkeeping
survived the move, which was that the specs passed untouched (D027). The half-fix that
followed gave every function that *stamped* a time an optional `now`, defaulting to
`os.epoch`.

**The optional default is what caused the bug it was supposed to avoid.** `util.since`,
which every *comparison* went through, kept reading `os.epoch` while callers holding a
clock port stamped from theirs. Every lease the leases service took looked fifteen minutes
stale the instant it was written, and two turtles were handed the same shaft. A comparison
is as much a use of the clock as a stamp is, and an optional `now` is how a second clock
gets into a system without anybody declaring one.

So `now` is required, in both files. The mismatch that used to be a lease which quietly
never expired is now a nil arithmetic error at the call site.

ICOS 1 has no clock port and no storage port and will never get one — it is being replaced,
not upgraded. `legacy/mine/registry.lua` is where its CC clock and its `.mine` file went:
a facade that adds one argument in one place and re-exports every name explicitly rather
than forwarding through `__index`, so "what does ICOS 1 still use the mine registry for"
is answerable by reading the file. `legacy/fleet/roster.lua` names the clock at its one
call site for the same reason.

**The allow list is now empty, and keeping it empty is the point.** An entry in it is a
declaration that a pure folder is not pure; it needs a header comment in the file saying
what empties it again, and it is a debt with a due date rather than an exemption.

## D042 — The dual run was on the wrong protocol, and a bridge is not optional

**Status:** accepted

§12 of the ICOS 2 plan names phase 3 the high-risk one, because it replaces recall — a
safety control — while turtles are underground. Its stated mitigation is a dual run: the
desired-state reply and the old ICOS 1 command go out together *"until every device
converges, then events go"*. `reconcile` duly sends both.

**It sends both on `icos`.** ICOS 1 talks `ccfleet`. So the old-shaped command reached only
devices that already spoke the new protocol, and the mitigation for the riskiest phase in
the plan protected nobody.

The consequence was not subtle. Every turtle in the live fleet is an ICOS 1 miner (§13:
*"the migration that actually runs on ten machines"*), so the moment `startup.lua` booted
`os/server/main.lua` the whole fleet would have gone silent to its own base:

- no heartbeats received, so an empty registry, so an empty Devices page and no recall —
  §1's first two failures reappearing, caused by the change written to fix them;
- no sector leases, because a mine request is a `ccfleet` message like any other, so
  turtles would also have lost the ability to ask where to dig;
- nothing addressed at all, because no ICOS 2 service hosted the rednet name `base` that
  an ICOS 1 Pocket controller resolves for every authoritative request.

`os/server/services/bridge.lua` is the translator: a second inbox on the old protocol.
Receiving consumes, so one loop per protocol is the rule — but two loops on two protocols
do not eat each other's traffic, so this is a second ear rather than a second reader of the
first one.

**It is a bridge, not a second implementation.** `registry.observe` records the heartbeat,
`desired` decides the goal, `leases.handle` answers the mine request, and `reconcile.legacy`
translates the goal — every decision is made by the code the ICOS 2 path already uses. This
file changes an envelope and a protocol name and nothing else, because a rule that lived
there would be a rule that applied to half the fleet.

**A legacy device converges on its `command_result`, not on a generation.** ICOS 1 has no
notion of an applied generation, so such a device reports nothing `desired.converged` can
read and would be commanded forever. Its acknowledgement carries the same information by
another route. The generation credited is the one that was *sent*, not the one currently
wanted, so an order set while an acknowledgement was in flight stays pending rather than
being marked applied by a reply to its predecessor. Marking it converged when the command
went out would have been the "sent" status §5 exists to abolish.

**A goal with no ICOS 1 equivalent is not faked.** `park` has no old command; nothing is
sent and nothing is recorded as sent, so the device stays honestly pending.

`transport` gained a `host` method for this, and it is the general lesson: the port had no
way to express "be findable under a name", so nothing could notice that the new server was
never going to be addressable. A capability absent from a port is a capability nobody can
discover is missing.

## D043 — One file holds the turtle's dependency on ICOS 1, and it is a seam not a habit

**Status:** accepted

`os/turtle/main.lua` declares `runJob` and `runControls` as seams and defaults them to a
function that does nothing and a launcher. So an ICOS 2 turtle booted today heartbeats,
obeys recall, and **never mines** — which from the base looks identical to a turtle that is
working. That is the worst failure mode this project has: something that reports health it
does not have.

`os/turtle/engine.lua` fills them, by building ICOS 1's `Context` and handing back
`runtime.agent` and `runtime.localControls`. `legacy/miner/runtime.lua` is 326 lines
deciding when a turtle parks, deploys, updates, changes job and starts its next cycle, and
every one of those decisions is load-bearing on a machine that is underground with an open
shaft behind it. Rewriting it in the same change that gives ICOS 2 its first working turtle
would put two untested halves in one hole.

**Two of ICOS 1's four loops are taken, not four.** The heartbeat and the command receiver
are ICOS 2's own, on ICOS 2's protocol, under desired state — so a turtle running this
engine is *not* an ICOS 1 device and `bridge` does not see it as one. That works only
because `ctx:report` draws locally and sends nothing; if it broadcast, the same machine
would appear twice on two protocols.

It is wired from `boot.WIRING`, a table keyed by role beside `boot.ROOTS`, because a branch
there would be `os/kernel/boot.lua` growing an opinion about mining — which its own header
forbids. The entry declares `when = "runJob"`: the seam whose absence means "this machine
has no engine". Declared rather than discovered, because *building* the engine constructs
an ICOS 1 context that reads `turtle` and paints a screen, and a caller that brought its own
must not pay for one — finding that out by calling it would be finding out too late.

**Deleting it** is the last step of the turtle migration: when a job runner exists that
takes ports instead of globals, this file, `legacy/miner/` and `legacy/apps/miner.lua` go
together. Keeping the dependency in exactly one file is what makes "what is left to port"
a question with an answer you can read.

**A bug this found.** `domain/turtle/jobs.lua` said `module = "jobs.quarry"` for all five
jobs — paths that moved in D039 and had been wrong ever since, because nothing resolved
them and the only check asserted the field was *a string*, which a wrong path satisfies
perfectly. A string that names a module is not tested by looking at it. `os_spec` now
requires every entry, and the layering check learned to strip string literals so that a
module path beginning `os.` is not read as a use of the CC global `os`.

## D044 — The turtle's decisions are data before they are a rewrite

**Status:** accepted

§14 puts the turtle runtime first in the retirement order because it is the piece most
likely to need a second attempt. `legacy/miner/runtime.lua` decides when a turtle parks,
which pending order it services, and what each key on its case does — and **not one of
those decisions had a test**, because all of them live inside a `while true` that also
draws a screen, writes a file, plays a sound and sleeps.

So they came out first, into `domain/turtle/lifecycle.lua`, before anything was rewritten
around them. Nothing there does anything: `after` says what should happen, `pending` says
what to service, `keypress` says what a key means, and the caller performs all three. That
is the shape every service on the server already has, for the reason `discovery.lua` gives
— anything worth testing that lives inside a loop is something that cannot be tested.

ICOS 1 was rewired through it in the same change rather than left alone, which is the D027
discipline applied twice: the extraction is only proven mechanical if the existing caller
uses the extracted version. **The honest caveat is that `runtime.agent` and `runtime.park`
have no spec coverage of their own**, so that proof is weaker here than it was for the mine
registry — the sixteen new specs cover the decisions, and review covers the wiring.

Three invariants are now assertions rather than the shape of a branch:

- **Recall outranks every other outcome**, including a job that failed in the same cycle.
  A turtle told to come home must not report as broken instead.
- **A fuel stop is not a failure.** A turtle that came home because its return reserve said
  so did the right thing, and reporting it as an error trains somebody to ignore errors.
- **Deploy is serviced last.** Servicing it before a pending job change would deploy the
  turtle on the job it had before — the three-message race §5 exists to collapse.

The keypress table carries the same idea further: a running turtle has no `deploy` and a
parked one has no `recall`, **not** because a guard rejects them but because they are not
in the table. A rule enforced by absence cannot be got wrong by somebody adding a key.

Keys are names, not CC keycodes. `keys.d` is a number that exists only on a machine with
the CC globals loaded, and what `d` does is a rule rather than an I/O concern; the runtime
translates once, at the edge.

## D045 — `x and nil or y` is not a guard, and D020 was open because of it

**Status:** accepted

Three apps wrote their display-only boundary as:

```lua
onDeploy = options.readOnly and nil or function(device) ... end
```

It reads as "no callback when read-only". **It always passes the callback.** `and` yields
`nil`, and `nil or fn` is `fn` — so the guard evaluated to the function in both branches,
in nine places, since each app was written.

D020 calls that boundary a safety property: an Advanced Monitor reports touch coordinates,
and a display-only surface must not be able to send commands. The Devices app's own header
claimed "there is no code path that could put a Deploy button on it". There was, and it was
the one that said it could not.

The fix is not a cleverer expression. Every one of them is now a block:

```lua
if not options.readOnly then
  page.onDeploy = function(device) ... end
end
```

There is nothing to get subtly right, which is the property worth having in a guard that
nothing was checking.

## D046 — Coverage is a claim on ground, not an assignment of turtles

**Status:** accepted

A turtle outside a loaded chunk is not disobeying an order, it is **not executing**. §5's
desired state fixed the delivery of orders and cannot fix that, so an unattended fleet has
to carry its loaded region with it. Chunk-loading turtles — *generals* — are how, and the
question is what the base allocates.

The obvious model is to assign miners to generals: two generals, twenty miners, ten each.
It is wrong in three ways. Miners move between work whenever they are re-leased, so the
binding needs constant maintenance; the thing that actually has to be loaded is *where the
work is*, not *who is doing it*; and a headcount ratio has no opinion about whether the
ground in question is reachable.

So coverage is a second claim table beside sector leases. **A general claims a chunk; work
is only handed out on ground somebody is holding.** The ratio stops being a rule and
becomes a consequence — the fleet works as much ground as it can keep loaded and no more.

Three things fall out of that, and each was got wrong once first.

**The rule is disjoint footprints, not one turtle per chunk.** The Chunky Turtle holds the
chunk it stands in, so at radius 0 the two are identical. They are not identical for every
loader: under a radius-1 loader, two generals one chunk apart sit in different chunks,
satisfy "never two in one chunk", and overlap on six of their nine. `grid.RADIUS` exists so
that changing the mod changes a number rather than revealing an assumption.

**An expired claim is not reassigned.** This is where a chunk claim and a sector lease
differ. A stale sector handed to somebody else costs a few seconds of two turtles in one
shaft. A stale *chunk* handed to a second general puts two loaders in one chunk — which is
precisely the waste the whole feature exists to prevent, and it looks like working
coverage. So staleness stops a chunk counting as coverage and does not free it; only an
operator, or a general physically reporting from that chunk, does. Presence beats a record;
absence does not.

**Coverage that is not joined to the base is not coverage.** A miner flies home across
every chunk between its work and the depot, so an island of loaded ground is worse than
none: it looks like somewhere to work and strands whoever is sent there. The region is
therefore grown one adjacent chunk at a time from the base chunk, which makes it connected
by construction rather than by inspection, and an island is reported as an island.

The last piece is that slices belong to the chunk rather than to the headcount.
`quarry` already splits an area by `workerIndex` of `workerCount` and its defaults are
already a 16×16 area — a chunk — so a chunk quarry needed no new turtle code at all. But
deriving `workerCount` from however many miners are currently assigned would re-cut the
area under every other turtle in that chunk whenever one ran out of fuel. The divisor is
fixed at `PER_CHUNK`; an absent miner leaves an unworked slice, and the next free turtle
takes exactly that slice.

**The first spec written for it passed vacuously**, and that is the more useful half of
this entry. It asserted on the return of `mount` — which is a *node tree*, not the options
table — so `page.onDeploy` was nil whatever the app did, and the test went green against
the bug it existed to catch. The spec now captures what the app hands its view, and it was
confirmed to fail when the guard is removed. **A test for a boundary is worth nothing until
it has been seen to fail.**

Lua's `and`/`or` idiom is safe only when the middle value cannot be false or nil. It is
banned here for optional callbacks, optional tables, and anything else whose absence is the
point — which is most of the places somebody reaches for it.
