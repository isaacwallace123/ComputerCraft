# ICOS 2 — the design system and the component API

What ICOS looks like, and what writing a screen feels like. Companion to
[`ui-framework.md`](ui-framework.md), which covers the machinery underneath — the renderer,
the reactive primitives, the layout solver. This one is about the layer people touch.

Run `.\tools\preview.ps1` to see it. Everything in this document is painted through the
real renderer at a real 51×19 terminal, so the screenshots in your terminal are what a
computer shows, not a drawing of what it might.

The goal, stated plainly: **a framework where a screen is shorter to write than it is in
Basalt, and looks like it was designed rather than assembled.**

**Built as of phase 3.** The tokens are `src/ui/theme.lua`, the components are
`src/ui/components/`, and `src/apps/fleet/view.lua` and `src/apps/devices/view.lua` are
real screens written against them — the second being the acceptance test the framework
plan set for the project. Everything below describes code that exists and is under test,
except where it says otherwise.

---

## 1. Why shadcn is the right reference

[shadcn/ui](https://ui.shadcn.com) is not a component library so much as a set of habits,
and the habits are what transfer. Three of them, in order of how much they matter here:

**Semantic tokens, never raw colours.** Nothing in a shadcn component says `#18181B`. It
says `bg-card`, `text-muted-foreground`, `border-border`. A theme is then data, and it is
impossible for one screen to drift from another because there is nothing at the call site
to drift.

That is the discipline this repository most obviously lacks. `legacy/shell/ui.lua` has
`ui.theme.good = colors.lime`, which is a start, and then `ui.bar` hard-codes *red below
15%, yellow below 40%*. The bar decided what a low fuel reading means. It should ask for
`destructive` and let the theme decide what `destructive` looks like.

**Variants, not properties.** A shadcn button is `variant="destructive" size="sm"`. It is
not `background`, `foreground`, `border`, `hover`, `padding` set individually at every call
site. A variant is a *named intent*, and the number of intents is small and finite while
the number of property combinations is not.

**Restraint as a style.** Neutral greys, one accent used sparingly, subtle elevation, no
gradients, no ornament, secondary text in a muted grey rather than a smaller size. This
happens to be exactly what a sixteen-colour character grid can do well, which is a
coincidence worth taking.

### What does not transfer

**Whitespace.** shadcn is airy because a web page has a thousand pixels of width to be airy
with. A computer terminal has fifty-one columns. Padding of 1 is already 2% of the screen;
padding of 4, which is a small gap on the web, is 8% of everything a person can see. The
spacing scale here is `0, 1, 2` and that is the whole scale.

**Radius.** There is no such thing as a rounded corner on a character grid. The 2×3 glyphs
could fake one, at a cost of one full cell per corner and a shape that reads as noise at
this size. Rejected; the soft feeling has to come from the palette instead.

**Borders as thin lines.** This is the interesting one, and §3 is about it.

---

## 2. The sixteen

Six neutrals, two for the accent, three semantic, three free, plus the page and its text.
The values live in [`src/ui/theme.lua`](../src/ui/theme.lua);
[`tools/preview.lua`](../tools/preview.lua) mirrors them so the look can be adjusted
without touching shipped code, and the theme file is the one that is right if they drift.

| Slot | Token | Role |
| ---: | --- | --- |
| 0 | `foreground` | primary text |
| 1 | `primary` | solid action surface — near-white in dark, near-black in light |
| 2 | `primaryFg` | text on `primary` |
| 3 | `mutedFg` | secondary text: labels, hints, column headings, a parked turtle |
| 4 | `border` | separators, and the recess inside a raised surface |
| 5 | `muted` | recessed fill: input wells, selected rows, meter tracks, disabled |
| 6 | `card` | raised surface, one step above the page |
| 7 | `accent` | the one colour that means *this one* |
| 8 | `accentFg` | text on `accent` |
| 9 | `good` | |
| 10 | `warn` | |
| 11 | `destructive` | |
| 12–14 | `free1`–`free3` | app-owned: chart series, card suits, a game |
| 15 | `background` | the page |

Slot numbers are not arbitrary. A CC terminal clears to slot 15 and writes in slot 0, so
putting `background` at 15 and `foreground` at 0 means a freshly cleared screen is already
the right colours and a component that forgets to set one is not obviously broken.

### There is no `info`, deliberately

There was. It was cut rather than retuned, because of the constraint in the next section:
four semantic tones plus two text greys do not fit on one luminance axis with room to
spare, and `info` was the one that named nothing the fleet actually reports. Dropping it
bought every remaining pair about ten points of separation. **If a fifth semantic colour is
ever proposed, this is the trade it has to win.**

### Contrast is a correctness property, and it is checked

`term.setPaletteColour` works on every terminal, but a non-advanced one renders each slot
as `(r + g + b) / 3` (verified in §2 of [`ui-framework.md`](ui-framework.md)). So a standard
computer gets the theme in sixteen greys — and two tokens that differ only in hue become
the same grey. The row that says a turtle is stuck then looks exactly like the row that
says it is fine.

`tools\preview.ps1` reports the separation and it has already earned its place: the first
palette written for it put `warn` and `destructive` **one point apart**. Nobody would have
found that until somebody ran the fleet from a standard computer and could not tell a full
depot from an open shaft.

The current numbers, on a target of 20 points:

```
dark    good 108   destructive 133   mutedFg 164   warn 207   foreground 250
        closest pair 25 apart                                        clears

light   foreground 9   good 49   warn 74   destructive 98   mutedFg 116
        closest pair 18 apart                     under target, usable but tight
```

Light is tighter by construction: every token has to be dark enough to read on white, so
the whole set is squeezed into the bottom half of the range. That is reported rather than
hidden.

None of which removes the standing rule: **never encode meaning in colour alone.** The
status column says `no cap block`. The colour only makes it findable faster.

---

## 3. Elevation instead of outline

The single most important adaptation, and the one that makes the result look like shadcn
rather than like a 1990s TUI.

On the web a card is a 1-pixel border and a soft shadow — both far *thinner* than the text
beside them, which is what makes them read as a quiet boundary. The nearest equivalent on a
character grid is a box of `+---+`, which is a full cell wide. A cell is the same size as a
letter. So a drawn border is not a quiet boundary; it is **heavier than the content it
surrounds**, which is the opposite of the intended effect. That is why terminal UIs built
out of box-drawing characters look busy no matter how carefully they are spaced.

So: a card is a rectangle painted one step lighter than the page, with no drawn edge at
all. A separator is one row of `border` as a background — the closest a cell grid gets to a
hairline, used where a change of elevation would be too strong. Panels stack
`background → card → muted` and that is the entire vocabulary of depth.

Three cells of chrome are saved on every panel edge, which on 51 columns is real.

### The rule this forces: components take their surface

There are sixteen slots, not a continuous scale, so there is not always a spare shade. A
`muted` meter track on a `muted` selected row is invisible.

That is not hypothetical — the first version of the preview had exactly that bug, and the
selected turtle silently lost its fuel bar. Every component that recesses or raises
therefore takes the surface it is sitting on and picks its shade relative to that. A track
on `background` is `muted`; a track on `muted` is `border`.

On the web you would never write this down, because there is always another shade of grey.
Here it is a rule.

---

## 4. Variants

Four button variants, which turns out to be enough:

| Variant | Fill | Use |
| --- | --- | --- |
| `primary` | `primary` bg, `primaryFg` text | the one action the page is for |
| `secondary` | `muted` bg | everything else |
| `ghost` | no fill, `mutedFg` text | tertiary, and anything in a dense row |
| `destructive` | `destructive` bg | the only variant allowed to be a colour |

In dark, `primary` is a near-white slab with dark text. That is shadcn's dark theme and it
looks startlingly good on a monitor wall — it is the brightest thing on the screen, so the
eye goes to it, which is what a primary action is for.

`destructive` being the only coloured variant is what makes it read as a warning rather
than as decoration. The moment there are three coloured buttons on a page, none of them
means anything.

Sizes are `sm` and `md`. There is no `lg`; on 51 columns a large button is a full-width
button, which is a layout decision rather than a size.

---

## 5. Writing a screen

Components are ordinary functions over a props table, reached through the scope. Lua's
`f{...}` call syntax means no parentheses, so the code's indentation is the UI's shape.

```lua
local ui = require("ui")
local scope = ui.scoped()

local devices  = scope:Store(services.fleet, function(state) return state.devices end)
local selected = scope:Value(nil)
local online   = scope:Computed(function(use) return count(use(devices), "online") end)

return scope:Page {
  Title  = "Fleet",
  Status = scope:Computed(function(use)
    return ("%d of %d online"):format(use(online), #use(devices))
  end),

  Children = {
    scope:Table {
      Rows     = devices,
      Selected = selected,
      OnOpen   = function(row) ui.open("devices", { id = row.id }) end,
      Columns  = {
        { Title = "Device", Width = 12, Key = "label" },
        { Title = "Status", Grow  = 1,  Key = "phase", Tone = statusTone },
        { Title = "Fuel",   Width = 7,  Key = "fuel",  Align = "right", Format = ui.count },
        { Width = 10, Render = function(row) return scope:Meter { Value = row.fuelFraction } end },
      },
    },
  },

  Actions = {
    scope:Button { Text = "Deploy all", Variant = "primary", OnClick = fleet.deployAll },
    scope:Button { Text = "Recall",     OnClick = fleet.recallAll },
    scope:Button {
      Text     = "Stop",
      Variant  = "destructive",
      Disabled = scope:Computed(function(use) return use(selected) == nil end),
      OnClick  = function() fleet.stop(selected:get()) end,
    },
  },
}
```

That is the whole page. There is not a single coordinate in it, not a single colour, and no
call that says "now redraw".

### The same page in Basalt 2

```lua
local main = basalt.getMainFrame()

main:addLabel():setPosition(3, 2):setText("Fleet"):setForeground(colors.white)
main:addPane():setPosition(1, 3):setSize("parent.w", 1):setBackground(colors.gray)

local status = main:addLabel():setPosition(36, 2):setForeground(colors.lightGray)
local list   = main:addList():setPosition(1, 5):setSize("parent.w", 10)

local function refresh()
  list:clear()
  local online = 0
  for _, d in ipairs(fleet.devices()) do
    if d.online then online = online + 1 end
    list:addItem(
      d.label .. string.rep(" ", 12 - #d.label) .. d.phase,
      colors.black,
      d.stuck and colors.red or colors.green
    )
  end
  status:setText(online .. " of " .. #fleet.devices() .. " online")
end

main:addButton():setPosition(3, 18):setSize(14, 1):setText("Deploy all")
  :setBackground(colors.white):setForeground(colors.black)
  :onClick(function() fleet.deployAll(); refresh() end)

main:addButton():setPosition(19, 18):setSize(10, 1):setText("Recall")
  :setBackground(colors.gray):setForeground(colors.white)
  :onClick(function() fleet.recallAll(); refresh() end)

refresh()
```

Both work. The differences are not cosmetic:

**Coordinates.** Nine literal positions and sizes above, every one of which has to be
re-derived by hand when a column is added or the screen is a pocket computer instead of a
monitor. The layout solver's entire job is to make that arithmetic disappear.

**Colours at the call site.** `colors.white`, `colors.black`, `colors.gray`, `colors.red`.
Change the theme and you change every screen. This is the `ui.bar` problem again: the
button decided what a primary action looks like.

**`refresh()`.** The list is rebuilt from scratch, by hand, and every mutation has to
remember to call it. Forget one and the screen silently lies — which is the specific bug
class the fleet has already hit, in a different form, when closing the Fleet app disabled
sector leasing (D018). Binding `Rows = devices` means the table cannot be stale, because
nothing is copying anything.

**Derived state.** `online` is counted inside `refresh` and written into a label. Above it
is a `Computed`, so it cannot disagree with the list it is counting.

**Padding the label by hand.** `string.rep(" ", 12 - #d.label)` is `ui.pad` reinvented at
the call site, because a list item is a string and not a row of cells.

The measured consequence of the binding difference is in §12 of
[`ui-framework.md`](ui-framework.md): `refresh()` repaints the whole tree, which costs 81
terminal calls and 13,284 characters. Changing one bound value costs one call and one
character.

---

## 6. The component set

The list from §7 of [`ui-framework.md`](ui-framework.md), now with the variants and the
surface rule attached. This is the whole of it for ICOS 2; §15 explains why the list is
closed.

Built (**bold**) and planned:

**Layout** — **`Page`**, **`Row`**, **`Column`**, **`Box`**, **`Card`**, **`Separator`**,
**`Spacer`**, `ScrollView`, `Modal`, `Tabs`.

**Data** — **`Text`**, **`Heading`**, **`Muted`**, **`Table`**, **`Meter`**, **`Badge`**,
`List`, `Sparkline`, `Gauge`, `KeyValue`.

**Input** — **`Button`**, **`Stepper`**, **`Select`**, **`Toggle`**, `TextField`, `Menu`.
Buttons take clicks, touches, focus and keyboard activation. The other three are one family
and look like it: a label that takes the slack, a value in `accent`, and small ghost
controls on the right. Between them they cover every setting the fleet has — numbers, a job
from a fixed list, and the five policy booleans.

`TextField` is the one with real work behind it — a cursor, a selection and an edit model —
and nothing has asked for it yet. `Menu` likewise.

Three rules the family shares, each of them a decision:

- **One tab stop, not three.** The row is focusable and its two arrows deliberately are
  not. A person with a mouse presses them; a person on a turtle tabs to the row and uses
  left and right. Otherwise a page of six settings would take eighteen presses to cross.
- **`Select` cycles rather than dropping down.** A dropdown needs somewhere to drop: on 51
  columns it covers the thing being configured, and on a monitor it is a floating panel a
  touch can miss with no hover to hint that it opened. Four or five options is the working
  limit; past that the list wants a page of its own.
- **`Toggle` says "on" or "off".** Not a two-cell switch whose states differ by which end
  is lit — that does not read across a room, and on a non-advanced terminal both ends are
  the same grey. The word carries it and the colour reinforces it, which is §2's rule about
  never encoding meaning in colour alone.

All three report intent through `OnChange` and never write their own value, because in the
fleet a setting change is a message to a parked turtle that may refuse it.

**Feedback** — `Toast`, `Spinner`, `Skeleton`, `Empty`, `Banner`.

**Graphics** — **`Canvas`**, **`Sprite`**, `Logo`.

`Page` is the one that does not exist in Basalt and carries most of the consistency. It
owns the title, the status line, the separators, and the action row, so every screen in
ICOS has the same anatomy without every screen re-deciding it. An app supplies `Title`,
`Children`, and `Actions`; it does not get to draw its own header.

`Table` is the other composite, and the one where the performance claim meets something
real. It builds a fixed pool of row slots once and never rebuilds them; each cell is a
`Computed` that indexes into the list, so a device leaving the roster changes what four
cells say rather than destroying four nodes. That is virtualisation arrived at from the
other direction — a stable binding graph over a changing list — and it is the reason a
heartbeat costs one blit rather than a table's worth.

---

## 7. What makes it easier, in one list

Everything above reduces to four things, and they are the acceptance criteria for phase 2.

1. **No coordinates.** If a screen contains a literal `x` or `y`, the layout solver has
   failed at its only job.
2. **No colours.** If a screen names a colour rather than a token, the theme is not data.
3. **No redraw calls.** If a screen calls something to make the display catch up, the
   binding is not doing its job and the screen can be stale.
4. **No stale derived values.** Anything computed from state is a `Computed`, so it cannot
   disagree with what it was computed from.

A phase 2 review that finds any of the four in a rebuilt Devices screen has found a missing
framework feature, not a sloppy screen.

---

## 8. Deliberately not included

- **Rounded corners, shadows, gradients.** No representation at cell resolution that is not
  more noise than signal.
- **Hover states.** A monitor touch has no hover (§9 of the framework plan). Anything that
  depends on hover is unusable on exactly the surface the fleet dashboard lives on. This
  is now enforced by the shape of the event model rather than by discipline: there is no
  hover event to bind.
- **A grid layout, wrapping, percentage units.** Flex covers a dashboard and a card table.
  Add them when a second app needs them.
- **Icons.** The 2×3 glyphs can draw one in a 2×2 cell block. Everything tried so far reads
  as a smudge at monitor scale; the word is shorter and clearer. Revisit with the canvas.
- **A dense mode.** Tempting on 164×81, but a second density doubles the spacing decisions
  and every component has to be checked in both. One scale, chosen for the smallest useful
  screen.
