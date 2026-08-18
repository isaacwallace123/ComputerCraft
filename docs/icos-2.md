# ICOS 2 — architecture plan

This is a plan, not a description. Nothing here is built yet.

It covers four things that were asked for together because they turn out to be the same
change: a server that is the brain, control that survives an unloaded chunk, a mutable
list of drop-offs, and a codebase laid out so all of that has somewhere to live.

Read [`docs/architecture.md`](architecture.md) first for what exists today, and
[`docs/ui-framework.md`](ui-framework.md) for the rendering and component layer these
operating systems are drawn with.

---

## 1. Why

Four failures drove this, all observed in a running fleet:

| Symptom | Actual cause |
| --- | --- |
| Recall does nothing when a turtle is out of render distance | Control is an **event**. If nobody is listening, it is gone. |
| Three miners vanished and nothing knew where | Position is broadcast and discarded. Nothing persists it. |
| Everything must come home to one chest | The depot is a convention (`below home`), not data. |
| `where.lua` sits in `apps/` next to Fleet | There is no distinction between an app, a tool, and a service. |

The first two are the same bug seen twice: **the system has no memory and no
authority.** A device shouts, something may or may not hear it, and nothing is written
down. Everything below follows from fixing that.

---

## 2. Four operating systems

Today's roles are `fleet`, `controller`, `miner`, `gps`, `utility`. They become four
operating systems, each a composition root that wires the same shared code differently.

| OS | Runs on | Owns | Replaces |
| --- | --- | --- | --- |
| **Server** | Advanced computer, chunk-loaded | Authoritative state, device registry, GPS host, desired state | `fleet` + `gps` |
| **Client** | Advanced computer + monitor | Views and control surfaces. Holds no authority. | `fleet`'s desktop half |
| **Miner** | Mining turtle | Movement, jobs, local safety | `miner` |
| **Mobile** | Pocket computer | The same views, touch-first | `controller` |

The `gps` role disappears into Server. A server already has to be permanently loaded and
already has to know exactly where it is — that is the entire job description of a GPS
host. Running them as separate roles meant maintaining two always-on machines with the
same requirements and no shared state.

**Servers are plural.** Four or more form the GPS constellation. One of them is
**primary** and holds authoritative state; the others host GPS and mirror. Replication is
deliberately deferred (§10).

---

## 3. Layering: ports and adapters

The domain is the part worth protecting: geometry, planning, reconciliation, policy.
Today it is tangled with `turtle.*`, `fs`, `rednet`, and `term`, which is why testing it
required simulating a whole world.

```
                    ┌─────────────────────────────┐
   os/server ──────►│                             │
   os/client  ─────►│          domain/            │  pure Lua
   os/miner   ─────►│   no globals, no CC APIs    │  no I/O
   os/mobile  ─────►│                             │  fully testable
                    └──────────────┬──────────────┘
                                   │ depends on
                                   ▼
                            ┌─────────────┐
                            │   ports/    │  interfaces only
                            └──────┬──────┘
                                   │ implemented by
                    ┌──────────────┴──────────────┐
                    ▼                             ▼
             adapters/cc/                   adapters/sim/
       fs, rednet, term, turtle          the spec suite's world
```

**The rule:** `domain/` may not reference a CC global. Not `fs`, not `turtle`, not
`term`, not `os.epoch`. Everything it needs arrives through a port.

That single rule is what makes the rest cheap. The simulated world in
[`tools/spec/`](../tools/spec) stops being a monkey-patch over `_G` and becomes an
ordinary adapter, and domain tests need no world at all.

**The rule is checked.** `tools\check.ps1` strips comments from everything under
`src/domain`, `src/ports`, and `src/ui` and fails the build on a reference to any CC
global. It has one entry in its allow list — `domain/mine/registry.lua` and `os` — with
the reason recorded in that file's header. Do not add a second without doing the same.

The simulated world keeps its `install()` alongside its new `ports()` face, and will for
a while. Every module written before ports existed reads `turtle`, `fs`, and `os` as
globals; rewriting all of them at once is exactly the flag day §12 refuses to have. New
code takes ports, old code keeps its globals, and both see one world.

### Ports

As built in phase 1:

