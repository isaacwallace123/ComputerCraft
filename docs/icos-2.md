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
| **Turtle** | Any turtle | Movement, jobs, local safety | `miner` |
| **Mobile** | Pocket computer | The same views, touch-first | `controller` |

**Every one of these is a form factor, not a job**, and that is the rule the role set has
to obey. `miner` broke it. A mining turtle and a farming turtle are the same machine
running different code — the same heartbeat, the same recall, the same fuel and depot and
dead-reckoning problems, everything except which file drives the arms. Giving mining a role
of its own would have meant a second operating system differing from the first by one
`require`, and a third when somebody wanted a builder.

So what a turtle *does* is a **job**, chosen at setup and changeable from the base without
reinstalling anything, and what a turtle *is* is a turtle.

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
   os/turtle  ─────►│   no globals, no CC APIs    │  no I/O
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
    turtle/                  composition root + job runner
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
    locate.lua               (was legacy/apps/where.lua)
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

The existing capability filter in `legacy/apps.lua` already does most of this. This
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
| **Turtle** | `heartbeat` · `job` · `controls` |

Client and Mobile run exactly the same two, which is more evidence for one shared tree
(§4) rather than a copy per OS.

Two of these deserve naming. `mirror` keeps a local read-only copy of server state, so
apps render instantly and survive a brief server outage instead of showing an empty
screen. `intents` is the only thing that talks to the server about changes — which means
**a client never commands a turtle directly.** It asks the server to change desired
state, and the server owns the conversation. D019's "a handheld is never a second base"
stops being a convention and becomes a thing the structure enforces.

Today's `legacy/fleet/service.lua` is one function doing discovery, leases, policy, logging, and
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
| 5 | OS split | `os/server` absorbs fleet + gps | Medium — every device needs role migration | **server done** |
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

`domain/fleet/registry.lua` is built and specced. It is **not wired** — `legacy/fleet/service.lua`
still writes `legacy/fleet/roster.lua`, and swapping them is a base-side change that wants an
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

Still to do for phase 2: `legacy/fleet/service.lua` writing through it, and a Devices view sorted
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

### Phase 5: leases, and the server's single inbox

`os/server/services/leases.lua` is the ICOS 2 half of what `legacy/fleet/coordinator.lua` does
today, and it is the clearest illustration of §4's rule. Sector leasing used to live inside
the Fleet page, so closing the page stopped two turtles being kept out of the same shaft
(D018) — a UI decision silently became a mining collision.

**Only one loop can call `transport.receive`,** because receiving consumes. Two services
polling the same protocol would each silently eat half the fleet's traffic, and both would
look perfectly healthy doing it. So `discovery` owns the radio and everything else
registers a handler; `discovery.dispatch` returns a *list* of replies, because one message
can legitimately concern two services — a status heartbeat is a device report to
`discovery` and a lease renewal to `leases`. Which handlers exist is a composition-root
decision, so "what reads the radio" is answerable by reading one function.

**Claims are written immediately; reports are batched.** The opposite of the device
registry, and the reason is the cost of losing one. A lost report costs a few blocks of
re-counted footage and the turtle re-reports within seconds. A lost *claim* is a sector the
server has forgotten is occupied, and the next turtle to ask for work gets sent down a
shaft that already has a turtle in it. One is arithmetic; the other is two turtles in one
hole. Writing claims immediately costs nothing, because a claim happens when a turtle
finishes a sector — minutes apart — while reports arrive constantly.

`.mine` is shared with ICOS 1 rather than renamed, which is the opposite choice from
`.fleet2` and deliberate. The registry has a different shape in ICOS 2, so sharing that
name would mean a rollback reading a roster it cannot parse; the mine has the *same* shape,
so sharing the name means a rollback keeps every lease and every surveyed shaft head. Only
one server is ever running, because `startup.lua` picks one.

### Phase 5: policy, GPS, logrotate — the server is complete

**Policy** is the one that changed shape most. `legacy/fleet/policy.lua` opens by saying an
unattended system "must not turn an intentional recall into an automatic redeploy", and
enforces it by having no rule that happens to match a recalled turtle. That is not
enforcement; it is an absence any future rule can end by accident.

Desired state makes it structural: **policy never contradicts a standing goal.** It may act
when a device has no goal, or when its goal is already `deploy` and reality disagrees — the
case "it is supposed to be working and it is not". A recalled turtle has a goal of
`recall`, so every rule is unreachable for it no matter what anybody adds later.

