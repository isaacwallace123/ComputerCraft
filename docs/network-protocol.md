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
| `progress` while parked | durable job progress, not route phase; 1 when `parkKind` is `complete` |
| `settings`, `settingFields` | values and schema rendered by Devices |
| `sector`, `workKey` | shared-mine sector and profile/depth key, absent for other jobs |
| `peers` | how many other miners this turtle can currently hear |

New snapshot fields should be optional on readers because old turtles may not report
them until updated.

Miners now also listen to each other's `status` broadcasts, not just the base. The
`world` field is what makes that useful: `turtle/peers.lua` uses it to tell which
computer is standing in the block ahead, and therefore who has right of way.

### `mine`

Broadcast by a turtle to claim or update a shared-mine sector. Broadcast rather than
addressed because the base is the only thing that answers, which keeps the turtle from
having to know a base ID.

| Action | Extra fields | Meaning |
| --- | --- | --- |
| `claim` | `requestId`, `workKey`, `sector`, `frontier` | request work; the turtle's cached sector/frontier is preferred |
| `report` | `workKey`, `sector`, `frontier`, `blocks`, `exhausted` | record progress for one profile/depth |
| `release` | `sector` | give a lease back without recording progress |

The base replies to `claim` with `mine_result`:

```lua
{
  ok = true,
  requestId = "17:1786914000000:rare@-59",
  plan = { centreX = 0, centreZ = 0, surfaceY = 64, cellSize = 48, ... },
  sector = 3,
  frontier = 17,
}
```

`ok = false` carries a `message` and no plan. A turtle waits about three seconds for
this before falling back to its cached plan, so the handler must not block. Leases
expire after 15 minutes of silence so a turtle lost to lava does not lock a sector out
permanently. While a turtle is running, its normal status heartbeat renews the lease;
a parked turtle eventually releases it by expiry.

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