| Port | Methods | CC adapter | Sim adapter |
| --- | --- | --- | --- |
| `clock` | `now`, `sleep` | `os.epoch("utc")`, `sleep` | the world's clock, advanced by the test |
| `storage` | `read`, `write`, `list`, `delete` | `fs` + atomic replace | in-memory table |
| `transport` | `send`, `broadcast`, `receive`, `id` | `rednet` | in-memory queue, droppable |
| `screen` | `size`, `blit`, `clear`, `isColour`, `setPalette`, `setCursor` | `term` or any redirect | recording cell grid + call log |
| `body` | `move`, `turn`, `dig`, `detect`, `inspect`, `place`, `drop`, `select`, `slot`, `stack`, `fuel`, `refuel` | `turtle` | block grid |
| `locator` | `gps`, `saved` | `gps` + `.location` | fixed answer |

Ports are tables of functions, not classes. There is no inheritance anywhere in this
plan. Each port module carries its own list of method names, a `check(impl)` that verifies
a table against that list and returns it, and a `null()` that answers rather than raises.
`ports/contract.lua` is the entirety of the machinery.

Three details that only became apparent while building them:

- **`screen.blit` carries its own `x, y`.** CC's terminal has a cursor and `term.blit`
  writes wherever it happens to be. Hidden ordering state defeats the recording adapter —
  a call cannot be verified in isolation, and "one blit per changed run" stops being
  countable. One port call is now one positioned run, and moving the cursor is the cc
  adapter's private business.
- **Colours are palette indices 0–15**, not `colors.*` bitmasks. The blit format is a hex
  digit and the palette is sixteen numbered slots; carrying the bitmask would mean
  converting it back on every cell. The conversion happens inside the cc adapter, twice a
  frame, on calls that are not on the hot path.
- **`transport.id` was missing from the sketch.** A sender that cannot name itself makes
  every message ambiguous, and every existing caller was reaching for
  `os.getComputerID()` directly to fill the gap.

---

## 4. Directory layout

```
src/
  domain/                    pure logic, no CC globals, no I/O
    mine/                    plan geometry, spine assignment, frontiers
    fleet/                   device registry, desired state, reconciliation
    depot/                   drop-off list and selection
    job/                     job state machines and route planning
    protocol/                message shapes and versioning
  ports/                     interface definitions and null implementations
  adapters/
    cc/                      fs, rednet, term, turtle, gps, peripheral
    sim/                     the spec suite's world, promoted to first class
  os/
    server/                  composition root + always-on services
    client/                  composition root + desktop shell
    miner/                   composition root + job runtime
    mobile/                  composition root + handheld shell
  apps/
    fleet/                   app.lua, view.lua, state.lua
    devices/
    mine-control/
    drop-offs/
    logs/
    update/
    setup/
    power/
    terminal/
  commands/                  one-shot operator commands, no page
    locate.lua               (was apps/where.lua)
    equip.lua
    swarm.lua
    scan.lua
  shell/                     desktop, handheld, headless — hosts apps
  startup.lua                detects OS, hands off to os/<name>
```

### Two recommendations against what was asked

**OS folders go in `src/os/`, not `src/core/`.** `core/` means "platform services
everything shares". An OS is a composition root: it knows about apps, services, and
adapters, and wires them together. Putting it inside `core/` inverts the dependency —
`core` would import `apps` — which is the exact thing the layering is for. If the
grouping matters more than the rule, `src/core/os/<name>/` gets the same nesting without
breaking anything; nothing else in the plan changes. Your call.

**One `apps/` tree, not one per OS.** Several apps genuinely run on more than one OS —
Fleet and Devices on both Client and Mobile, Logs and Update on all four. A folder per OS
forks those into copies that drift. Instead each app declares where it runs:

```lua
-- apps/fleet/app.lua
return {
  id = "fleet",
  title = "Fleet",
  os = { "client", "mobile" },
  requiresInput = false,        -- may appear on a display-only monitor
  requires = { "transport" },   -- ports it needs to function
  run = function(ctx) ... end,
}
```

The existing capability filter in `core/apps.lua` already does most of this. This
formalises it as a manifest the shell reads.

### Apps, commands, services

You were right that `where.lua` is not an app. Three categories, one test each:

- **App** — has a page you look at and leave open. Lives in `apps/<id>/`.
- **Command** — runs once, prints, exits. No page, no taskbar entry. Lives in
  `commands/`.
