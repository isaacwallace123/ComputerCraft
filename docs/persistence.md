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
| `.gps` | install/GPS host | absolute X/Y/Z advertised by a device with the `gps` role |
| `.nav` | `device/nav.lua` | relative position/facing, movement statistics, world origin and heading |
| `.fleet` | `legacy/fleet/roster.lua` | paired device snapshots and last-seen times |
| `.fleet-policy` | `legacy/fleet/policy.lua` | unattended recovery, refresh, sync, and update policy |
| `.fleet-log` | controller service | recent authoritative base log mirrored to a Pocket controller |
| `.fleet-responses` | controller service | short-lived request-correlated operation replies |
| `.mine` | `domain/mine/registry.lua` | base mine plan, leases, and per-profile/depth frontiers |
| `.site` | `legacy/mine/site.lua` | turtle's cached mine plan and most recent sector claim |
| `.update` | bootstrap/updater | GitHub user, repo, branch, source path, optional token |
| `.update-result` | updater/runtime | last update success or failure details |
| `.log` | `adapters/cc/logfile.lua` | capped persistent base log |
| `.quarry` | quarry job | world box, worker partition, layer/cell progress, delivery count |
| `.expedition` | rare job | legacy-compatible rare prospecting settings and progress |
| `.fuel-hunt` | fuel job | coal prospecting settings and progress |
| `.resources` | resources job | common-resource settings and progress |
| `.hollow` | hollow job | room settings and current cell |
| `.swarm` | swarm app | deployer layout and progress |

## Configuration behavior

`adapters/cc/config.lua` copies defaults and then overlays saved top-level fields. It is a
shallow merge. Nested tables are replaced, not recursively merged. Prefer flat saved
fields for values that need forward-compatible defaults.

Writes go to a temporary sibling first and replace the live file only after the new
serialization is closed. If power is lost in the replacement window, loading recovers
the completed temporary file instead of silently falling back to defaults.

Movement state is written after each confirmed movement. Job checkpoints are written
after completed cells, trunk cells, layers, or phase transitions. This ordering is
intentional: a crash may repeat already-cleared air, but must not skip unmined blocks.

## Migration rules

- The former job name `expedition` migrates to `rare` in miner context.
- Rare deliberately keeps using `.expedition` so existing settings and progress are
  not discarded during the rename.
- The coordinated quarry is incompatible with the old relative width/length/depth
  file shape. Detection of those legacy keys marks the job unconfigured and inactive.
  A fresh absolute assignment is required.
- Readers must tolerate missing fields because fleet devices update independently.
- A Pocket Computer saved with the former `fleet` role migrates to `controller` at
  startup, preventing it from competing with the stationary base hostname.
- Never delete unknown persisted fields during a migration unless their meaning is
  dangerous. Layering defaults naturally preserves fields older code does not use.

## Moving a turtle

`nav.setHome()` resets only job-relative coordinates. Absolute quarry and shared-mine
navigation also depend on the world origin and heading recorded by the Where tool.
After physically moving or turning a turtle, run Where again before deploying it. The
tool resets the relative frame and records the new world origin together.

## Secrets

A private-repository token in `.update` is plaintext in the world save. Use a
fine-grained, read-only token scoped to this repository with an expiry. Never add an
in-game `.update` file or token to Git, logs, screenshots, or documentation.
