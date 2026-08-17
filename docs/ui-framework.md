# ICOS 2 — UI framework plan

A plan for the rendering and component layer ICOS 2 is built on. Nothing here is built.

Companion to [`docs/icos-2.md`](icos-2.md), which covers the OS split and the service
model. This covers everything a person actually looks at.

---

## 1. Why

The current UI is `ui.text(x, y, text, colour)` and hand-computed coordinates. That has
three costs, all of which have already been paid:

- **Layout is arithmetic.** Every column width, every scroll offset, every "does this fit
  on a pocket computer" branch is written by hand at the call site. `ui.pad` exists
  because Lua has no `%-*s`.
- **Redraw is all-or-nothing.** Every repaint clears the screen and paints it again,
  which is why the monitor blinked until `ui.frame` double-buffered it. Nothing knows
  what changed, so nothing can update just that.
- **Animation is impossible.** Not hard — impossible. There is no frame loop, no time
  source in the draw path, and no way to redraw one region without redrawing all of it.

A framework fixes the third by fixing the first two.

---

## 2. What the hardware actually gives us

Design has to start here, because half of the interesting decisions are forced by it.
**Verify each of these against the CC: Tweaked docs before relying on it** — this is from
experience, not from the source.

| Constraint | Consequence |
| --- | --- |
| The screen is a character grid, ~51×19 on a computer, up to ~164×81 on a large monitor at scale 0.5 | Layout is integer cells. No subpixel positioning at the widget level. |
| 16 colours on screen — but `term.setPaletteColor` redefines all 16 to arbitrary RGB on advanced hardware | A real palette is possible. Sixteen *chosen* colours, not sixteen given ones. |
| `term.blit(text, fg, bg)` writes a run with per-character colours in one call | The renderer must batch into runs. Per-character `setTextColor` + `write` is the slow path. |
| The font has 2×3 block characters (codes 128–159) | An effective pixel grid of ~102×57, up to ~328×243. This is how cards and images get drawn. |
| The game runs at 20 ticks/second; `sleep(0.05)` is one tick | **20 FPS is the hard ceiling.** Design animation for 10–15. |
| Cooperative multitasking, no preemption | The frame loop is a coroutine that yields. A slow render starves input. |
| `window` objects buffer and flush on `setVisible` | Tear-free presentation already exists; use it rather than inventing one. |

The 20 FPS ceiling is the important one. It rules out anything that needs smooth motion
and rules *in* deliberate, snappy, well-eased transitions of 150–300ms. The aesthetic has
to be chosen to suit that, not fight it.

---

## 3. Fusion, not React