- **Service** — never has a page, runs for the life of the machine. Lives under
  `os/<name>/services/`.

By that test: Fleet, Devices, Mine Control, Drop-offs, Logs, Update, Setup, Power,
Terminal are apps. `locate`, `equip`, `swarm`, `scan` are commands. Discovery, lease
handling, GPS hosting, reconciliation are services.

`where` becomes `commands/locate.lua` **and** a first-run setup step, because every
device now declares its location (§9), not just turtles.

---

## 5. Desired state instead of events

This is the most important change in the plan.

**Today.** The base sends `{action="recall"}` over rednet. The turtle is in an unloaded
chunk. The message is gone. The dashboard shows the command as sent. Nothing happens,
ever.

**Target.** The server holds what each device *should* be doing. Devices reconcile
towards it whenever they can talk.

```lua
-- server, persisted
devices["7"] = {
  desired  = { mode = "recall", generation = 41 },
  observed = { mode = "mining", generation = 40, at = 1712... },
}
```

Every heartbeat carries the device's observed state and the generation it has applied.
The reply carries the desired state. The device compares generations and acts.

```
   device                                   server
     │  heartbeat { observed, applied=40 }    │
     ├───────────────────────────────────────►│
     │                                        │  desired.generation = 41
     │◄───────────────────────────────────────┤
     │  { desired = { recall, gen 41 } }      │
     │                                        │
   applies, sets applied=41                   │
     ├───────────────────────────────────────►│  converged
```

Properties that fall out of it, none of which are true today:

- **Survives an unloaded chunk.** The turtle reconciles when it comes back. Recall stops
  being a message that can be missed and becomes a fact that is eventually true.
- **Idempotent.** Replaying a generation changes nothing. Duplicate delivery is harmless.
- **Monotonic.** Generations only increase, so an old reply cannot undo a newer order.
- **Survives a server restart**, because it is persisted rather than in flight.
- **Honest UI.** The dashboard shows `converged` / `pending` / `unreachable` instead of
  "sent". Pending with a stale heartbeat is exactly the information that was missing when
  three miners went quiet.

**The autonomy invariant is unchanged.** A device that cannot reach the server keeps
doing what it was last told. Losing the server must never strand a turtle underground —
that rule (D004) survives this plan intact and is the reason desired state is a *goal*,
not a *permission*.

Modes: `park`, `deploy`, `recall`, `update`, `stop`. Job and settings ride alongside as
part of the desired record, which also removes the current three-message
set-job / configure / deploy dance.

---

## 6. Device registry and last known location

Every device — not only turtles — reports on a heartbeat. The server persists:

```lua
{
  id = 7, label = "miner-7", os = "miner",
  location = { x = 138, y = -59, z = -1176, dimension = "overworld" },
  seenAt = 1712...,        -- server clock, not the device's
  fuel = 51000, phase = "mining", job = "rare",
  desired = {...}, observed = {...},
}
```

Retained after a device goes quiet — that is the whole point. A missing turtle has a
**last known position and a timestamp**, which is the difference between "three miners
are gone" and "three miners were at these coordinates twenty minutes ago, heading east".

A Devices app view sorted by staleness makes that the first thing you see.

---

## 7. Drop-offs

A mutable, ordered list held on the server and synced to devices.

```lua
{
  id = "depot-north",
  label = "North depot",
  position = { x = 42, y = 84, z = -1084 },
  accepts = { "*" },          -- or { "_ore", "raw_", "ingot" }
  enabled = true,
  full = false,               -- last reported by a turtle that tried
}
```

**Managed by a Drop-offs app** on Client and Mobile: add here / add by coordinates / add
by GPS, rename, reorder, enable, disable, delete. Ordering matters — it is the tie-break
when two are equally close.

**Selection** is domain logic (`domain/depot/select.lua`), which means it is testable
without a world: given a position, a fuel budget, and the list, return the drop-off to
use, or `home`. Rules, in order: enabled, accepts the cargo, not known full, reachable
within the fuel reserve, then nearest, then list order.

**Two things this breaks that must be handled in the same change:**

1. `returnDistance` currently assumes the route home. Routing to a drop-off that is not
   home changes the exact return-fuel reserve, which is the single most safety-critical
   number in the codebase (D009). The chosen drop-off has to be picked *before* the
   outward fuel check, not after the inventory fills.