It also stops sending commands and hoping. It sets a goal, and `reconcile` carries it — so
a recovery dropped by a radio is retried by machinery that already exists, and one that
succeeds is not re-sent. Per-device cooldowns live in the domain module because they are a
property of the rule; the one-update-per-pass limit lives in the service because it is a
property of the fleet. A rolling update that queues ten turtles at once is not rolling.

**GPS** folds the old `gps` role into the server, and gets a new port. `transport` is
rednet-shaped — ids and tables — while GPS is a raw modem exchange on a fixed channel where
the *distance the modem reports* is the payload that matters. Widening `transport` with a
channel concept exactly one caller needs would cost every null adapter and every spec; a
second narrow port costs less. The wire protocol is verified against `rom/programs/gps.lua`
and `rom/apis/gps.lua` at tag `v1.20.1-1.113.1`, not remembered.

It serves only what `locator.saved` reports and never what `locator.gps` returns. A missing
host makes `gps.locate` return nil and every caller falls back to dead reckoning; a host
announcing the *wrong* position makes it return a confident number, and a turtle that
believes it is thirty blocks from where it is drives into a wall and keeps going. Serving a
fix would also let a constellation bootstrap off its own error.

With no modem or no saved position it raises rather than parking quietly. The tempting
alternative — sleep forever, report "running" — makes the health page show green while
nothing in the world can get a fix, which is the worst of the three states.

**Logrotate** fixes a bug rather than porting one. `adapters/cc/logfile.lua` trims on open, so the one
machine that is never rebooted is the one machine whose log is never trimmed — and §2's
premise is that a server is permanently loaded. It rotates rather than truncates: when
something breaks at 3am and is noticed at 9am, the interesting lines are the first ones
after it started, and truncation keeps six hours of consequences and deletes the cause.

### Phase 5: the turtle agent, and the rolling update

`os/turtle/agent.lua` is the device half of desired state: what a turtle persists, what it
puts in a heartbeat, and what it does with what comes back. It returns an *intent* rather
than acting, so the whole of it is testable without a turtle; translating an intent into
the runtime's control flags is the composition root's job.

**It takes orders from both protocols**, and that is not laziness. It would be tidier to
handle desired state alone — but **turtles update before the base does.** The updater
deploys by manifest and a fleet upgrades a machine at a time, so there is a window where a
new turtle is talking to an old server that has never heard of desired state. A turtle that
ignored `command` in that window would ignore recall, which is a safety control.

So it takes both, and stops taking commands only when the server stops sending them — one
switch, in one place, thrown once. Acting on both is harmless for the same reason
`reconcile` can send both: every mode is a state to be in, so recall twice is recall.

The applied generation is persisted in `.desired`, its own file rather than a field in
`.node`. `.node` is written by setup and read at boot by code that predates all of this,
and the whole migration story rests on old code tolerating new files by not knowing about
them.

A missing file means generation zero, which means the next order looks new. That is the
safe direction: worst case a turtle re-applies an order it had already applied, and every
mode is idempotent precisely so that costs nothing.

### Phase 6: closing the log loop

Every service in `os/` returns what it did rather than writing it down, and every one of
them says so in a comment: a service that wrote to a log would be deciding how a machine
reports things, and on a Pocket Computer that log is somewhere else. That was right, and it
left a hole — **nothing in ICOS 2 could log**, so `logrotate` was rotating a file nobody
wrote.

`ports/log.lua` is the other end. The composition root takes what its services returned and
records it, which puts the one decision — *what is worth writing down* — in the file that
already knows what kind of machine it is. Only failures, and only through the supervisor's
`onError` hook: a boot that logged every service starting would put seven lines in the file
every time a base station reloads a chunk, and the log's whole value is that its lines are
worth reading. The first failure is a **warning** and the rest are errors, because a service
that fails once and restarts is ordinary — a radio going out of range does it — and a machine
that shouted about every one would train somebody to skip the shouting.

The CC adapter wraps `adapters/cc/logfile.lua` rather than replacing it. Reimplementing would give
ICOS 2 a *second* log — a second file, a second tail, and an ICOS 1 console that goes quiet
the moment a machine is upgraded. During a rolling update both operating systems are running
somewhere in the fleet, and a log with everything in it is exactly what a person needs then.

**A real bug, caught by a spec on the adapter's first day.** The port declares its levels
lowercase; `adapters/cc/logfile.lua` writes them upper-case; the adapter recovered the level from the
formatted line and returned it raw. So the Logs page compared `"WARN"` against `"warn"`,
found no warnings, and its warnings-only filter showed an **empty screen while warnings were
arriving** — the worst possible failure for a diagnostic page, because it looks like good
news. `log.level` now owns the vocabulary and everything else asks it.

