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

## 3. What "React for CC" should and should not mean

Worth being precise, because copying React wholesale would be a mistake.

**Take:** declarative component tree, props and state, re-render on change, keyed lists,
composition over inheritance, hooks for local state and effects.

**Leave:** fibers, concurrent mode, suspense, synthetic event pooling, a virtual DOM
diffed as a tree. A tree diff is the wrong tool when the output is a 164×81 grid of
cells — **diff the cells, not the tree.**

That single decision shapes the whole renderer. Components re-render freely and cheaply
into a buffer; the expensive step (talking to the terminal) is driven entirely by which
*cells* changed. It makes correctness easy — a component never has to know what it
previously drew — and it makes animation nearly free, because a moving element dirties
only the cells it entered and left.

---

## 4. Architecture

```
  apps/*                      screens built from components
      │
  ui/components/              Button, List, Table, Modal, Sparkline, …
      │
  ┌───┴────────────────────────────────────────────┐
  │  ui/runtime      tree, state, effects, frames  │
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

## 7. Components and hooks

Function components returning an element tree:

```lua
local function FuelBar(props)
  local pulse = ui.useTween(props.low and 1 or 0, { duration = 400, loop = true })

  return ui.Row({ gap = 1 }, {
    ui.Text({ text = "fuel", color = "muted" }),
    ui.Bar({ grow = 1, value = props.fraction, tint = props.low and pulse or nil }),
    ui.Text({ text = ui.count(props.value), align = "right", width = 6 }),
  })
end
```

Hooks, implemented with a per-instance hook index — the same trick React uses, and the
reason the rules-of-hooks constraint exists there will exist here too:

| Hook | Purpose |
| --- | --- |
| `useState` | local state; setting it schedules a re-render |
| `useEffect` | run on mount / on dependency change, with cleanup |
| `useTween` | animated value, drives frames only while running |
| `useInterval` | timer that respects the frame loop instead of `sleep` |
| `useStore` | subscribe to a service's state (fleet, devices, drop-offs) |
| `useFocus` | participate in keyboard focus order |

`useStore` is the join between this framework and the OS: services own state, apps read
it. A component subscribes; when the service updates, only the subscribed components
re-render.

### Component library

Layout: `Row`, `Column`, `Box`, `Spacer`, `ScrollView`, `Modal`, `Tabs`.
Data: `Text`, `Table`, `List`, `Bar`, `Sparkline`, `Gauge`, `Badge`, `KeyValue`.
Input: `Button`, `Toggle`, `Stepper`, `TextField`, `Menu`, `Slider`.
Feedback: `Toast`, `Spinner`, `Skeleton`, `Empty`, `Banner`.
Graphics: `Canvas`, `Sprite`, `Logo`.

---

## 8. Animation

A tween engine driven by the frame loop, not by `sleep`:

- easings: `linear`, `easeOut`, `easeInOut`, `spring`
- `useTween(target, { duration, easing })` retargets smoothly mid-flight
- timelines for sequencing (deal card 1, then 2, then flip)
- transitions on mount/unmount so a list insert slides in rather than appearing

**The frame loop only runs while something is animating.** Idle screens are purely
event-driven and cost nothing, which matters on a server that is also reconciling a
fleet. This is a hard requirement, not an optimisation.

Motion budget, given 20 FPS: 150ms for state feedback, 250–300ms for transitions, and
nothing continuous except a deliberate pulse on an alert. Long or elaborate motion will
read as jank at this frame rate — restraint is a technical requirement here, not taste.

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

## 10. Theming

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

## 11. Performance budget

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

## 12. The showcase: Blackjack

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

## 13. Phasing

| # | Phase | Delivers |
| --- | --- | --- |
| 1 | `ports/screen`, `ui/buffer`, diff + blit, bench | Flicker-free painting, measured |
| 2 | `ui/layout` + `ui/runtime` + core components | Rebuild one existing app (Devices) on it |
| 3 | `ui/input`, focus, gestures | Full interaction parity with today |
| 4 | `ui/anim` + transitions | Motion, frame loop gated on activity |
| 5 | `ui/canvas` + sprites + theming | Imagery and real palettes |
| 6 | Blackjack | Showcase and soak test |
| 7 | Port remaining apps | Old `core/ui.lua` deleted |

Phase 2 rebuilding **Devices specifically** is deliberate: it is the densest existing
screen, with a list, a detail view, a settings editor, and scrolling. If it does not come
out simpler than the current version, the framework is not earning its place and the plan
should be revisited before phase 3.

---

## 14. Risks

- **Performance is the whole bet.** If the diff cannot repaint a large monitor in a tick,
  none of the rest matters. Benched in phase 1 for exactly that reason.
- **Hook rules in Lua.** No linter will catch a conditional `useState`. Needs a documented
  rule and a dev-mode runtime assertion on hook count per render.
- **Scope.** A component library is a bottomless pit. The list in §7 is the whole of it
  for ICOS 2; anything else waits for a second app that needs it.
- **Two rendering models.** Cell components and pixel canvas can look inconsistent if
  mixed carelessly. Canvas is for content, never for chrome.
- **This is a large rewrite of everything visible**, running in parallel with the OS
  split. They should not land together — UI phases 1–3 can proceed while the OS work is
  in its own phases, but one of them goes to the live fleet at a time.

---

## Appendix — kickoff prompt

Paste this into a fresh chat to begin phase 1.

```text
Work in C:\Users\isaac\Desktop\ComputerCraft (ICOS, CC: Tweaked / Minecraft 1.20.1).

