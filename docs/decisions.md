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

The world is now divided once into square sectors around the base (`mine/plan.lua`).
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
It is held at the base (`mine/registry.lua`) and cached on the turtle (`mine/site.lua`), and
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
through, and replaces it from above. `turtle/access.lua` owns the mechanics — block
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

`tools/spec/` is a sparse block world with the CC: Tweaked turtle, fs, and peripheral
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

`mine/registry.lua` held leases and frontiers — progress. Where a sector's shaft head
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

## D014 — Version changes happen at merge

**Status:** accepted

`src/core/version.lua` is the single installed version. The GitHub workflow serializes
merges and applies semantic version labels, avoiding conflicting manual bumps across
parallel feature branches.

## D018 — Fleet networking is a boot service, not a page

**Status:** accepted

Discovery, claim handling, and lease renewal used to live inside `apps/fleet.lua`.
Closing one dashboard silently disabled the fleet's coordination. `fleet/service.lua`
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