The Logs page itself breaks one house rule deliberately: **newest last.** Every other list
puts the interesting thing first — Devices by staleness, Services by failure — but a log is
a *sequence*, and reading a sequence backwards means reading every consequence before its
cause. It reads the in-memory tail rather than the file, so a machine whose disk is full
still has a log on screen, which is precisely when somebody is looking at one.

It reaches the turtle's launcher too, and that is where it matters most: `edit .log` on a
machine with thirteen rows whose program is still running is not a thing anybody does at 2am.

### Phase 6: the Services page, and what surface filtering buys

The supervisor's comments have referred to "the Services page" since it was written. It
exists now, and it is the diagnostic surface for everything else: when a turtle will not
deploy, or a client shows nothing, or GPS is down, this is the page that says which loop is
failing and what it said.

**It reads a supervisor, not a fleet.** Every other app reads the mirror; this one reads
`context.supervisor`, which is *this machine's own*. The moment somebody needs this page is
the moment the radio might be the broken thing, and a services page that had to ask the
server what it was running would be useless in exactly the case it exists for.

**Three states, and the middle one matters most.** `running` is boring, `gave up` is
obvious, and **`waiting`** — a service failing and backing off — looks like nothing on every
other screen and is the state a machine spends its time in while a person walks over to look
at it. So it reads "retrying 8s", because 8s and 30s are different situations. The
supervisor calls it `waiting` and the page calls it retrying; the internal word is accurate
and the displayed one is useful, and they are allowed to differ.

**A degraded machine is still healthy, and the page says both.** A client that cannot reach
its server still draws, so `healthy()` is true with a red row on screen — and somebody
reading that needs to be told why both are true, or they conclude the page is lying. A
non-critical failure is amber, not red: painting a degraded client the same colour as a dead
turtle trains somebody to ignore both.

**It counts restarts, not failures.** `failures` resets to zero the moment a service comes
back, so a service that has crashed forty times today and is up right now shows zero — true
and useless.

Then the payoff for filtering apps by *surface* rather than by machine. The turtle's
`controls` service was still a stub; it now runs the same shell with
`surface = "launcher"` — and the Services page, which is exactly what somebody standing in
front of a stopped turtle wants because it says `job: gave up — bedrock`, needed no turtle
version written for it. It declared the surface and appeared. Devices deliberately did not:
a turtle showing a fleet roster would be drawing something it has no copy of.

### Phase 6: the desktop shell

`client.boot` took a `draw` and nothing provided one, so a client booted with two services
one of which did nothing — and the supervisor was right to call that running.
`os/client/shell.lua` is that function: the composition root for the *screen*, in the same
way `main.lua` is the composition root for the machine.

**Two event loops that turn out to be one.** `ui/host.lua` runs its own loop pulling from
the input port, and the supervisor runs its own loop resuming coroutines. That reads like a
collision and is not: the input port's `pull` is `os.pullEvent`, which is `coroutine.yield`
with a filter, so a supervised `host.run` parks on exactly the yield the supervisor is built
to resume. `boot.run` pulls the event, the supervisor hands it to the coroutine, and
`host.run` receives it as the return value of its own `pull`. Nothing had to change on
either side — the supervisor's filter honouring was written for this and it worked first
time.

**Switching apps destroys the one that was open**, rather than hiding it. The alternative is
ten pages of `Computed` recalculating on every heartbeat so that nine of them can be
invisible, and `reactive.live()` exists precisely to catch that — the shell being the most
likely place to leak it, so it has a spec that asserts the count returns to where it started.

**The taskbar is text, not buttons**, and that is D020 rather than laziness. A wall monitor
has no keyboard and no mouse, so a row of buttons there is a row of things that cannot be
pressed. The same row on a desktop tells somebody which key to press.

Which apps appear is filtered by role *and* surface, so a Pocket Computer and a wall monitor
run identical code and disagree only about what they are. `mobile.boot` fills in
`role = "mobile"`, `surface = "handheld"` itself rather than requiring the caller to — a
mobile that had to be told it was mobile is a mobile that works until somebody forgets.

The shell is required *inside* `client.boot`'s default rather than at the top of the file.
That is the one deliberate piece of laziness: requiring it pulls in the whole UI framework
and every app it lists, and a headless client — which is what every sync test is — would pay
for a screen it never opens.

