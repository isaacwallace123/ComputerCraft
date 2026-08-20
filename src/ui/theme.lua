--- Semantic colour tokens, and the sixteen palette slots behind them.
---
--- The rule this file exists to enforce: **a component names a role, never a
--- colour.** It asks for `destructive` and the theme decides what that is.
---
--- The alternative is what `legacy/shell/ui.lua` does today - `ui.bar` hard-codes red
--- below 15% and yellow below 40%, which means the bar decided what a low fuel
--- reading means, and changing that decision means finding every bar. There are
--- only sixteen colours available, so the temptation to reach for one directly
--- is constant; the discipline has to be structural.
---
--- See docs/ui-design.md for the reasoning behind each value, and run
--- `tools\preview.ps1` to look at them.
---
--- ## Slot numbers are not arbitrary
---
--- A CC terminal clears to slot 15 and writes in slot 0. Putting `background` at
--- 15 and `foreground` at 0 means a freshly cleared screen is already the right
--- colours, and a component that forgets to set one is not obviously broken.
---
--- ## Why there is no `info`
---
--- There was, and it was cut rather than retuned. A non-advanced terminal
--- renders every slot as its greyscale average, so tokens that differ only in
--- hue become indistinguishable; four semantic tones plus two text greys do not
--- fit on that one axis with room to spare. `info` named nothing the fleet
--- reports, so dropping it bought every remaining pair about ten points of
--- separation. A fifth semantic colour has to win that trade.

local theme = {}

--- Token name -> palette slot. Stable: these numbers travel into every blit
--- string the renderer produces, so changing one changes what is on screen
--- everywhere at once, which is the point.
theme.TOKENS = {
  foreground = 0,
  primary = 1,
  primaryFg = 2,
  mutedFg = 3,
  border = 4,
  muted = 5,
  card = 6,
  accent = 7,
  accentFg = 8,
  good = 9,
  warn = 10,
  destructive = 11,
  free1 = 12,
  free2 = 13,

  -- The window manager's own colour, and the one token that is not about the
  -- content. A top bar in `primary` is fifty-one cells of near-white across the
  -- top of every screen, which is the loudest thing on a wall monitor and is
  -- competing with the data rather than framing it. Chrome is indigo: clearly
  -- not part of the page, and dark enough in both themes to sit still.
  --
  -- It takes the slot `free3` had. The free slots are for an app that wants a
  -- chart series or a card suit, and nothing has ever wanted one; a bar that
  -- every machine draws at all times has a better claim on a palette entry.
  chrome = 14,

  background = 15,
}

--- What reads on `chrome`.
---
--- The same slot as `primaryFg`, deliberately, because the requirement is
--- identical - text that reads on a saturated block - and a sixteen-slot palette
--- cannot afford a second near-black. Named separately so a component asks for
--- the role it means, which is this file's whole rule.
theme.TOKENS.chromeFg = theme.TOKENS.primaryFg

--- Tokens a person has to be able to tell apart, because they can appear in the
--- same place. A status column shows `good`, `warn`, `destructive`, and
--- `mutedFg` for a parked turtle, so all four compete; the free slots do not,
--- because a chart series is not a status.
theme.SEMANTIC = { "good", "warn", "destructive", "mutedFg", "foreground" }

local T = theme.TOKENS

--- Dark is the default because a monitor wall in a dark base is the normal
--- viewing condition, and a bright page is a lamp on the wall.
---
--- The semantic three are chosen against two constraints at once, which is why
--- they are not the obvious picks: at least 4.5:1 contrast against the page, and
--- at least 20 points of greyscale apart so the meaning survives a non-advanced
--- terminal. `good` is the darker green rather than the mint one and `warn` is a
--- pale amber rather than a saturated one entirely to open that gap.
theme.dark = {
  name = "dark",
  [T.background] = 0x09090B,
  [T.card] = 0x18181B,
  [T.muted] = 0x27272A,
  [T.border] = 0x3F3F46,
  [T.mutedFg] = 0xA1A1AA,
  [T.foreground] = 0xFAFAFA,
  [T.primary] = 0xE4E4E7,
  [T.primaryFg] = 0x18181B,
  [T.accent] = 0x38BDF8,
  [T.accentFg] = 0x082F49,
  [T.good] = 0x22C55E,
  [T.destructive] = 0xF43F5E,
  [T.warn] = 0xFDE68A,
  [T.free1] = 0xC084FC,
  [T.free2] = 0x2DD4BF,
  [T.chrome] = 0x818CF8,
}

--- Light has less room: every token has to be dark enough to read on white, so
--- the whole semantic set is squeezed into the bottom half of the luminance
--- range. Its tightest separation is 18 points against 25 for dark, which is a
--- real and unavoidable difference between the two.
theme.light = {
  name = "light",
  [T.background] = 0xFFFFFF,
  [T.card] = 0xFAFAFA,
  [T.muted] = 0xF4F4F5,
  [T.border] = 0xE4E4E7,
  [T.mutedFg] = 0x71717A,
  [T.foreground] = 0x09090B,
  [T.primary] = 0x18181B,
  [T.primaryFg] = 0xFAFAFA,
  [T.accent] = 0x0284C7,
  [T.accentFg] = 0xF0F9FF,
  [T.good] = 0x14532D,
  [T.warn] = 0x854D0E,
  [T.destructive] = 0xDC2626,
  [T.free1] = 0x9333EA,
  [T.free2] = 0x0D9488,
  [T.chrome] = 0x4F46E5,
}

--- Push a palette onto a screen.
---
--- Sixteen calls, once, at startup and on a theme change - never per frame. On a
--- non-advanced terminal these still take effect and are rendered as greyscale
--- averages, so this is not gated on `isColour`: a standard computer gets the
--- theme flattened to luminance, which is better than the default palette and is
--- why `greyscale` below is a real check rather than a nicety.
function theme.apply(screen, palette)
  for index = 0, 15 do
    local value = palette[index]
    if value then
      local r = math.floor(value / 65536) % 256
      local g = math.floor(value / 256) % 256
      local b = value % 256
      screen.setPalette(index, r / 255, g / 255, b / 255)
    end
  end
end

--- What a non-advanced terminal shows for a slot.
function theme.greyscale(value)
  local r = math.floor(value / 65536) % 256
  local g = math.floor(value / 256) % 256
  local b = value % 256
  return math.floor((r + g + b) / 3)
end

--- How far apart the semantic tokens land once colour is removed, and which pair
--- is closest.
---
--- This is a real check with a real threshold, and it earned its place on its
--- first run: the palette written before it put `warn` and `destructive` one
--- point apart, which nobody would have noticed until somebody ran the fleet
--- from a standard computer and could not tell a full depot from an open shaft.
---
--- It does not remove the standing rule, which no palette can: **never encode
--- meaning in colour alone.** The status column says "no cap block"; the colour
--- only makes it findable faster.
function theme.separation(palette)
  local entries = {}
  for _, name in ipairs(theme.SEMANTIC) do
    entries[#entries + 1] = { name = name, grey = theme.greyscale(palette[T[name]]) }
  end
  table.sort(entries, function(a, b)
    return a.grey < b.grey
  end)

  local worst, pair = 255, ""
  for index = 2, #entries do
    local delta = entries[index].grey - entries[index - 1].grey
    if delta < worst then
      worst = delta
      pair = entries[index - 1].name .. "/" .. entries[index].name
    end
  end
  return worst, pair, entries
end

return theme