The model is [Fusion](https://elttob.uk/Fusion/) — the Roblox library — rather than
React. That is not a vocabulary preference. The two have genuinely different
architectures, and Fusion's is the better fit here for reasons that matter on a machine
with a tick budget.

**React re-runs components and diffs the result.** State changes, the component function
runs again, the output is compared to last time, the differences are applied.

**Fusion binds state directly to properties.** State changes, the one property bound to
it updates. The component function never runs again. There is no re-render and nothing to
diff at the tree level, because the framework already knows exactly what changed.

Four consequences, all of which improve this design:

- **Less CPU per update.** A fuel reading ticking over updates one bar and one label, and
  executes no component code at all. On a server that is also reconciling ten turtles,
  that is the difference between an idle dashboard being free and being a tax.
- **Precise invalidation.** Because the binding knows *which property* changed, it knows
  whether layout has to be re-solved. A colour change repaints; only a size or text
  change re-runs the layout solver. React's model cannot make that distinction.
- **Animation stops being special.** In Fusion a `Spring` is just a state object that
  moves towards a goal. Anything that can consume a value can consume an animated one, so
  animating a colour requires no different code from setting it. §8 is short as a result.
- **No rules of hooks.** Hook ordering was a flagged risk in the React version of this
  plan — no linter catches a conditional `useState`, and Lua has no JSX-era tooling to
  help. Fusion has no hooks, so the whole class of bug is gone rather than mitigated.

Lua is also simply the right shape for it. Fusion is Luau, uses `:get()`/`:set()` and
table-of-properties construction, and reads like Lua rather than like JavaScript wearing
a Lua costume.

**What the cell diff is still for.** Diffing the cell buffer stays, but its job changes.
It is no longer how the framework detects change — the bindings do that — it is how many
small updates in one frame get batched into as few `term.blit` calls as possible. Twenty
values changing across the screen still present as one coalesced frame.

**Working name: Facet.** A mining word, and each bound property is one. Rename freely.

---

## 4. Architecture

```
  apps/*                      screens built from components
      │
  ui/components/              Button, List, Table, Modal, Sparkline, …
      │
  ┌───┴────────────────────────────────────────────┐
  │  ui/reactive     Value, Computed, Spring, …    │
  │  ui/runtime      retained tree, dirty queue    │
  │  ui/layout       flex solver → boxes           │
  │  ui/anim         tweens, easing, timelines     │
  │  ui/input        hit-testing, focus, gestures  │
  │  ui/theme        palette + semantic tokens     │
  └───┬────────────────────────────────────────────┘
      │
  ui/buffer                   cell grid + dirty diff + run batching
  ui/canvas                   2×3 subpixel drawing onto a buffer
      │
  ports/screen                the only thing that touches `term`
```

`ports/screen` matters: it is what lets the whole framework render into a recording
buffer in the spec suite. **A layout bug becomes a unit test** — assert the cells, no
Minecraft required. That has never been possible here.

---

## 5. Rendering

### The buffer

A cell grid of `{ char, fg, bg }`, double-buffered. Components paint into the back
buffer with no knowledge of what is already on screen.

On present:

1. Walk rows; skip any row whose cells are identical to the front buffer.
2. Within a changed row, find contiguous runs sharing nothing but position.
3. Emit one `term.blit` per run.
4. Swap buffers.

An idle screen costs one comparison pass and zero terminal calls. A blinking cursor costs
one `blit` of one character. This is the entire reason animation becomes affordable.

### The canvas

`ui/canvas` draws into the same buffer at 2×3 resolution using the block glyphs, exposing
`setPixel`, `line`, `rect`, `circle`, `sprite`, and `image`. A `Canvas` component gives
any region of the UI a pixel surface — used for card faces, the ICOS logo, sparklines
that want to be curves rather than bars.

Sprites are authored as a simple indexed-colour format checked into the repo, not
generated at runtime.

---

## 6. Layout

A small flexbox subset, solved top-down into integer cell rectangles:

- `direction` row | column, `gap`, `padding`
- `grow` / `shrink` / `basis`
- `align` and `justify`: start | center | end | between
- `absolute` for overlays
- intrinsic sizing for text, so a label measures itself

Integer-only, with a documented rounding rule (distribute remainder to the leftmost
growing children) so a three-column split of 51 cells is deterministic rather than
drifting by one between renders.

Explicitly **not** included: grid, wrapping, percentage units. They can be added; none of
them is needed for a dashboard or a card table.

---

## 7. Reactive primitives

The Fusion vocabulary, adapted. Roblox has a retained scene graph of Instances to bind
against; we do not, so `New` builds nodes in a retained tree of our own, and those nodes
are what the layout solver and painter walk.

| Primitive | Purpose |
| --- | --- |
| `Value(v)` | mutable state. `:get()`, `:set(v)` |
| `Computed(fn)` | derived state; dependencies declared with an explicit `use` |
| `Observer(state)` | run a side effect when a state changes |
| `Spring(goal, speed, damping)` | state that physically follows a goal |
| `Tween(goal, info)` | state that eases to a goal over a duration |
| `ForPairs` / `ForValues` | reactive lists, with per-item scopes |
| `New "Kind" { … }` | construct a node; any property may be a state object |
| `Children`, `OnEvent`, `Out` | special keys, as in Fusion |
| `scoped()` | lifetime; closing an app destroys its scope and every binding in it |

Dependency tracking is **explicit** (`Computed(function(use) … end)`), following Fusion
0.3 rather than 0.2's implicit capture. Less magic, far easier to implement correctly in
plain Lua, and the dependency set is readable at the call site.

```lua
local scope = facet.scoped()

local fuel  = scope:Value(51000)
local low   = scope:Computed(function(use) return use(fuel) < 800 end)
local tint  = scope:Spring(scope:Computed(function(use)
  return use(low) and theme.bad or theme.good
end), 20, 0.9)

scope:New "Row" {
  Gap = 1,
  Children = {
    scope:New "Text" { Text = "fuel", Color = theme.muted },
    scope:New "Bar"  { Grow = 1, Value = fraction, Tint = tint },
    scope:New "Text" {
      Width = 6, Align = "right",
      Text = scope:Computed(function(use) return util.count(use(fuel)) end),
    },
  },
}
```

`fuel:set(50999)` updates the bar's fill and six characters of text. No function in that
block runs again except the one `Computed` that formats the number.

### Scheduling and coalescing

Bindings do not paint immediately, which is the detail that makes this fast:

1. A `:set()` marks each dependent node **paint-dirty** or **layout-dirty**, by property.
2. Dirty nodes go on a queue; a frame is scheduled if one is not already pending.
3. On the frame: re-solve layout **only if** something layout-dirty exists, paint dirty
   regions into the back buffer, diff, blit, present.

So a service handler that updates twenty values produces **one** frame, not twenty. This
is a hard requirement — without coalescing, fine-grained reactivity is slower than
re-rendering, not faster.

### The join to the OS

`scope:Store(service, selector)` subscribes to a service's state. This is where §8 of
[`icos-2.md`](icos-2.md) lands: services own state, apps read it, and a component that
reads `devices` re-binds when discovery updates it — without the app polling and without
the service knowing any app exists.

### Component library

Layout: `Row`, `Column`, `Box`, `Spacer`, `ScrollView`, `Modal`, `Tabs`.
Data: `Text`, `Table`, `List`, `Bar`, `Sparkline`, `Gauge`, `Badge`, `KeyValue`.
Input: `Button`, `Toggle`, `Stepper`, `TextField`, `Menu`, `Slider`.
Feedback: `Toast`, `Spinner`, `Skeleton`, `Empty`, `Banner`.
Graphics: `Canvas`, `Sprite`, `Logo`.

---

## 8. Animation

Short, because §7 already did the work. `Spring` and `Tween` are state objects, so
anything that accepts a value accepts an animated one. There is no separate animation
API, no `animate()` call, and no imperative timeline for the common case.

```lua
Width = scope:Spring(scope:Computed(function(use)
  return use(selected) and 24 or 12
end), 25, 1)
```

That is the whole of it. The spring re-targets whenever its goal changes, including
mid-flight.

- Easings for `Tween`: `linear`, `easeOut`, `easeInOut`, `back`.
- `Spring(goal, speed, damping)` for anything interruptible — selection, resizing,
  anything a person can change their mind about halfway through.
- Sequencing (deal, deal, flip) uses staggered goals or an explicit timeline helper; only
  the game needs it.
- Mount and unmount transitions so a list insert slides rather than appears.

**A spring that has settled unschedules itself.** The frame loop runs only while at least
one animation is in flight; an idle screen is purely event-driven and costs nothing. On a
server that is also reconciling a fleet, this is a hard requirement, not an optimisation.

Motion budget, given 20 FPS: 150ms for state feedback, 250–300ms for transitions, nothing
continuous except a deliberate pulse on an alert. Long or elaborate motion reads as jank
at this frame rate — restraint here is a technical requirement, not taste.

---

## 9. Input

One normalised event model over `key`, `char`, `mouse_click`, `mouse_drag`,
`mouse_scroll`, `mouse_up`, `monitor_touch`, `paste`, `term_resize`.

- Hit-testing walks the laid-out tree, topmost first.
- Focus ring with tab order; every focusable component has a visible focused state.
- A monitor touch is a click with no hover and no drag — components must not depend on
  hover for anything essential. The display-only rule (`requiresInput`) stays exactly as
  it is.
- Gestures: tap, drag, scroll. Long-press deliberately omitted; it is undiscoverable on a
  monitor.

---

## 10. Surfaces beyond the screen

Advanced Peripherals adds no new display hardware, but it adds three things that are
genuinely part of the interface, and treating them as ports rather than one-off calls is
what makes them usable from an app.

**Confirm each against the Advanced Peripherals docs before building on it.**

| Peripheral | Port | What it gives the UI |
| --- | --- | --- |
| Chat Box | `ports/chat` | Notifications that reach you anywhere. `miner-7 parked: no cap block` in chat beats a red row on a monitor you are not standing in front of. |
| Player Detector | `ports/presence` | Who is nearby, and how near. A wall can show the summary at distance and detail when someone walks up. |
| Inventory Manager | `ports/carried` | Read and move the player's own inventory — refuel a turtle, take the haul, without opening a chest. |

Presence is the interesting one. A monitor that shows a dense table nobody is close
enough to read is wasted; the same monitor can show three large numbers at ten blocks and
the full fleet table at two. That is a real use of reactivity — `distance` is just
another state object, and the layout is `Computed` from it.

Chat matters for a different reason. Every failure mode built so far — an unsealable
shaft head, a full depot, a turtle that gave up after four barren cycles — currently
waits for someone to look at a screen. A chat line is the only channel that finds the
player. It should be a service on the Server, driven by the same state the dashboard
reads, with a severity threshold so it is not noise.

None of this is required for the framework to ship. It is the argument for why the ports
layer is worth having: adding a chat notifier should not mean touching any app.

## 11. Theming

`term.setPaletteColor` gives sixteen arbitrary RGB slots on advanced hardware. Budget:

- 6 neutrals (ground, surface, raised, border, muted text, text)
- 1 accent + 1 accent-dim
- 4 semantic (good, warn, bad, info)
- 4 free for the current app — cards, charts, a game

Components reference **semantic tokens** (`surface`, `muted`, `bad`), never raw colour
indices, so a theme swap is data. Standard (non-advanced) hardware falls back to the
fixed 16 with a documented mapping, and monochrome hardware to two.

Light and dark are two token sets. Contrast has to be checked on a real monitor — CC's
palette is rendered at a size where subtle neutrals disappear.

---

## 12. Performance budget

Explicit targets, verified by a bench in the spec suite:

| Metric | Budget |
| --- | --- |
| Idle screen | 0 terminal calls, < 1ms comparison pass |
| Typical dashboard update | < 40 `blit` calls |
| Full-screen change, 164×81 | one frame (50ms) |
| Frame loop while animating | 10–15 FPS sustained, no starved input |

If the diff cannot repaint a large monitor inside one tick, the framework has failed at
the thing it exists for. Measure it in phase 1, not at the end.

---

## 13. The showcase: Blackjack

Chosen because it exercises nearly every layer, not because it is a card game:

| Framework feature | How Blackjack uses it |
| --- | --- |
| `ui/canvas` + sprites | card faces at 2×3 resolution |
| Timelines | dealing, one card at a time, with a flip |
| Transitions | chips sliding to the pot, cards clearing |
| `Stepper` / `Button` | betting controls |
| `Modal` / `Toast` | blackjack, bust, insurance offers |
| Theme slots | felt, card, chip colours from the 4 free slots |
| `useStore` + storage port | a bankroll that survives a reboot |
| Input | mouse on a monitor, keys on a terminal, touch on a pocket |
| The diff renderer | a full table redrawn at 15 FPS without flicker |

It is also a **soak test with a scoreboard**: if a hand of blackjack animates cleanly on
a wall monitor while the server reconciles ten turtles, the framework is fast enough for
anything the fleet UI will ask of it.

Ships as an app on Client and Mobile, `os = { "client", "mobile" }`, `requiresInput` true.
Not on Server, and not on a turtle.

---

## 14. Phasing

| # | Phase | Delivers |
| --- | --- | --- |
| 1 | `ports/screen`, `ui/buffer`, diff + blit, bench | Flicker-free painting, measured |
| 2 | `ui/reactive` + `ui/layout` + `ui/runtime` + core components | Rebuild one existing app (Devices) on it |
| 3 | `ui/input`, focus, gestures | Full interaction parity with today |
| 4 | `Spring` / `Tween` + transitions | Motion, frame loop gated on activity |
| 5 | `ui/canvas` + sprites + theming | Imagery and real palettes |
| 6 | Blackjack | Showcase and soak test |
| 7 | Port remaining apps, add AP ports | Old `core/ui.lua` deleted; chat notifications |

Phase 2 rebuilding **Devices specifically** is deliberate: it is the densest existing
screen, with a list, a detail view, a settings editor, and scrolling. If it does not come
out simpler than the current version, the framework is not earning its place and the plan
should be revisited before phase 3.

---

## 15. Risks

- **Performance is the whole bet.** If the diff cannot repaint a large monitor in a tick,
  none of the rest matters. Benched in phase 1 for exactly that reason.
- **Leaks, which is the price of fine-grained reactivity.** React's model cleans up by
  virtue of re-rendering; a binding graph does not. Every `Computed`, `Observer`, and
  `Spring` holds a reference until its scope is destroyed, and a component that
  subscribes to a service and is never torn down keeps that service's updates flowing
  into dead nodes forever. `scoped()` is not optional decoration — it is the whole
  lifetime story, and closing an app must destroy its scope. Worth a dev-mode counter of
  live bindings so a leak shows up as a number rather than as a slow machine.
- **Cyclic dependencies.** `Computed` graphs can be made to depend on themselves. Detect
  it during evaluation and fail loudly with the cycle named, rather than hanging.
- **Scope.** A component library is a bottomless pit. The list in §7 is the whole of it
  for ICOS 2; anything else waits for a second app that needs it.
- **Two rendering models.** Cell components and pixel canvas can look inconsistent if
  mixed carelessly. Canvas is for content, never for chrome.
- **This is a large rewrite of everything visible**, running in parallel with the OS
  split. They should not land together — UI phases 1–3 can proceed while the OS work is
  in its own phases, but one of them goes to the live fleet at a time.

---

## Appendix — kickoff prompt

Phase 1 of this plan and phase 1 of [`icos-2.md`](icos-2.md) are the same work: both
establish `ports/` and `adapters/`, neither changes live behaviour, and the bench proves
the renderer premise before anything is built on it. One session covers both.

Paste into a fresh chat.

```text
Work in C:\Users\isaac\Desktop\ComputerCraft — ICOS, a fleet operating system for
CC: Tweaked (Minecraft 1.20.1, Valhelsia 6). A live 10-turtle mining fleet is
running the current release. Nothing this session does may change its behaviour.

We are starting ICOS 2. Read these completely before writing anything:

  AGENTS.md
  docs/ai-handoff.md        conventions, invariants, verification commands
  docs/architecture.md      what exists today
  docs/decisions.md         D001-D026: why things are the way they are
  docs/icos-2.md            the OS split, services, desired state     <- the plan
  docs/ui-framework.md      the UI framework                          <- the plan
  src/core/ui.lua           what the UI framework replaces
  tools/spec/               the existing simulated-world spec suite

The UI framework is modelled on Fusion (the Roblox library), NOT React. State
objects bind directly to node properties and components never re-run. Read
section 3 of docs/ui-framework.md carefully, and Fusion's own docs if you do
not already know it.

## This session: the foundation

Phase 1 of both plans, because they are the same work — establish ports and
adapters, and prove the renderer's performance premise before anything is
built on top of it.

Deliver:

1. src/ports/ — interface definitions with null implementations: clock,
   storage, transport, screen, body, locator. Tables of functions. No classes,
   no inheritance, no metatable trickery.

2. src/adapters/cc/ — real implementations over fs, rednet, term, turtle, gps.
   src/adapters/sim/ — promote tools/spec/support/world.lua to a first-class
   adapter rather than a monkey-patch over _G.
   Nothing outside adapters/cc may reference a CC global.

3. src/domain/mine/ — move mine/plan.lua and mine/registry.lua, which are
   already nearly pure arithmetic. No logic changes. The existing specs must
   pass unmodified; that is the proof the move was clean.

4. src/ui/buffer.lua — double-buffered cell grid of {char, fg, bg}. present()
   diffs against the front buffer and emits one term.blit per contiguous
   changed run, through ports/screen.

5. Specs against the recording screen adapter: an unchanged frame emits zero
   terminal calls; a one-character change emits exactly one blit; a
   full-screen change emits at most one blit per row. Assert cell contents
   directly.

6. A bench reporting blit count and elapsed time for three cases: idle, a
   typical dashboard update, and a full 164x81 repaint. Write the measured
   numbers into docs/ui-framework.md section 12.

## Out of scope this session

No reactivity (Value/Computed/Spring), no layout solver, no components, no
canvas, no OS split, no desired state, no drop-offs. No changes to jobs,
mining, fleet, or existing apps. Each of those gets its own session.

## Non-negotiable

- Verify every CC: Tweaked claim in docs/ui-framework.md section 2 against the
  real documentation before relying on it — blit semantics, palette support,
  the 2x3 glyph range, terminal sizes. Those were written from experience, not
  from the source. Correct the doc where it is wrong and say so.
- The existing spec suite must pass unchanged: .\tools\spec.ps1 (43 specs).
- Run .\tools\make-manifest.ps1, .\tools\check.ps1 and git diff --check before
  handing back.
- Match the house comment style: explain WHY, especially where a decision
  looks odd. src/turtle/access.lua and src/jobs/prospecting/surface.lua are
  the standard to hit.
- Check the target PR state with `gh pr view <n> --json state` BEFORE every
  push. If it merged, branch fresh from origin/master. This has caught people
  out three times already.
- Open a DRAFT PR against master. Do not merge it. Do not bump the version.

## Stop condition

If the bench cannot repaint a full 164x81 screen within one tick (50ms), STOP
and report it rather than continuing. That budget is the premise the entire
framework rests on; if it does not hold, the plan needs revisiting rather than
building on.

## Report at the end

Measured bench numbers. Any plan claims that turned out to be wrong. Whether
the one-tick budget held. What the next session should pick up.
```