2. The chest-below-home convention (D008) stays as the **fallback**, and stays the
   default when the list is empty. An empty list must behave exactly like today.

---

## 8. Services

A service never has a page and runs for the life of the machine. This is D018
generalised: closing the Fleet app used to disable sector leasing, because coordination
was living inside a page. Splitting them by category means that cannot be expressed.

**The rule: services own state, apps read it.** No app performs coordination, and no
service draws. An app that is closed, crashed, or was never opened changes nothing about
what the machine is doing.

### What runs where

| OS | Services |
| --- | --- |
| **Server** | `discovery` · `reconcile` · `leases` · `gps` · `persist` · `policy` · `logrotate` |
| **Client** | `mirror` · `intents` |
| **Mobile** | `mirror` · `intents` |
| **Miner** | `heartbeat` · `agent` · `peers` · `controls` |

Client and Mobile run exactly the same two, which is more evidence for one shared tree
(§4) rather than a copy per OS.

Two of these deserve naming. `mirror` keeps a local read-only copy of server state, so
apps render instantly and survive a brief server outage instead of showing an empty
screen. `intents` is the only thing that talks to the server about changes — which means
**a client never commands a turtle directly.** It asks the server to change desired
state, and the server owns the conversation. D019's "a handheld is never a second base"
stops being a convention and becomes a thing the structure enforces.

Today's `fleet/service.lua` is one function doing discovery, leases, policy, logging, and
persistence. Splitting it is the point: a bug in the auto-recovery policy currently takes
sector leasing down with it.

### Manifest

Mirrors the app manifest, so the shell and the supervisor read the same shape:

```lua
-- os/server/services/reconcile.lua
return {
  id = "reconcile",
  requires = { "transport", "storage", "clock" },
  critical = true,        -- the machine is not healthy without it
  run = function(ctx) ... end,
}
```

### Supervision

CC gives cooperative multitasking and nothing else: coroutines under
`parallel.waitForAny`, no preemption. Two consequences that have to be designed for
rather than discovered.

**A service that does not yield starves every other service on that machine.** Services
are event-driven loops that block on `pullEvent` or a timer. Any long computation is
chunked. This is a review rule, not something the runtime can enforce.

**One service crashing must not take the others with it.** `parallel.waitForAny` returns
when *any* coroutine finishes, so today an escaping error stops everything. The
supervisor instead wraps each service, restarts it with exponential backoff, and keeps
its neighbours running. GPS must survive a bug in the auto-recovery policy — an outage
there breaks navigation for the whole fleet.

Crash-looping needs the same treatment the mining stall counter got: back off, then stop
and **say so on the dashboard**, rather than retrying forever while looking healthy. A
`critical` service that has given up should make the server visibly unhealthy; a
non-critical one should degrade quietly and be reported.

```
   supervisor
     ├── discovery    ● running     restarts 0
     ├── reconcile    ● running     restarts 0
     ├── gps          ● running     restarts 0
     ├── leases       ● running     restarts 2   last: 4m ago
     └── policy       ○ stopped     gave up after 5 failures — see log
```

That panel is a Services app: a page that *reads* supervisor state. The supervisor itself
runs whether or not anyone opens it.

## 9. Worksite geometry

Being redesigned in parallel (single shared two-lane shaft, spines fanning out at depth).
That work is independent of this plan and lands first. Under this layout it becomes
`domain/mine/`, with no changes to its logic — it is already nearly pure arithmetic,
which is why it is the easiest module to move and a good first phase.

---

## 10. Server OS setup and GPS

Every server declares its own position, two ways:

- **Manual** — F3 `Targeted Block`, typed in, with the explicit X/Y/Z confirmation screen
  that already exists (and the signed-number parser that had to be fixed once already).
- **GPS** — if a constellation is already up, look it up and confirm. Bootstrapping
  problem acknowledged: the first three servers must be manual.

Setup then validates the constellation and **says what is wrong**, rather than leaving
`gps locate` to fail silently later:

- fewer than four hosts reachable
- all four coplanar, or three collinear
- a host advertising a position that disagrees with where it is

Every non-server device also declares its location at setup, which is `where` promoted
from a turtle tool to a universal step. Turtles need heading as well as position; static
machines need only position.

---

## 11. What I am deliberately not planning yet

