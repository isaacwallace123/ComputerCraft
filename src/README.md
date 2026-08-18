# The source tree

One architecture, top to bottom, plus a quarantine for the one it replaces.

```
domain/     Pure rules. No CC globals, no I/O, no requires outward.
              fleet/  mine/  depot/  turtle/
ports/      Interfaces: tables of function names, nothing else.
adapters/   How a real machine provides a port.
              cc/     ComputerCraft
              sim/    the spec suite's world
os/         The four operating systems and what runs them.
              kernel/ supervisor, service, boot, roles
              server/ client/ mobile/ turtle/
device/     A turtle's own hardware: navigation, fuel, inventory, ore.
jobs/       What a turtle does, grouped by what it is for.
              mining/  prospecting/  common/
ui/         The framework.
              core/       reactive, runtime, layout, buffer, anim
              draw/       canvas, sprite
              components/ Button, Table, Page, ...
apps/       Pages. One folder each: app.lua wires, view.lua draws.
lib/        Genuinely generic. Two files, and it stays that way.
legacy/     ICOS 1. Deleted a folder at a time as ICOS 2 replaces it.
```

## The rule that decides where a file goes

**Which way does it point?** `domain/` knows nothing below it. `ports/` names
what it needs without saying how. `adapters/` knows CC without knowing what
anybody does with it. `os/` knows both the shape and the machine, and is the only
layer allowed to.

If a file needs to know two of those at once, it is a composition root and
belongs in `os/`. If it needs to know none of them, it belongs in `domain/`.

## Why `legacy/` exists

Before this, two complete operating systems lived interleaved. `src/mine/` sat
beside `src/domain/mine/`; `src/miner/` beside `src/os/turtle/`; `src/fleet/`
beside `src/domain/fleet/`; and one directory held both `apps/devices.lua` and
`apps/devices/`. Every pair was ICOS 2 next to the ICOS 1 thing it replaces, and
nothing in a path said which one was live.

Now the path says it. `legacy/` is code that works, ships, and is running a fleet
right now — and that has a replacement written or planned. Deleting it is one
folder at a time, when the replacement has been proven in a world rather than in
a spec suite.

**Nothing new goes in `legacy/`.** A change there is a bug fix for the running
fleet, or it is in the wrong file.

## Why `core/` is gone

It was thirteen of fourteen files touching CC globals — a runtime, not a core.
The name attracted anything that did not obviously belong elsewhere, which is how
a folder becomes a landfill.

Its contents went where they actually belonged: `util` and `version` to `lib/`,
`config` and `log` to `adapters/cc/` (both are CC I/O wearing a friendly name),
and the shell, desktop, net and device-detection to `legacy/`.

`lib/` is checked for CC globals by `tools/check.ps1` for exactly this reason. It
is the mechanism that stops it becoming the next `core/`.

## Where the debt is

`tools/check.ps1` holds an allow list, and it is the complete inventory:

- **`domain/mine/registry.lua`** reads `os.epoch` and requires `adapters/cc/config`.
  Half fixed — every function takes an optional `now` — and finishable when
  `legacy/fleet/coordinator.lua` goes.
- **`lib/util.lua`** reads `os.epoch` in `since`, for the same reason and with the
  same optional `now`.
- **`device/`** is real algorithms welded to CC globals. It should reach hardware
  through `ports/body` and does not yet.

An allow list is the point. A rule with an exception nobody can see is a rule
that has already been abandoned.