### Phase 6: the first real app

`apps/devices/view.lua` was already built on the framework — it is §14's acceptance test.
What it lacked was the other half: `apps/devices/app.lua`, the composition root that turns
a function-from-state-to-nodes into something you can open.

The split is §4's rule made concrete. **Services own state, apps read it.** This app holds
no roster, opens no radio of its own, and coordinates nothing: it reads `context.state.fleet`,
which the client's `sync` service keeps fresh, and it writes by *asking the server*. D018 is
why — sector leasing used to live inside the Fleet page, so closing the page stopped two
turtles being kept out of the same shaft. An app that is closed, crashed, or was never
opened must change nothing, and the only way to guarantee that is for it to own nothing.

**Actions are goals, not commands.** Deploy does not send "deploy"; it asks the server to
*want* the device deployed, and `reconcile` keeps saying so until the device agrees. A press
dropped by a radio is retried without the person who pressed it knowing — which is why the
page has no "sent" state to display, because "sent" was never the honest word for it.
Pressing the same button twice returns `ok` with `changed = false`: reporting it as a
failure would make a second click on Recall look like something went wrong when the correct
answer is "it is already recalled".

**A device the server has never heard of is refused, not invented.** The registry is built
from heartbeats, and creating an entry from a click would put a device on the page that does
not exist — destroying the one distinction §6 exists to preserve, between "there is no
miner-7" and "we do not know where miner-7 is".

**A quiet device does not claim to still be mining.** `phase` comes from the last snapshot,
and a snapshot is a fact about when it was sent. An offline device reads `offline`, because
"mining" on a device nobody has heard from in twenty minutes is a claim the server cannot
support and is exactly how a dashboard misleads somebody at 2am.

The job picker now reads the catalogue instead of a hard-coded list that carried a comment
admitting it was a copy. A picker offering a job no turtle has produces a refusal somebody
has to interpret, and it happened every time a job was added and the copy was not.

There is no authentication on `want`, and there cannot be: CC has no way for one computer to
prove who it is, and a shared secret in a file every device holds is not a secret. This is
the same exposure ICOS 1 has today with `command`, bounded the same way — the modem is in a
base nobody else can reach. Stated rather than left as an assumption somebody discovers.

### Phase 5: the job catalogue

The rename made a second problem visible. ICOS 1 kept jobs as a table built at the
entrypoint, keyed by name, whose values were the modules themselves — fine while every
turtle mined, and broken the moment one does not.

**The base cannot see the list.** A console offering "which job?" had to hard-code the
names or ask a turtle, and a turtle down a shaft cannot answer. So `domain/turtle/jobs.lua`
is data, and both ends of the radio read the same file. `module` is a *string*, resolved by
the turtle when it starts work — which is what lets a server with no `turtle` global at all
list, validate and assign jobs it could not itself run. A base that had to `require`
`jobs/mining/quarry.lua` to know a quarry exists is a base that crashes on `turtle.dig` being nil.

**Nothing declared what a job needs.** A farming turtle wants a hoe; a quarry wants a
pickaxe and a lot of fuel; a fuel hunt wants neither — and notably **not a modem**, because
a fuel hunt is the job a turtle does *because* something has gone wrong, and requiring the
base for it would mean a fleet that cannot refuel itself once the base is unreachable.

Two of the four capabilities can be observed and two cannot, and the catalogue says so
rather than pretending otherwise. Fuel is a number; a modem answers or does not. `dig` and
`place` a turtle *cannot* check: `turtle.dig` with no tool and `turtle.dig` with nothing in
front both return false, so telling them apart means breaking a block to ask a question, and
a capability check that damages the world to run is worse than the problem it detects. Those
two are a declaration for the person — setup says what a job needs before they choose it —
and the runtime still discovers the truth the first time it digs, parks, and reports why.

A job the machine cannot run is **still selected**, and reported as unrunnable rather than
silently swapped. A turtle that quietly started fuel-hunting because its pickaxe fell out is
a turtle nobody can diagnose from the base; one reporting "quarry — needs a tool equipped
that can break blocks" is one somebody fixes in ten seconds.

Adding a job is one entry and one module. Setup offers whatever the catalogue lists, the
base assigns from the same list, and the turtle resolves `module` when it starts.

### Phase 5: booting it, without changing what a machine does on power-up