- **Multi-server state replication.** All servers host GPS from day one. Only the primary
  holds authoritative state. Real replication needs leader election and conflict rules,
  and getting that wrong is worse than a single point of failure you can see. Hot standby
  that mirrors and can be promoted by hand is the sensible next step.
- **Cross-dimension anything.** `dimension` is in the location record so it does not have
  to be retrofitted, and is otherwise ignored.
- **Authentication.** Rednet is open. Anyone on the channel can command the fleet. Worth
  knowing; not worth solving on a private server.

---

## 12. Phasing

Every phase is independently deployable and leaves a working fleet. Nothing here is a
flag day, because there is a live fleet to keep running.

| # | Phase | Delivers | Risk | |
| --- | --- | --- | --- | --- |
| 0 | Finish the worksite redesign | Shared shaft, spines | — | |
| 1 | Extract `domain/` + `ports/` + `adapters/` | No behaviour change. Specs stop needing globals. | Low, purely mechanical | **started** |
| 2 | Device registry + last known location | Missing turtles become findable | Low, additive | **domain done** |
| 3 | Desired state, running alongside events | Recall that works from an unloaded chunk | **High** — dual-run both paths, then delete events | **domain done** |
| 4 | Drop-off list | Multiple depots | Medium — touches return fuel | **domain done** |
| 5 | OS split | `os/server` absorbs fleet + gps | Medium — every device needs role migration | **server + roles done** |
| 6 | App folders and manifests, commands split out | The layout above | Low, mechanical | |

Phase 1 first is not tidying-before-features. It is what makes phases 3 and 4 testable —
reconciliation and drop-off selection are pure logic, and pure logic is the only kind this
project can currently test properly.

### What phase 1 has delivered so far

- `src/ports/` — `clock`, `storage`, `transport`, `screen`, `body`, `locator`, each a list
  of method names, a `check` that verifies an implementation against it at construction,
  and a null implementation. `ports/contract.lua` is the whole mechanism and it is thirty
  lines: no classes, no metatables, no dispatch cost.
- `src/adapters/cc/` — the six over `fs`, `rednet`, `term`, `turtle`, `gps`, and `os`.
- `src/adapters/sim/` — `world.lua`, moved here from `tools/spec/support/` and given a
  `ports()` face beside its existing `install()`. `screen.lua` is new: a recording screen
  that keeps a real cell grid and a call log.
- `src/domain/mine/` — `plan.lua` and `registry.lua`, moved with no logic changes.
  `src/mine/plan.lua` and `src/mine/registry.lua` remain as one-line aliases so the
  existing specs still resolve; that they passed untouched is the proof the move was clean,
  and the aliases go when the specs are rewritten against the new paths.
- `src/ui/buffer.lua` and its specs, and `.\tools\bench.ps1`. See
  [`ui-framework.md`](ui-framework.md) §12 for the measured numbers.
- `tools\check.ps1` gained a **layering check**: `domain/`, `ports/`, and `ui/` fail the
  build if they reference a CC global. The rule in §3 was previously a sentence in a
  document, which is the same as not having it.

Still open in phase 1, and deliberately deferred rather than forgotten:

- **`domain/mine/registry.lua` is not pure yet.** It still reads `os.epoch` and persists
  through `core/config`. Moving the file and changing how it gets its clock and its
  storage are two changes, and doing both at once would have destroyed the evidence that
  the move altered nothing. It is the one entry in the layering check's allow list.
- **`protocol/` and the message version field** named in §13. Nothing has been written yet
  and nothing depends on it until phase 3.
- **Nothing has been rewired.** Every adapter is constructed by nobody: the live fleet runs
  the same code paths it did before. Wiring composition roots is phase 5's job.
- **`adapters/sim/` ships in `src/manifest.json` and therefore onto every turtle.** It is
  about 25KB that no in-game device will ever require. Harmless, and left alone on
  purpose: teaching `tools/make-manifest.ps1` to exclude a folder is a special case a
  future maintainer would trip over for no benefit anybody can measure. Revisit only if
  the simulated world grows large enough that OTA update time notices it.

Phase 3 is the one to be careful with. Recall is a safety control; replacing its
mechanism while turtles are underground is how a fleet gets stranded. Both paths run
together until the dashboard shows every device converging, then events go.

### Phase 2: the device registry

