# Network protocol

## Transport

All fleet traffic uses Rednet protocol `ccfleet`. The base hosts hostname `base`.
`core/net.lua` prefers a wireless modem and falls back to wired for bench testing.
Messages are best-effort and must never be required for a turtle to finish or return.

Every message has this envelope:

```lua
{
  kind = "status",
  body = { ... },
  at = os.epoch("utc"),
}
```

Malformed envelopes are ignored. `rednet.send` confirms local transmission, not
remote receipt; command results and later status snapshots provide application-level
feedback.

## Turtle-to-base messages

### `hello`

Announces a newly installed or newly rediscovered turtle. The body is normally a
snapshot, though installation may send a minimal body containing label, role, phase,
and version.

### `status`

Broadcast every two seconds and sent directly after `status_request`.

Important snapshot fields:

| Field | Meaning |
| --- | --- |
| `label`, `version`, `role`, `job` | device identity and software/job selection |
| `phase`, `detail`, `parked`, `parkKind` | lifecycle and user-facing reason |
| `x`, `y`, `z`, `facing` | job-relative navigation state |
| `world` | world coordinates when origin or GPS is available |
| `fuel` | tank plus known carried fuel; `-1` means unlimited |
| `fuelTank`, `fuelReserve`, `fuelRequired` | detailed fuel telemetry |
| `distanceHome`, `moves`, `digs` | navigation statistics |
| `progress`, `haul`, `delivered`, `startedAt` | job telemetry |
| `settings`, `settingFields` | values and schema rendered by Devices |

New snapshot fields should be optional on readers because old turtles may not report
them until updated.

### `command_result`

```lua
{
  action = "configure",
  ok = true,
  message = "settings saved",
  snapshot = { ... },
}
```

Fleet logs these results. Devices also optimistically updates controls so repeated
touches do not wait for the next heartbeat.

## Base-to-turtle `command` actions

| Action | Extra fields | Rules |
| --- | --- | --- |
| `recall` | none | running turtle returns; parked turtle acknowledges immediately |
| `deploy` | none | parked only; readiness and fuel are checked before movement |
| `set_job` | `job` | parked only |
| `assign_job` | `job`, `settings` | parked only; atomically select, configure, and queue deploy |
| `configure` | `settings` | parked only; job validates all supplied values |
| `status_request` | none | reply with current snapshot |
| `update` | none | parked turtle updates; working turtle recalls first |
| `rename` | `label` | label is truncated to 32 characters |

Unknown actions are currently ignored. When adding an action, update the receiver,
the sending UI/console, result handling, and this table.

## Discovery and staleness

Turtles resolve the hosted base name periodically but broadcast status even before a
base is found. Fleet persists the last snapshot in `.fleet`. A device becomes late
after 10 seconds and offline after 60 seconds; offline devices remain visible until
explicitly forgotten.

Plain wireless range loss is expected. Do not turn a missed heartbeat into a mining
failure or synchronous retry loop.
