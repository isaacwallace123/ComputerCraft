# Persistent state

ICOS stores Lua-serialized tables in dotfiles on each in-game computer. Code comes
from Git; operational state belongs to the device and is deliberately not listed in
the update manifest.

The manifest is a deployment allowlist, not a filesystem synchronizer. Updating writes
listed source files but does not delete a source file removed in a later release. Code
must stop requiring deleted modules before they are removed from the manifest.

## Files

| File | Owner | Contents |
| --- | --- | --- |
| `.node` | install/startup/miner context | role, label, selected job, parked state and reason, auto-update |
| `.nav` | `turtle/nav.lua` | relative position/facing, movement statistics, world origin and heading |
| `.fleet` | `fleet/roster.lua` | paired device snapshots and last-seen times |
| `.update` | bootstrap/updater | GitHub user, repo, branch, source path, optional token |
| `.update-result` | updater/runtime | last update success or failure details |
| `.log` | `core/log.lua` | capped persistent base log |
| `.quarry` | quarry job | world box, worker partition, layer/cell progress, delivery count |
| `.expedition` | rare job | legacy-compatible rare prospecting settings and progress |
| `.fuel-hunt` | fuel job | coal prospecting settings and progress |
| `.resources` | resources job | common-resource settings and progress |
| `.hollow` | hollow job | room settings and current cell |
| `.swarm` | swarm app | deployer layout and progress |

## Configuration behavior

`core/config.lua` copies defaults and then overlays saved top-level fields. It is a
shallow merge. Nested tables are replaced, not recursively merged. Prefer flat saved
fields for values that need forward-compatible defaults.

Movement state is written after each confirmed movement. Job checkpoints are written
after completed cells, tunnel steps, layers, or phase transitions. This ordering is
intentional: a crash may repeat already-cleared air, but must not skip unmined blocks.

## Migration rules

- The former job name `expedition` migrates to `rare` in miner context.
- Rare deliberately keeps using `.expedition` so existing settings and progress are
  not discarded during the rename.
- The coordinated quarry is incompatible with the old relative width/length/depth
  file shape. Detection of those legacy keys marks the job unconfigured and inactive.
  A fresh absolute assignment is required.
- Readers must tolerate missing fields because fleet devices update independently.
- Never delete unknown persisted fields during a migration unless their meaning is
  dangerous. Layering defaults naturally preserves fields older code does not use.

## Moving a turtle

`nav.setHome()` resets only job-relative coordinates. Absolute quarry navigation also
depends on the world origin and heading recorded by the Where tool. After physically
moving a quarry turtle, run Where again before assigning world coordinates.

## Secrets

A private-repository token in `.update` is plaintext in the world save. Use a
fine-grained, read-only token scoped to this repository with an expiry. Never add an
in-game `.update` file or token to Git, logs, screenshots, or documentation.
