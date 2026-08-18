# Architecture

## System shape

ICOS is one codebase installed onto several CC: Tweaked devices. A base computer owns
the desktop and fleet roster. Mining turtles own their movement state and jobs. Rednet
connects them, but mining never depends on a live connection.

```text
GitHub repository
  └─ bootstrap.lua → update.lua → src/manifest.json
                                  └─ installed device filesystem

Base computer            Pocket controller             Mining turtle
  startup.lua              startup.lua                    startup.lua
  always-on service        handheld shell                 miner runtime
  local full desktop       synced roster/policy  Rednet   navigation + fuel
  display-only monitor
  authoritative state  ↔  Fleet/Devices/Mine Control ↔  local job safety
```

## Dependency direction

The intended dependency flow is:

```text
apps → miner / fleet / jobs → turtle / mine → core
```

- `core/` contains platform services: configuration, UI, display, logging, networking,
  sound, boot, and app metadata.
- `mine/` contains the shared worksite. Sector geometry (`plan.lua`, pure arithmetic) and
  the base-side lease and frontier store (`registry.lua`) have moved to `domain/mine/`,
  leaving aliases behind; the turtle-side cache and claim client (`site.lua`) is still
  here. It sits beside `turtle/` because both sides import it.
- `turtle/` contains hardware primitives and should not know about a particular job.
  `turtle/access.lua` is the surface-access primitive: block classification, cap
  material selection, and verified placement. It knows what a safe cap is, never when
  to move one — that decision belongs to the job running the route.
- `jobs/` contains mining behavior and accepts callbacks rather than drawing UI or
  receiving network messages.
- `miner/` owns the long-running turtle state machine, telemetry, and command handling.
- `fleet/` owns shared base-side roster and coordination logic.
- `apps/` contains thin executable entrypoints, control pages, and display-only views.

Avoid dependencies in the opposite direction. In particular, a turtle primitive
should not import an app, and a job should not manipulate the desktop.

### The ICOS 2 layers, being built alongside

Four folders exist that nothing in the running fleet uses yet. They are the foundation of
[`docs/icos-2.md`](icos-2.md) and [`docs/ui-framework.md`](ui-framework.md), landed first
so that everything after them is testable:

```text
domain/   pure logic. May not reference a CC global; the check enforces it.
ports/    interface definitions - a method list, a check, a null implementation.
adapters/ cc/   real implementations over fs, rednet, term, turtle, gps
          sim/  the simulated world, and a recording screen
ui/       the cell buffer and its diff
```

`domain/mine/` holds `plan.lua` and `registry.lua`, moved from `mine/` without logic
changes; `mine/plan.lua` and `mine/registry.lua` remain as aliases until the specs are
rewritten. `mine/site.lua` has not moved, because it is the turtle-side cache and talks to
the network.

Nothing is wired. No composition root constructs an adapter, and every device boots
through exactly the paths described above. That is deliberate: phase 1 changes no
behaviour at all, which is what makes the unchanged spec suite meaningful.

## Boot flow

`src/startup.lua` is the installed entrypoint:

1. Load `.node` and detect device capabilities.
2. Detect the local terminal and the largest attached computer monitor.
3. Show a splash. Holding a key opens recovery/system tools.
4. If enabled, run the automatic updater.
5. Load the app registry after updating so fresh app definitions are used immediately.
6. On a turtle, auto-run the only valid launcher app or show the compact launcher.
7. On a Pocket Computer, start the touch-first handheld shell. On other computers,
   start the full page-based desktop on the local keyboard terminal. If a monitor is
   attached, run a second display-only desktop there in parallel.
8. For `fleet` and `controller` roles, run networking beside the UI. Closing an app
   never stops discovery, sector leasing, telemetry, or controller synchronization.
   Startup supervises and restarts that service if an unexpected runtime error escapes.

`src/install.lua` assigns the device role and label. Capability filtering in
`src/core/apps.lua` decides which apps and tools are valid for the hardware, role, and
output surface. Every app declares `requiresInput`; unknown apps default to requiring
input, so a new control page cannot leak onto a monitor accidentally.

