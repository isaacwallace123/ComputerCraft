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
              client/ mobile/
              server/ main.lua + services/   its long-running work
              turtle/ main.lua + jobs/       its work
                                + device/    its hardware
ui/         The framework. The spine is at the top, the machinery below.
              init.lua     front door
              runtime.lua  the component system
              input.lua    events, focus, hit testing
              host.lua     mount, and the run loop
              theme.lua    tokens and palettes
              format.lua   text that must fit an exact cell width
              state/       reactive, anim - values that change over time
              render/      buffer, layout, canvas, sprite
              components/  grouped by family, not one file each
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

**And who runs it?** `jobs/` and `device/` started at the top level and did not
belong there: nothing on the base ever requires a job module - the base reads
`domain/turtle/jobs.lua`, the catalogue, which is why `module` is a string and not
a `require`. Both are turtle-only, so both live under the turtle.

That makes `os/` symmetric. A server is `main.lua` plus `services/`, its
long-running work. A turtle is `main.lua` plus `jobs/`, its work, and `device/`,
its hardware. Adding a farming job is `os/turtle/jobs/farming/` and one entry in
the catalogue.

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

## Why `ui/` has no `core/`

It had one, for exactly one commit, and it was the same mistake this document
criticises `src/core/` for. Four unrelated concerns shared a folder whose name
said nothing: `reactive`+`anim` (values that change over time), `buffer`+`layout`
(boxes and cells), `runtime`+`input` (the component system), `util` (text
padding).

Now the folders are named for what they hold, and the framework's spine sits at
the top level where a reader opening `ui/` sees what the thing is made of.

Two things were deliberately **not** changed:

- **`components/` groups by family** - `text.lua` holds Text, Heading and Muted;
  `controls.lua` holds Button, Badge, Meter, Stepper, Select and Toggle. One file
  per component is the shadcn habit and it works there because each component is
  standalone; here Stepper, Select and Toggle share `controlRow`, so splitting
  would produce fifteen files and a sixteenth for the helper.
- **`runtime.lua` is 768 lines and stays one file.** It is already sectioned -
  registry, nodes, scopes, painting, the root, input - and those sections are
  three files waiting to happen. But `Root` methods reach `markPaint`,
  `markMeasure` and `markLayout` directly, so splitting means either spreading a
  metatable across files or inventing a shared internal module. That is a real
  refactor of the most intricate, most load-bearing code in the project, and
  organisational tidiness is not a good enough reason to risk it. It is recorded
  here so the next person knows it was considered rather than missed.

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
