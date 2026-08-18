# ICOS 2 — UI framework plan

A plan for the rendering and component layer ICOS 2 is built on. Nothing here is built.

Companion to [`docs/icos-2.md`](icos-2.md), which covers the OS split and the service
model. This covers everything a person actually looks at.

For the design system and the component API — tokens, variants, and what writing a screen
feels like — see [`docs/ui-design.md`](ui-design.md). This document is the machinery
underneath it. Run `.\tools\preview.ps1` to see the proposed look rendered through the
real renderer at a real terminal size.

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

**Verified.** This table was originally written from experience. Every row has since been
checked against the CC: Tweaked source at tag `v1.20.1-1.113.1` — the exact build this
fleet runs — and against [tweaked.cc](https://tweaked.cc). Two rows were wrong and one was
missing; they are corrected below and called out underneath.

| Constraint | Consequence |
| --- | --- |
| The screen is a character grid: **51×19** on a computer, **39×13** on a turtle, **26×20** on a pocket computer, and exactly **164×81** on the largest monitor (8×6 blocks) at scale 0.5 | Layout is integer cells. No subpixel positioning at the widget level. |
| 16 colours on screen, and `term.setPaletteColour` redefines all 16 to arbitrary RGB — **on every terminal, not only advanced ones**. A non-advanced terminal stores the value and renders it as its greyscale average | A real palette is possible everywhere. Sixteen *chosen* colours, not sixteen given ones — but see §11: they have to differ in luminance, not only in hue. |
| `term.blit(text, fg, bg)` writes a run with per-character colours in one call. The three arguments must be the same length or it throws. It **does not wrap**: a run is clipped to its row, and the cursor must be positioned first | The renderer must batch into runs, and the unit worth minimising is the *run*, because each one costs a `setCursorPos` as well. Per-character `setTextColor` + `write` is the slow path. |
| The font has 2×3 block characters at codes 128–159. That is 32 codepoints for 6 subpixels: **five are addressable and the sixth needs fg and bg swapped**, and a cell holds only two colours whatever the pattern | An effective pixel grid of 102×57, up to 328×243, in two colours per 2×3 cell. This is how cards and images get drawn. |
| The game runs at 20 ticks/second; `os.sleep` and `os.startTimer` round **up** to the next multiple of 0.05 | **20 FPS is the hard ceiling.** Design animation for 10–15. |
| Cooperative multitasking within a computer, and **pre-emptive scheduling between them**: all computers share `computer_threads` (default **1**), and each runnable one gets 50ms ÷ the number of runnable computers, floored at **5ms**, before it is paused for its neighbours | The frame loop is a coroutine that yields, and a slow render starves input on that machine. But the budget is a 5ms slice on a busy server, not a 50ms tick — see §12. |
| `window` objects buffer while invisible and draw immediately on becoming visible | Tear-free presentation already exists; use it rather than inventing one. |

The 20 FPS ceiling is the important one. It rules out anything that needs smooth motion
and rules *in* deliberate, snappy, well-eased transitions of 150–300ms. The aesthetic has
to be chosen to suit that, not fight it.

### What the check changed

**The palette is not an advanced-hardware feature.** `Palette.setColour` accepts a value
on every terminal; what a non-advanced one does is store it and render
`(r + g + b) / 3`. So a theme is not unavailable on a standard computer, it is *flattened
to luminance*. That turns §11's fallback from a second colour mapping into a constraint on
the first: tokens that differ only in hue become the same grey. Contrast is now a
correctness property of the palette rather than a nicety.

**164×81 is exact, not approximate.** `Config.monitorWidth`/`monitorHeight` cap a monitor
at 8×6 blocks, and `ServerMonitor.rebuild` sizes the terminal as
`round((blocks − 2 × (border + margin)) ÷ (scale × 6 or 9 × 1/64))`, which at scale 0.5
gives 164 × 81 with no rounding ambiguity in the width. Be aware that the widely quoted
figure of 162×80 is from the pre-Tweaked ComputerCraft wiki, whose border constants
differ; benching against it would undercount by two columns and a row.

**A computer does not get a whole tick.** This row was missing entirely and it is the one
that matters most for §12. `ComputerThread` targets 50ms of latency per computer but
divides it by the number of runnable computers, with a 5ms floor
(`DEFAULT_LATENCY`, `DEFAULT_MIN_PERIOD`). A base station and ten turtles is eleven
runnable computers on one thread, so the base's slice is 5ms — a tenth of the tick the
budget was originally written against. Nothing crashes when a frame overruns; the computer
is simply paused and resumed, and the only hard limit is the 7-second "Too long without
yielding" abort. But a frame that needs 40ms of Lua is a frame that takes eight scheduling
slices to appear, while every turtle on the server waits behind it.

**Confirmed unchanged:** the blit signature and its same-length requirement; the 128–159
glyph range; tick rounding; `window` buffering.

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

The bottom two rows exist as of phase 1. `ports/screen` is
[`src/ports/screen.lua`](../src/ports/screen.lua), implemented over a terminal by
[`src/adapters/cc/screen.lua`](../src/adapters/cc/screen.lua) and over a recording cell
grid by [`src/adapters/sim/screen.lua`](../src/adapters/sim/screen.lua);
[`src/ui/buffer.lua`](../src/ui/buffer.lua) is the grid and the diff, and
[`tools/spec/buffer_spec.lua`](../tools/spec/buffer_spec.lua) is the first test in this
repository that asserts what is on a screen without a world to put it in.

Two decisions made while building it are worth knowing before adding to the layer, and
both are recorded in the file's own header: **a changed row is emitted as one run spanning
its first change to its last**, never as several runs skipping the identical middles,
because a call into the game costs far more than the characters inside it; and **a row is
three strings rather than a table of cells**, which makes comparison and painting run in C
and makes cell-at-a-time `set` the deliberate slow path the canvas must avoid.

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
that want to be curves rather than bars. Pixel coordinates begin at 1; a component box
`w × h` cells exposes exactly `2w × 3h` pixels to its `Draw` callback.

Sprites are authored as rows of palette-index hex digits, with `.` for transparency, and
checked into the repo rather than generated at runtime:

```lua
local chip = ui.sprite.new({
  ".cc.",
  "cddc",
  ".cc.",
})
```

`Sprite` measures that asset to its intrinsic cell size; `Canvas` owns an arbitrary region
and draws through a callback. Both feed complete encoded rows into `ui/buffer`, never one
write per pixel. The normal diff still decides what reaches the terminal.

A glyph can hold only two colours. If drawing creates three or more in one 2×3 block, the
two most frequent survive and the rest go to the nearest survivor in the active theme's
RGB palette. Ties are settled in reading order. That rule is deterministic, honours the
custom palette rather than assuming CC's defaults, and is recorded in D036.

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

**Built in phase 4**, and the requirement above holds in a stronger form than it was
written: a screen that animates nothing never allocates a driver at all, so the loop's
"is anything moving" question is answered without one existing.

One thing the plan did not anticipate. **A spring cannot be integrated in one 50ms step at
the speed this section gives as its example.** `Spring(goal, 25, 1)` puts `speed² · dt²` at
1.56, and a semi-implicit Euler integrator above 1 gains energy every step: the value
reached six figures within six frames, never settled, and therefore kept the frame loop
awake forever — turning a runaway animation into a machine that never idles. Frames are
sub-stepped at 1/60s, which is a stability limit rather than a smoothness setting. See
D034; the motion budget above is unaffected.

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

**Built in phase 3.** `ui/input.lua` has the normalisation and the tree walks;
`Root:dispatch` has the routing. Two details that only became clear while building it:

- **A monitor touch produces two events, not one.** It has no release of its own, so one
  is synthesised at the same point. A component that waited for an `up` would simply never
  fire on the surface the fleet dashboard is for.
- **Key codes are a version dependency.** `ui/` may not read CC's `keys` table, so the
  handful the framework itself consumes are written out in `input.KEY`, copied from
  `rom/apis/keys.lua` at v1.20.1-1.113.1. CC's own header warns these are not stable
  between versions — they changed once already, moving from LWJGL to GLFW — so re-check
  them on a major CC upgrade. Everything a screen binds beyond those is passed through as
  a number and needs no table.

Drag is normalised and routed but nothing uses it yet; there is no component that a person
can drag. Hover does not exist and will not.

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
indices, so a theme swap is data.

**Corrected after checking the source (§2).** This section used to say standard hardware
falls back to the fixed 16 with a documented mapping, and monochrome hardware to two.
There is no such fallback and no monochrome tier: `Palette.setColour` accepts the value on
every terminal, and a non-advanced one renders each slot as `(r + g + b) / 3`. Standard
hardware gets **the theme, in sixteen greys**.

That is better than a second mapping and stricter than it. There is nothing to write; but
two tokens that differ only in hue — a green `good` and a red `bad` at the same brightness
— become the same grey, and the row that says a turtle is stuck becomes indistinguishable
from the row that says it is fine. So every semantic pair must separate on luminance as
well, and the palette needs a check that computes `(r + g + b) / 3` per token and fails on
collisions. That is enforced by `theme.separation`, which landed with the theme in phase 2.

Light and dark are two token sets. Contrast still has to be checked on a real monitor —
CC's palette is rendered at a size where subtle neutrals disappear — but the greyscale
collision test can be done without one, and now is: `.\tools\preview.ps1` reports the
separation of every semantic token in both themes. It found a `warn`/`destructive` pair one
point apart on its first run.

**The token set, the values, and the reasoning are in
[`docs/ui-design.md`](ui-design.md).** In summary: six neutrals, two accent, three semantic,
three free. There is no `info` — it was cut rather than retuned, because four semantic
tones plus two text greys do not fit on one luminance axis with room to spare.

Colours are handled as **palette indices 0–15** throughout the framework, not as
`colors.*` bitmask values. `term.blit` names slots with a hex digit and the palette is
sixteen numbered slots; the bitmask is a shape that suits `redstone` and nothing here.
Conversion happens once, inside `adapters/cc/screen.lua`, on the two calls per frame that
are not on the hot path.

---

## 12. Performance budget

Explicit targets, and — as of phase 1 — measured numbers rather than hopes. Run
`.\tools\bench.ps1`.

### Measured

The phase 5 renderer, painting a fleet dashboard modelled on the real Fleet page and a
full-surface pixel workload. `blits` is calls through `ports/screen`; `chars` is how many
cells those calls carried.

| Case | Surface | blits/frame | chars/frame | ms/frame |
| --- | --- | ---: | ---: | ---: |
| Idle, nothing touched | 164×81 | 0 | 0 | 0.000 |
| Idle, page repainted in full | 164×81 | 0 | 0 | 0.64 |
| Dashboard update (10 heartbeats + clock) | 164×81 | 11 | 171 | 0.28 |
| Full repaint, every cell differs | 164×81 | **81** | 13,284 | **0.84** |
| Full 2×3 canvas repaint | 164×81 | **81** | 13,284 | **4.46** |
| Idle, page repainted in full | 51×19 | 0 | 0 | 0.12 |
| Dashboard update | 51×19 | 11 | 171 | 0.09 |
| Full repaint, every cell differs | 51×19 | 19 | 969 | 0.16 |
| Full 2×3 canvas repaint | 51×19 | 19 | 969 | 0.34 |

### Against the budget

| Metric | Budget | Measured | |
| --- | --- | --- | --- |
| Idle screen | 0 terminal calls, < 1ms comparison pass | 0 calls; < 0.001ms untouched, 0.64ms when the page repaints itself | ✅ |
| Typical dashboard update | < 40 `blit` calls | 11 | ✅ |
| Full-screen change, 164×81 | one frame (50ms) | 0.84ms — 2% of a tick, 17% of a contended 5ms slice | ✅ |
| Full 2×3 canvas, 164×81 | one frame (50ms) | 4.46ms — 9% of a tick, 89% of a contended 5ms slice | ⚠️ |
| Frame loop while animating | 10–15 FPS sustained, no starved input | idle/driver behaviour is spec-covered; Cobalt still needs an in-world smoke test | ⚠️ |

**The one-tick premise holds, with room.** A full repaint of the largest monitor a person
can build costs 0.84ms and 81 terminal calls, against a 50ms tick. It also fits inside the
5ms slice a computer gets when it is sharing a thread with ten turtles (§2), which is the
budget that actually binds and which the original target did not account for.

The phase 5 pixel case rebuilds and encodes all 79,704 subpixels, changes every terminal
cell, and still costs 4.46ms on desktop Lua. It fits one contended slice here, narrowly;
the in-game Cobalt measurement remains part of phase 6's soak test.

### Read the times with the caveat attached

The bench runs on the Lua the language server embeds — PUC Lua on a desktop CPU. In game
the same code runs on Cobalt, a Java interpreter, on a server that is doing other things.
Cobalt is slower; a conservative 10× would put the cell repaint at about 8ms and the
synthetic full-wall canvas at about 45ms, both inside a tick but neither inside a single
contended slice.

Which is why the bench reports counts as well. **81 blits and 13,284 characters are
properties of the algorithm** and are identical on every interpreter. The times say whether
there is headroom; the counts say whether the design is right. Hold future changes to the
counts, and re-measure the times on hardware before trusting a margin.

Three results are worth reading beyond the pass mark:

- **Idle is genuinely free.** Not "cheap" — below the timer's useful precision and zero calls, because a frame with
  no dirty rows examines nothing at all. This is what makes §8's claim affordable: a frame
  loop can tick at 20 FPS behind a settled screen and cost nothing.
- **A page that repaints itself in full still emits nothing.** 0.64ms of painting into the
  back buffer, and zero terminal calls, because the diff finds every row identical. That is
  the compatibility story for every app in this repository as it stands: they can keep
  redrawing everything and stop flickering, before any of them is rewritten.
- **The dashboard update is 11 calls for 171 characters** — one per changed row, spanning
  first change to last. The naive per-cell renderer would have emitted somewhere near 171.
**The canvas row is the one caveat in this table**, and it is marked rather than passed.
Against the stated 50ms budget it passes comfortably; against the 5ms slice a computer
actually gets on a loaded server (§2) it uses 89% — and the same 10× Cobalt margin that
leaves a cell repaint inside a tick puts a full-wall canvas at roughly 45ms, which is nine
slices. A full monitor wall of pixels is a thing you can draw once. It is not a thing you
can animate while ten turtles are reporting.

That gives §15's *"canvas is for content, never for chrome"* a quantitative form. A canvas
costs about **0.3µs per terminal cell** here; allowing 10× for Cobalt, a 5ms slice affords
roughly **1,700 cells of pixel surface per frame** — a full 51×19 computer terminal, or
about a third of a monitor wall. Sizing an animated canvas is a real decision, and the
answer is a region rather than the whole screen.

- **A full pixel surface stays batched.** Rebuilding the largest possible canvas costs
  4.46ms but still emits exactly 81 runs, one per terminal row. The first implementation
  took 26.42ms; allocation-free two-colour encoding and retained pixel rows cut that by
  more than six times (D037).

### Against Basalt 2

[Basalt](https://github.com/Pyroxenium/Basalt2) is the established UI framework for
CC: Tweaked and the obvious thing to be measured against. `.\tools\compare.ps1` runs one
identical dashboard workload through both renderer designs and counts what each sends to
the terminal. Basalt's side is a faithful reimplementation of its published
`src/render.lua`; it is the **renderer only**, not the framework.

|  | ICOS blits | Basalt 2 blits | ICOS chars | Basalt 2 chars |
| --- | ---: | ---: | ---: | ---: |
| Idle, nothing changed | 0 | 0 | 0 | 0 |
| **One label changes** | **1** | **81** | **1** | **13,284** |
| Dashboard update, only changed cells written | 11 | 21 | 171 | 208 |
| **Page repaints itself, same result** | **0** | **81** | **0** | **13,284** |
| Full repaint, everything differs | 81 | 81 | 13,284 | 13,284 |

Since phase 2 the comparison also runs the **whole framework** rather than only the
renderer, because that is where the advantage is actually won or lost. One heartbeat —
a single turtle changing fuel and phase, on a full page of six devices:

| | blits |
| --- | ---: |
| ICOS: the node is marked, its subtree is painted | **1** |
| Root invalidation: the whole tree is painted | **81** |

The ICOS figure is the real thing: `ui/runtime.lua`, the real reactive graph, the real
layout solver, and `apps/fleet/view.lua`. Nothing is simulated on that side.

**The two designs tie at both extremes and diverge in the middle, which is where a
dashboard lives.** Nothing-changed is free in both, because both skip the work when no
element reports a change. Everything-changed costs 81 calls in both, because that is the
floor — you cannot repaint 81 rows in fewer than 81 blits. The ceiling and the floor are
the same. All of the difference is in the ordinary case.

The cause is one design choice: **Basalt's buffer records where it was written to; ours
records what changed.** `Render:addDirtyRect` is called on every write, unconditionally,
and there is no front buffer to compare against — so a row repainted with the text it
already had is a row that gets sent. We keep the previously-presented row and compare, so
it is not.

That compounds with a second choice. `BaseElement:updateRender` walks up the parent chain
and sets `_renderUpdate` on the **root frame**, so changing one property redraws the entire
visible tree. Every one of those redraws is a write, every write is a rectangle, and no
rectangle knows it is identical to what is already on screen. Hence row two: one changed
label, 81 calls, 13,284 characters — to put one character on a monitor.

The sharpest part is that Basalt 2 *has* the information to avoid this. Its property system
knows which property changed and carries a per-property `canTriggerRender` flag. It then
discards that precision at the last step by invalidating the root instead of the node.
**That is the mistake to not repeat in phase 2**, and it is easy to repeat, because
invalidating upwards is the simplest thing that works.

Two smaller notes on the rectangle approach, recorded because someone will eventually
propose replacing our row spans with it:

- Rectangles lose to row spans even when the caller is careful. Row three of the table is
  the case where only genuinely-changed cells are written: 21 rectangles, one per write,
  because rectangles on different rows never overlap and so never merge. Our row spans
  coalesce those same writes into 11.
- The merge is single-pass and grows to the bounding box: a rectangle that merges is not
  re-tested against the ones before it, so overlapping rectangles can survive into the
  emit and blit the same cells twice; and two small changes that each overlap a third
  rectangle become one rectangle covering everything between them.

See §16 for what this does and does not mean, and D028 for why a changed row is one span.

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

| # | Phase | Delivers | |
| --- | --- | --- | --- |
| 1 | `ports/screen`, `ui/buffer`, diff + blit, bench | Flicker-free painting, measured | **done** |
| 2 | `ui/reactive` + `ui/layout` + `ui/runtime` + core components | Rebuild one existing app on it | **done** |
| 3 | `ui/input`, focus, gestures | Full interaction parity with today | **done** |
| 4 | `Spring` / `Tween` + transitions | Motion, frame loop gated on activity | **done** |
| 5 | `ui/canvas` + sprites | Imagery; theming landed early, in phase 2 | **done** |
| 6 | Blackjack | Showcase and soak test | **next** |
| 7 | Port remaining apps, add AP ports | Old `core/ui.lua` deleted; chat notifications | |

**Phase 1 landed**, with `ports/`, `adapters/cc`, `adapters/sim`, `src/ui/buffer.lua`, the
buffer specs, and `.\tools\bench.ps1`. The measured numbers are in §12 and the premise
holds. It shipped one thing the plan did not name: `tools\check.ps1` now fails if anything
under `src/domain`, `src/ports`, or `src/ui` references a CC global, because a layering
rule that nothing checks is a comment.

Phase 2 rebuilding **Devices specifically** is deliberate: it is the densest existing
screen, with a list, a detail view, a settings editor, and scrolling. If it does not come
out simpler than the current version, the framework is not earning its place and the plan
should be revisited before phase 3.

**Phase 2 had one hard constraint, and it held.** A `:set()` marks the **node**
paint-dirty or layout-dirty, never the root. `tools\compare.ps1` now measures the whole
framework rather than only the renderer, and one heartbeat on a full 164×81 page costs
**1 blit** against **81** for the same change under root invalidation.

### What phase 2 delivered

- `ui/reactive.lua` — `Value`, `Computed` with explicit `use`, `Observer`, `scoped()`,
  cycle detection, and a live-object count for the leak check §15 asks for.
- `ui/layout.lua` — the flex subset, integer-only, with the remainder rule written down.
  Pure functions over plain tables; it knows nothing about nodes or painting.
- `ui/runtime.lua` — the retained tree, the bindings, and the per-node dirty queue.
- `ui/theme.lua` — the sixteen tokens, both palettes, and the greyscale check.
- `ui/components/` — `Text`, `Heading`, `Muted`, `Box`, `Row`, `Column`, `Card`, `Spacer`,
  `Separator`, `Button`, `Badge`, `Meter`, plus the `Page` and `Table` composites.
- `apps/fleet/view.lua` — the Fleet dashboard rebuilt, with no coordinates, no colours, no
  redraw calls and no derived value that can go stale.
- 48 new specs, all of them without a world or a Minecraft.

Three refinements were forced by building it, and each is a comment in the file it lives
in:

- **Re-measure before deciding to re-solve.** Classifying `Text` as layout-affecting and
  stopping there would re-solve and repaint on every heartbeat. "miner-3" becoming
  "miner-4" measures the same, so the frame degrades it to a paint. Without this the
  binding is precise and the frame throws the precision away.
- **Invalidation is not change.** A `Computed` reading the whole device list is
  invalidated whenever any device reports, but usually formats to the string it already
  had. The binding compares before marking, which is what turns forty invalidated cells
  into the eleven that moved.
- **Defaults belong at construction, not in `paint`.** `Direction` is read during measure,
  so a `Column` that set its own direction while painting had already been laid out as a
  row.

### What phase 3 delivered

- `ports/input.lua`, with a cc adapter over `os.pullEventRaw` and a sim adapter that is a
  scripted pair of hands. The sim one needs no world: a spec writes down what a person did
  and the framework cannot tell the difference.
- `ui/input.lua` — normalisation, hit testing, bubbling, and the focus ring. All pure
  functions over a laid-out tree, so every routing rule is a unit test.
- `ui/runtime.lua` gained `dispatch`, `handle` and focus management.
- `ui/host.lua` — mount against two ports, then pull, dispatch, render, repeat.
- `Table` gained scrolling and row selection.
- `apps/devices/view.lua`, and 31 more specs.

**Devices is the acceptance test this section set for the project.** It was claimed
complete a phase early and was not: this section asks for "a list, a detail view, **a
settings editor**, and scrolling", and the first rebuild had three of the four. The editor
landed afterwards, and the claim stands now — a list, a detail panel, a full-width settings
editor with one `Stepper` per advertised field, selection, scrolling, keyboard operation,
and a display-only variant with nothing to tab to. No coordinate, no colour and no redraw
call anywhere in it. Read it against `src/apps/devices.lua`, which is the version it
replaces.

The comparison the section actually asks for: the old page carries a
`compact = width < 42` branch that recomputes four column positions by hand, which is the
"does this fit on a pocket computer" arithmetic §1 says the framework exists to delete.
There is none of it in the rebuild.

Three things are worth knowing before phase 4:

- **A monitor touch is a whole tap.** CC gives a terminal four mouse events and a monitor
  exactly one, with no release, no drag, and no hover ever. `ui/input.lua` normalises a
  touch into a press *and* a release at the same point. Nothing above may assume a release
  follows a press after an interesting interval — which is why §9 omits long-press
  deliberately rather than by oversight.
- **Scrolling is an offset, not a clip.** A table's slot `i` shows `list[i + offset]`, so
  scrolling changes what cells compute to and moves no layout at all. There is still no
  clip region in the buffer; `ScrollView`, `Modal` and `Tabs` will need one, and that is
  the first real decision phase 4 or 5 has to make.
- **Focus is a node property**, so moving it repaints exactly two nodes however large the
  tree — and when both are on the same row the cell diff coalesces them into one call.
  That is D028 and the runtime meeting without either one knowing about the other.

Building the settings editor afterwards pulled four gaps into the open, which is the
argument for making a real screen the acceptance test rather than a checklist:

- **`Hidden` only affected hit testing.** A hidden node still reserved its space and still
  painted — invisible to a click and perfectly visible to a person. It is structural now.
- **`Grow` could not shrink.** A flexible label wider than the space left for it pushed the
  controls beside it off the edge, because `distribute` gave up when free space went
  negative. Growable children now give space back, in proportion to what they hold.
- **Composites dropped structural properties.** `scope:Table { Hidden = ... }` did nothing
  at all: a composite is a function, and the node it builds never saw the property.
  `runtime.layoutProps` forwards them.
- **A composite reads *raw* props.** `props.Disabled` is usually a `Computed` — a table,
  and therefore truthy whether it reads true or false. `if props.Disabled then` disabled
  every stepper on the page permanently, reviewed clean, and raised nothing. Any prop a
  composite reads imperatively goes through `reactive.peek`.

Fleet was rebuilt first, in phase 2, because it is the screen the performance claim is
actually about and because it needs no input at all — which made it the one screen that
could be finished before any of this existed.

### What phase 4 delivered

- `ui/anim.lua` — `Spring`, `Tween`, the four easings, and the driver. Both are state
  objects, so anything that consumes a value consumes an animated one and no component
  knows it is being animated.
- A clip stack in `ui/buffer.lua`, `Scroll` and `Absolute` in the solver, and the
  `ScrollView` and `Overlay` components that need them. D033 flagged the clip region as
  something to decide deliberately rather than bolt on; this is that.
- `Root:advance(now)` and `Root:animating()`; the host loop wakes on a tick only while
  something is moving and blocks on the next event otherwise.

**The §8 claim holds: an idle screen costs nothing.** A screen that animates nothing never
allocates a driver, so `animating()` answers false without one existing. A settled spring
removes itself. Both are asserted rather than argued.

Three findings, all now decisions because each is the kind of thing that gets simplified
back:

- **A spring at the speed §8 gives as its example diverges** if integrated in one 50ms
  step — `speed² · dt²` is 1.56, and above 1 the integrator gains energy. It reached six
  figures in six frames and, because it never settled, kept the host loop awake at 20 FPS
  forever. Sub-stepping at 1/60s is a stability limit, not a quality setting (D034).
- **`Scroll`, `Align` and `Justify` change arrangement without changing measurement**, so
  the measure-and-compare path skipped the re-solve and a `ScrollView` rendered the top of
  its list forever while reporting the right offset. Structural properties now force a
  re-solve; content properties keep the fast path (D035).
- **A targeted repaint inside a clipped container has to replay its ancestors' clips.**
  Painting a subtree in isolation is not the same as painting it in context, and without
  the replay a row scrolled off the top repaints itself over whatever is above the panel.

### What phase 5 delivered

- `ui/canvas.lua` — a pure pixel surface with clipped points, Bresenham lines, outlined or
  filled rectangles, outlined or filled midpoint circles, numeric images, sprite drawing,
  and the 2×3 encoder. It knows no terminal and paints one complete run into the buffer per
  character row.
- `ui/sprite.lua` — the deliberately small source format above, validated once when it is
  constructed, plus transparency and palette remapping when it is drawn.
- `Canvas` and `Sprite` components. The former exposes a retained node's cell box as pixels;
  the latter measures immutable art to `ceil(width / 2) × ceil(height / 3)`. Replacing a
  same-sized reactive sprite repaints its own cell and does not re-solve the page.
- Six specs covering the glyph's foreground/background swap, theme-aware reduction,
  clipped primitives, sprite validation and remapping, row batching, and retained reactive
  repaint. The suite is now 168 specs.
- `tools/bench.lua` gained a full-canvas workload. The largest monitor rebuilds and changes
  all 79,704 pixels in 4.46ms on desktop Lua, still emitting one run per terminal row. The
  Cobalt result is deliberately left for Blackjack's in-world soak test.

The Basalt reference confirmed the important representation trick: pixel six is carried by
the background and the other five select the glyph. Its pixelbox plugin uses a fixed
distance table for CC's default colours; ICOS cannot, because its sixteen slots are
deliberately redefined by the active theme. D036 records why reduction receives the real
palette instead.

The first correct encoder was not fast enough: it took 26.42ms for that full-wall case.
The normal one/two-colour path now allocates no per-cell tables and retained components
reuse their pixel rows, reducing it to 4.46ms. D037 keeps the benchmark and the reason for
those two otherwise-easy-to-remove optimisations together.

---

## 15. Risks

- ~~**Performance is the whole bet.**~~ **Retired.** The diff repaints the largest
  monitor in 0.79ms against a 50ms tick, and in 16% of the 5ms slice a computer gets on a
  contended server (§12). Re-measure on real hardware before relying on the margin, and
  hold future changes to the blit counts rather than the times.
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
- **Reinventing Basalt badly.** A worse version of an existing framework is worse than
  using the existing framework. §16 is the standing answer to "why not just use Basalt",
  and if the answers in it stop being true, this plan should stop too.

---

## 16. Why not just use Basalt

[Basalt 2](https://github.com/Pyroxenium/Basalt2) exists, is MIT-licensed, is actively
developed, and is far more finished than anything here. Writing a second framework needs a
better reason than not having read the first one. This section is that reason, and the
place to check it is still valid.

### What Basalt is better at, and we should not chase

- **Breadth.** Around sixty elements — Accordion, Breadcrumb, ComboBox, ContextMenu,
  Dialog, TabControl, Tree, three chart types. §7 lists about twenty-five and that is the
  whole of it; §15 already calls a component library a bottomless pit. Basalt has spent
  years filling it and will keep winning that race, which is the correct outcome.
- **Polish around the edges.** XML layouts, JSON theme files, a plugin system, a bundler
  producing a single-file release, `flow` and `grid` layouts.
- **Maturity.** Two major versions, real users, real bug reports. This has one phase.

### What we are better at, and must stay better at

Three things, all of which are load-bearing for a fleet dashboard specifically and none of
which are about widget count.

**1. Precision, measured.** One changed label costs us one blit and one character, and
costs the dirty-rectangle design 81 blits and 13,284 characters (§12). Not because their
renderer is careless — it is a reasonable design — but because it records writes and we
record changes, and because invalidation there goes to the root frame rather than the node.
This is the whole technical argument and it is a number, not a preference.

**2. It is testable, and that is what keeps the number true.** Neither Basalt version has
a test suite. Ours renders through `ports/screen`, so a recording adapter with a cell grid
and a call log is a complete substitute for a monitor: `tools/spec/buffer_spec.lua` asserts
both what is on the screen and how many calls put it there. A performance property nothing
checks is a performance property that decays. This one fails the build.

**3. It runs where this fleet runs.** A display-only monitor with no keyboard, where the
`requiresInput` boundary (D020) decides what may even appear; a 39×13 standard turtle
screen; a 26×20 pocket computer; and a server that is reconciling ten turtles while it
draws. Basalt 2 imposes no advanced-computer requirement — that was a Basalt 1 restriction
and it is gone — but no general framework has a concept of a surface that must refuse to
show a command. Ours has to, because the alternative is a recall button on a wall.

### What to steal, deliberately

- **Generated LuaLS annotations.** Basalt generates `.lua` type annotations and its docs
  from source comments (`tools/generate-annotations.lua`, `tools/BasaltDoc/`). This
  repository already runs the language server in `check.ps1` and already writes annotated
  headers; generating a component annotation file from the component definitions would make
  every property autocomplete in the editor for free. Worth doing at phase 2, when there
  are components to generate from.
- **Per-property render hints.** Basalt's property definitions carry `canTriggerRender`.
  §7 already splits paint-dirty from layout-dirty by property, so this is confirmation that
  the axis is right — but mark the **node**, not the root. That single difference is most
  of the 81× above.
- **Runtime argument checking at construction.** Their `libraries/expect.lua` validates
  types where an element is built. Lua's failure mode is a nil three frames later in a
  place unrelated to the mistake; checking at construction is the same reasoning as
  `ports/contract.lua` and costs nothing per frame.

### The honest summary

Basalt is the better choice for a program that wants a lot of widgets soon. This is the
better choice for a wall-mounted dashboard that redraws on every heartbeat, on a machine
that is also running a mining fleet, and that has to keep proving it is still fast. If
that stops being the trade, use Basalt.

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
