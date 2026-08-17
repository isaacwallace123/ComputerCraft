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