`os/kernel/boot.lua` is the one file in ICOS 2 allowed to know both that CC exists and that there
are four operating systems. Everything below it knows one or the other and never both,
which is what makes the tree testable: `domain/` knows neither, `ports/` and `os/` know the
shape without the implementation, `adapters/cc/` knows CC without knowing what anybody does
with it.

**The event loop is here, not in the supervisor.** `Supervisor:step(event)` resumes services
and returns; a supervisor that pulled events could not be driven by a spec. So the
`os.pullEventRaw` loop lives in the file already allowed to name CC globals, and the
supervisor stays a pure state machine over coroutines. `pullEventRaw` rather than
`pullEvent`, so terminate reaches the services and they are stopped in order rather than
having the loop pulled out from under them.

The loop stops on three things: terminate, the turtle's `halt` flag — checked here because
stopping is the one thing a service cannot do to itself, since a coroutine that returns is
a fault — and **every service having given up**. That last check is `running() == 0` rather
than `healthy()`, and the reason is worth stating: both of a client's services are
non-critical, correctly, so a client that has lost both its server and its monitor reports
*healthy* while doing nothing at all. Only the running count catches it.

`serialise` finally became a real port. Every service had been using `ports.serialise` since
phase 4 and it had no definition and no adapter — the composition roots could not have been
wired without it. `decode` never raises, because a caller reading a file it did not write
(which is every caller: a previous version, a previous build, a crash mid-write) must be
able to ask "is this a table?" without a `pcall`. `encode` does raise, because a value that
cannot be serialised is a bug in the caller, and a silent failure there is a file that
quietly stops updating and is discovered weeks later.

`src/icos2.lua` runs a machine by hand. `startup.lua` still boots ICOS 1 — switching it over
alters what a live fleet does when the chunk loads and is the last change to make. Until
then, `icos2` in a test world makes the machine an ICOS 2 machine until Ctrl-T, writing
nothing ICOS 1 reads, so a reboot puts it back. `icos2 status` builds the machine, steps it
once and prints its health: the interesting failures are all in the wiring, and a status
command that read a file would report a healthy machine that cannot start.

### Phase 5: the client and the mobile

`os/client/main.lua` is the other half of the `fleet` split. A client has a screen and a
copy of what the server knows; it coordinates nothing, leases nothing and decides nothing —
which is the whole reason the role was split, because one machine was drawing the fleet
*and* being the fleet, so closing a page stopped the coordination behind it (D018).

**Its copy is always out of date, and that is the honest shape** rather than a compromise:
the server's copy is a few seconds behind the turtles too. What the mirror carries is the
*age* of every record, so a stale row can say so. A client that silently showed
twenty-minute-old positions as current would hide exactly the fact §6 exists to surface.

The mirror is a request-reply, not a subscription — a subscription means the server keeping
a list of who is listening, and a list of listeners on machines that reboot goes stale and
gets written to forever. It replaces rather than merges, because "this turtle no longer
exists" is a fact a dashboard must not quietly discard. And it is **not** persisted: a
mirror that survived a reboot would show a fleet as it was whenever the machine was last
on, which on a monitor in a corner could be days.

`os/mobile/main.lua` is deliberately thin, because a Pocket Computer is structurally a
client. Three things are actually different:

- **It goes out of range routinely.** A monitor either reaches the server or has a broken
  modem; a handheld in somebody's inventory is out of range every time they walk into a
  cave, and coming back is the normal case. So the sync interval backs off while it is
  failing — its own backoff, not the supervisor's, because that one is for a service that
  is *broken* and counts towards giving up. A handheld that reported unhealthy for walking
  into a cave would be reporting the world rather than itself.
- **Its screen is 26x20**, which is a different layout rather than a smaller one. The page
  decides; the composition root does not know.
- **It is the machine somebody is holding when something has gone wrong**, so mirror
  staleness matters more here than anywhere: showing a twenty-minute-old position as
  current sends a person to the wrong place.

What is *not* different, and was tempting: it gets no authority for being the thing you are
holding. A pocket computer that could lease sectors would be a coordinator that walks out
of range, and D018 is precisely the lesson that coordination must not live somewhere that
can disappear.

### Phase 5: the turtle's composition root, and the `waitForAny` bug

`legacy/apps/miner.lua` runs four coroutines under `parallel.waitForAny`, which returns when
**any** of them finishes. So a heartbeat loop that throws on a missing modem takes the
mining job down with it, and a turtle halfway down a shaft stops — not because mining
failed, but because *talking about* mining failed. D004 says job correctness may never
depend on a message arriving, and `waitForAny` is a direct contradiction of it sitting in
the entrypoint.

