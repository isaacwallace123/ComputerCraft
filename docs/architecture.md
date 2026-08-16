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
  desktop + console        synced roster/policy  Rednet   navigation + fuel
  authoritative state  ↔   Fleet/Devices/Operations  ↔   local job safety
```

## Dependency direction

The intended dependency flow is:

```text
apps → miner / fleet / jobs → turtle / mine → core
```

- `core/` contains platform services: configuration, UI, display, logging, networking,
  sound, boot, and app metadata.
- `mine/` contains the shared worksite: sector geometry (`plan.lua`, pure arithmetic),
  the base-side lease and frontier store (`registry.lua`), and the turtle-side cache and
  claim client (`site.lua`). It sits beside `turtle/` because both sides import it.
- `turtle/` contains hardware primitives and should not know about a particular job.
- `jobs/` contains mining behavior and accepts callbacks rather than drawing UI or
  receiving network messages.
- `miner/` owns the long-running turtle state machine, telemetry, and command handling.
- `fleet/` owns shared base-side roster and coordination logic.
- `apps/` contains thin executable entrypoints and interactive views.

Avoid dependencies in the opposite direction. In particular, a turtle primitive
should not import an app, and a job should not manipulate the desktop.

## Boot flow

`src/startup.lua` is the installed entrypoint:

1. Load `.node` and detect device capabilities.
2. Choose the local turtle screen or the best attached computer monitor.
3. Show a splash. Holding a key opens recovery/system tools.
4. If enabled, run the automatic updater.
5. Load the app registry after updating so fresh app definitions are used immediately.
6. On a turtle, auto-run the only valid launcher app or show the compact launcher.
7. On a Pocket Computer, start the touch-first handheld shell. On other computers,
   start the page-based desktop; if it is on a monitor, run the keyboard console on
   the physical computer in parallel.
8. For `fleet` and `controller` roles, run networking beside the UI. Closing an app
   never stops discovery, sector leasing, telemetry, or controller synchronization.
   Startup supervises and restarts that service if an unexpected runtime error escapes.

`src/install.lua` assigns the device role and label. Capability filtering in
`src/core/apps.lua` decides which apps and tools are valid for the hardware and role.

## Desktop model

`src/core/desktop.lua` implements maximized pages rather than nested windows:

- Home is permanent and owns the ICOS title bar.
- Each app gets its own terminal window and owns row 1 while focused.
- The bottom taskbar is global chrome.
- Keyboard and pointer events go only to the focused app.
- Timers, Rednet, resize, and ICOS events are broadcast to all app coroutines.
- `icos_open_app` opens or focuses a page; `icos_open` passes a payload to it.
- `icos_close` gives an app a chance to stop before its page is removed.

Fleet can claim the largest secondary monitor for its haul view. Display selection and
text scaling live in `src/core/display.lua`.

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
