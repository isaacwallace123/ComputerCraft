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

## D014 — Version changes happen at merge

**Status:** accepted

`src/core/version.lua` is the single installed version. The GitHub workflow serializes
merges and applies semantic version labels, avoiding conflicting manual bumps across
parallel feature branches.