The `gps` role is a deliberately smaller appliance path. On a stationary computer or
turtle with a wireless/Ender modem, startup runs only `apps/gps_host.lua` with the
coordinates saved in `.gps`. It does not start a desktop, fleet service, miner, or
Rednet hostname. A held key during boot still reaches update and role recovery tools.

## Desktop model

`src/core/desktop.lua` implements maximized pages rather than nested windows:

- Home is permanent and owns the ICOS title bar.
- Each app gets its own terminal window and owns row 1 while focused.
- The bottom taskbar is global chrome.
- Keyboard and pointer events go only to the focused app.
- Timers, Rednet, resize, and ICOS events are broadcast to all app coroutines.
- `icos_open_app` opens or focuses a page; `icos_open` passes a payload to it.
- `icos_close` gives an app a chance to stop before its page is removed.
- A normally returning app is removed and reveals Home; a crashed app stays open on
  its diagnostic page.

The base runs two independent instances when it has a monitor. Its local terminal has
keyboard input and receives the complete app set, including configuration, Update,
Setup, Terminal, and Fleet Console. The monitor surface has no keyboard and receives
only definitions with `requiresInput = false`: Fleet Status and a read-only Fleet Log.
Fleet Status launches automatically and removes all deploy, recall, refresh, row-open,
and configuration actions; touch is retained only for harmless display paging and app
switching. Events are surface-scoped so a monitor touch cannot click the local desktop.

The monitor Fleet Status page can claim the largest secondary monitor for its haul
view. The interactive Fleet page on the local desktop does not compete for that wall.
Display selection and text scaling live in `src/core/display.lua`.

## Miner model

`src/apps/miner.lua` is deliberately a small composition root. It creates a
`miner.context`, then runs four concurrent loops:

- `miner.runtime.agent` — job and park lifecycle
- `miner.network.heartbeat` — discovery and status broadcasts
- `miner.network.commands` — remote command intake
- `miner.runtime.localControls` — keys and turtle-screen controls

The lifecycle is:

```text
setup/deploy → working → return/unload → next cycle or parked
                         ↑                 │
                         └── recall/fuel ──┘
```

A parked turtle does not exit. It remains discoverable and accepts configuration,
deployment, update, and job-selection commands.

## Fleet model

`fleet/service.lua` is the only base-side Rednet receiver. It starts at boot, hosts the
base name, persists every turtle snapshot through `fleet/roster.lua`, renews leases,
answers mine claims, refreshes status, and applies conservative automation. Fleet and
Devices are views over that state, so neither app must remain open. Touching a Fleet
row opens Devices focused on that computer ID.

The default policy refreshes health, resumes a fuel park only after reported fuel meets
the turtle's own requirement, retries setup preflight and depot-full unloading, and
logs heartbeat transitions. It never auto-restarts an intentional recall, completed
job, unknown error, or stuck route. Rolling updates are available but opt-in.

`fleet/coordinator.lua` performs multi-turtle assignments. The coordinated quarry
currently selects connected parked miners, divides the world rectangle into balanced
non-overlapping cell ranges, and sends one atomic assignment to each worker.

The service answers shared-mine `mine` requests inline through `fleet/coordinator.lua`,
which leases prospecting sectors and records their frontiers in `mine/registry.lua`.
Handling is synchronous and short because a turtle waits about three seconds before
falling back to its cached plan.

A Pocket Computer uses role `controller`. Its own service passively mirrors turtle
heartbeats and subscribes to the base for authoritative roster, policy, and log state.
Mine/quarry operations are validated and executed on the base through request/result
messages; the handheld never hosts `base` and never answers a turtle's mine claim.

## Update model

`bootstrap.lua` installs the minimum updater dependencies and writes `.update`.
`update.lua` resolves the configured branch to a commit SHA, downloads the generated
manifest, writes changed files, and reads them back to verify checksums.

Only files listed in `src/manifest.json` are deployed. Root documentation and developer
tools stay in Git and are not copied onto in-game computers. The updater does not prune
old files that disappear from the manifest; removed modules can remain harmlessly on
existing devices until manually deleted, but no current code should require them.