`os/turtle/main.lua` supervises instead. The radio backs off and retries while the job
carries on, and the health model says the honest thing in both directions: `heartbeat` is
**not** critical, because a turtle that cannot reach the base is still working; `job`
**is**, because a turtle that has stopped working is a box standing still and should not
report green.

Nothing in that file knows what the turtle is *for*. `context.runJob` is whatever the node
selected, and a farming turtle registers exactly the same three services with a different
function behind one of them.

It runs the ICOS 1 job code unchanged. `legacy/miner/runtime.lua` is what actually drives a
turtle, it is proven, and the fleet is running it — rewriting it in the same change that
rewrites supervision and orders would put a fleet in a hole with two untested halves. So
`os/turtle/control.lua` writes the `ctx.control` flags the existing runtime already reads,
and from the runtime's point of view nothing happened. Its eventual replacement is a job
module like any other, which is the point of not calling that directory `miner`.

Heartbeat and orders are **one** loop, unlike ICOS 1's two. The exchange is a request and
its reply; splitting it meant a turtle whose receive loop had died kept reporting cheerfully
while ignoring every order — which looks identical, from the base, to a turtle that is fine.

The interesting behavioural change is what happens to an order a turtle cannot carry out
yet. ICOS 1 replied "recall this turtle first" and dropped it, so setting a job on a running
turtle produced a message and nothing else. Under desired state the goal stays on the
server, the turtle keeps reporting a generation it has not applied, and the Devices page
shows it as pending. The order is not lost — it is waiting. Nothing in the turtle OS has to
do anything for that to be true, which is the point of §5.

### Phase 5: reconcile, persist, and the dual run

Three of the server's seven services are built: `discovery`, `reconcile` and `persist`.

**`reconcile` is where §12's dual run lives.** Desired state is a pull model, and a pull
model is already correct — a device reconciles on its next heartbeat and every property in
§5 holds. The nudge is *latency*, not correctness, which is why it may fail silently and
why nothing depends on it arriving.

Each nudge carries **both** the desired-state reply and the ICOS 1 `command`. A turtle on
the old build obeys the command and never reports an applied generation; one on the new
build applies the generation and converges. Both are correct at once, so the fleet upgrades
a turtle at a time. Sending both is only safe because every mode is *a state to be in*
rather than an action to perform: recall twice is recall, and deploy on a running turtle is
refused by the turtle.

`context.events = false` ends the dual run. **That switch is not this project's to throw** —
§12 says both paths run until the dashboard shows every device converging, and that is a
judgement made by looking at a real fleet.

**`persist`'s actual job is not writing.** Ten turtles at one heartbeat every two seconds is
five disk writes a second, and a CC write is a real file operation on the host. So the
registry is batched and the drop-off list is not — and the test for which is not importance
but whether anything else in the world holds a copy. A registry is rebuilt by the devices
themselves within a minute; a drop-off list exists nowhere but that disk.

`persist` is **critical** and `reconcile` is not. A server that has stopped writing looks
perfectly healthy right up until it reboots, at which point it has forgotten where every
missing turtle was — which is the one thing §6 exists to remember. A server whose reconcile
has died still records heartbeats and still answers devices that ask, so the fleet
converges, just less promptly; marking that critical would take a whole machine down over a
latency problem.

### Phase 5: roles, the server, and the first wired service

`os/kernel/roles.lua`, `os/server/main.lua` and `os/server/services/discovery.lua` join the
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

`os/kernel/supervisor.lua` and `os/kernel/service.lua` are built and specced. The four composition roots
are not.

The supervisor exists because of one sentence of CC semantics: **`parallel.waitForAny`
returns when *any* coroutine finishes.** So today an error escaping `legacy/fleet/service.lua`
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
  state files), `controller` → `mobile`, `miner` → `turtle`, `gps` → `server`.
- `miner` → `turtle` is the migration that actually runs on ten machines, since every
  turtle in the live fleet is set up as a miner. It renames the role and leaves the job
  alone, because mining was always the job — the record already carries `job = "quarry"`
  or whatever was selected, and nothing about it changes.
- Existing `.mine`, `.fleet`, and job files are read by the same domain code after
  phase 1, so no data migration is needed there.
- The updater deploys by manifest and does not prune, so old module paths linger
  harmlessly on installed devices until deleted by hand.
- A device on an old build must keep working against a new server through phase 3.
  Protocol messages gain a version field in phase 1 so that stays true.