`domain/fleet/registry.lua` is built and specced. It is **not wired** — `fleet/service.lua`
still writes `fleet/roster.lua`, and swapping them is a base-side change that wants an
in-world test.

It exists because §1's second failure turned out to be sharper than written. The claim was
*"position is broadcast and discarded"*; in fact it is broadcast, recorded **and then
destroyed by the next message**. `roster.update` replaces the whole record:

```lua
devices[key] = { snap = snapshot, lastSeen = now, pairedAt = ... }
```

A turtle's snapshot carries `world` only while it has an origin. Reboot one underground, or
run a build that has never been given its position, and it reports `world = nil` — at which
point the base overwrites the last position it knew with nothing. The information arrived
and the next heartbeat deleted it.

So the registry keeps the location **apart from the snapshot**, and only ever replaces a
location with another location. A device that stops knowing where it is does not make the
fleet stop knowing where it was, and `locatedAt` records when the fix was true rather than
when the device last spoke.

Three smaller decisions, all of which are specced:

- **Pure, with the clock injected.** No `os.epoch`, no `core/config`, no CC global. This is
  the shape D027 says `domain/mine/registry.lua` has to be rewritten into; writing the new
  one the old way would have doubled the debt rather than paid it.
- **`seenAt` is the receiving machine's clock.** A turtle's own clock resets on reboot and
  drifts against every other computer, so a device-supplied timestamp is uncomparable with
  the one from the turtle beside it — and "which of these went quiet first" is the question
  the module exists to answer.
- **A malformed position is no position.** `0, 0, 0` is a real place, and a half-filled
  record is how a device ends up claiming to be there.

Still to do for phase 2: `fleet/service.lua` writing through it, and a Devices view sorted
by staleness so a missing turtle is the first thing on the screen rather than the ninth.

### Phase 3: desired state

`domain/fleet/desired.lua` is built and specced. Not wired.

Each of the five properties §5 promises is a test rather than a claim, and two of them
turned out to need more care than the plan states:

- **Idempotent** is not enough on its own. A policy loop that re-asserts "park" every pass
  would bump the generation every pass and make every device re-apply an order it was
  already obeying — the event model wearing a new hat. So `want` compares goals *by
  content* and only moves the generation when the goal genuinely differs, including for
  the settings table, which the caller rebuilds on every call.
- **Monotonic** matters more than "generations increase". Rednet promises nothing about
  ordering, so a reply carrying generation 40 can arrive after one carrying 41. `apply`
  refuses anything at or below what the device has already applied, which is the only
  thing standing between that and a recalled turtle quietly going back to work.

The autonomy invariant is expressed as a return value rather than as a comment. `apply`
returns nil for a duplicate, a stale reply, a malformed message, a mode it does not know,
and no reply at all — and **nil means carry on, never stop**. Losing the server cannot
strand a turtle, because none of these functions can be reached without a reply having
arrived in the first place.

### Phase 4: drop-offs

`domain/depot/list.lua` and `domain/depot/select.lua` are built and specced. Not wired.

§7 names two things that had to be handled in the same change, and both are:

- **The chosen drop-off is picked before the outward fuel check.** `select.plan` returns
  the depot *and* the fuel that choice commits, in one call, so the two cannot be computed
  from different positions. A turtle that flew out on a reserve computed for home, filled
  up, and only then decided to visit a depot the other way has already spent the fuel it
  needed to get back. The cost includes the leg from the depot **home again**, because a
  turtle is not safe when it reaches a chest.
- **An empty list behaves exactly like today.** `choose` returns nil for an empty list, a
  list with nothing enabled, nothing that accepts the cargo, and nothing in fuel range.
  Every path that is not a positive answer is D008, unchanged, which is what makes this
  safe to ship to a fleet that never opens the screen.

Two smaller decisions worth knowing:

- Distance is **Manhattan**, because `nav.goTo` only travels on cardinals and a diagonal is
  walked as a staircase. Euclidean would under-estimate every route and the error would
  land in the one number that must never be optimistic.
- A `full` report **expires** after twenty minutes. Nothing ever reports a depot empty
  again — a person walks over, takes the diamonds, and tells nobody — so a flag without an
  expiry removes a depot from service permanently on the strength of one bad trip.

### Phase 5: roles, the server, and the first wired service