Read these completely before changing anything:
  AGENTS.md
  docs/ai-handoff.md
  docs/architecture.md
  docs/ui-framework.md      <- the plan you are implementing
  docs/icos-2.md            <- the OS split this fits into
  src/core/ui.lua           <- what you are replacing
  src/apps/devices.lua      <- the app you will rebuild in phase 2
  tools/spec/               <- the existing simulated-world spec suite

Goal: implement PHASE 1 ONLY of docs/ui-framework.md — the screen port, the
cell buffer, the diff-and-blit renderer, and a performance bench. Do not
start phases 2+. Do not touch mining, fleet, or job code.

Deliverables:
1. ports/screen: the only module allowed to call `term`. A CC adapter and a
   recording adapter for tests.
2. ui/buffer: double-buffered cell grid ({char, fg, bg}), painting API,
   present() that diffs against the front buffer and emits one term.blit per
   contiguous changed run.
3. Specs against the recording adapter: an unchanged frame emits zero calls;
   a one-character change emits one blit; a full-screen change emits at most
   one blit per row. Assert cell contents directly.
4. A bench (tools/bench.ps1 or a spec case) reporting blit counts and elapsed
   time for: idle, a typical dashboard update, and a full 164x81 repaint.
   Record the numbers in the doc.

Constraints, all non-negotiable:
- Verify every CC: Tweaked API claim in the plan against the real docs before
  relying on it, especially blit semantics, palette support, the 2x3 glyph
  range, and terminal sizes. Correct the doc where it is wrong and say so.
- Nothing outside ports/screen may call `term` directly.
- The existing spec suite must keep passing: .\tools\spec.ps1
- Run .\tools\make-manifest.ps1, .\tools\check.ps1, and git diff --check.
- Match the house comment style: explain WHY, especially where a decision
  looks odd. See src/turtle/access.lua for the standard.
- Check the target PR's state before pushing; if it merged, branch fresh from
  origin/master. Open a DRAFT PR. Do not merge.

Report at the end: measured bench numbers, any plan claims that turned out to
be wrong, and whether the 1-tick full-repaint budget in section 11 was met.
If it was not met, stop and say so rather than continuing to phase 2 — that
budget is the premise the whole framework rests on.
```