`os/roles.lua`, `os/server/main.lua` and `os/server/services/discovery.lua` join the
supervisor. **Nothing calls `boot`** — `src/startup.lua` still runs the ICOS 1 paths, and
switching it over is the one change in this branch that alters what an existing machine
does on power-up.

`discovery` is the first service to actually connect the domain modules: a heartbeat comes
in, the registry records it and retains its position, and the reply carries the desired
state. That exchange is the whole of §5, and it is now testable end to end without a world.

**The migration is a read, not a write.** `roleOf` translates on every boot rather than
rewriting `.node` once. A machine that rewrote its own role on first boot could not be
rolled back, and a fleet half-migrated by a partial update would hold two incompatible
ideas of what a `fleet` computer is. Translating means an old `.node` keeps working forever
and a downgrade is just a downgrade.

`fleet` is the only role that does not map one-to-one: §2 splits it into a server that holds
authoritative state and a client that draws it, and one machine was doing both. It maps to
**server**, with the client started beside it when the machine has a screen. Mapping it the
other way would mean a base that lost its monitor stopped being the fleet's brain.

Two things found while wiring it, both worth keeping:

- **`registry.observe` replaced the whole record**, which erased the `desired` and
  `observed` fields attached to it — so an order set while a device was away vanished the
  moment it checked in, which is exactly the failure desired state exists to fix. It is the
  same bug as the location one, one module over, and the fix is to mutate in place rather
  than to copy a longer list of fields forward. A list falls out of date; a mutation cannot.
- **The simulated transport did not yield.** A real `receive` blocks; this one advanced a
  counter and returned, which is fine when a spec calls it directly and a **hang** when a
  service loop runs under the supervisor — `coroutine.resume` never returns, and no
  supervisor can preempt its way out of that. It yields now, which is what a real one does.

### Phase 5: the supervisor

`os/supervisor.lua` and `os/service.lua` are built and specced. The four composition roots
are not.

The supervisor exists because of one sentence of CC semantics: **`parallel.waitForAny`
returns when *any* coroutine finishes.** So today an error escaping `fleet/service.lua`
stops discovery, lease handling, policy, logging and persistence together — and on a server
it would take GPS with it, which breaks navigation for the whole fleet. This resumes each
service itself, so one dying is one dying.

Four decisions worth knowing, each of them specced:

- **A service that returns is a fault, not a success.** A service runs for the life of the
  machine, so falling off the end of `run` is treated as a failure — which means it backs
  off rather than being restarted in a tight loop that would spin the machine at full
  speed forever.
- **`failures` and `restarts` are different numbers.** One is the current consecutive run
  and decides the backoff; the other is the lifetime count the panel shows. A service that
  failed twice and then ran for a week should not be one failure from being abandoned.
- **Giving up is loud.** Five consecutive failures and the service stops with its reason
  attached; a **critical** one doing so makes the whole machine report unhealthy. Reviving
  it is deliberately manual, because a supervisor that reset its own counter on a timer
  would turn "gave up after five failures" into "retries forever, slowly" — which is the
  state this design exists to make visible rather than to reach.
- **Missing ports are refused before the service starts.** A service declares what it
  needs; starting one without them produces a nil index somewhere inside its own loop, on
  a machine with no screen, at whatever moment it first reaches that line.

§8 says a service that does not yield starves its neighbours and calls that a review rule.
It is still a review rule — no runtime built on `coroutine` can preempt — but the
supervisor records how long each service ran between yields, so a starving one shows up as
a number on the Services page rather than as a machine that feels sluggish.

The whole thing is plain Lua coroutines with an injected clock, so the backoff curve, the
give-up threshold and the revive path are exercised by advancing a number. Nobody would
ever sit and wait thirty seconds five times over in a world, which is exactly why those are
the parts that ship broken.

## 13. Migration

- `.node.role` maps: `fleet` → `client` (plus `server` on the machine that keeps the
  state files), `controller` → `mobile`, `miner` → `miner`, `gps` → `server`.
- Existing `.mine`, `.fleet`, and job files are read by the same domain code after
  phase 1, so no data migration is needed there.
- The updater deploys by manifest and does not prune, so old module paths linger
  harmlessly on installed devices until deleted by hand.
- A device on an old build must keep working against a new server through phase 3.
  Protocol messages gain a version field in phase 1 so that stays true.
