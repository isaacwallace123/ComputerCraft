--- The proposed ICOS look, painted for real and dumped to your terminal.
---
--- Run with `tools\preview.ps1`.
---
--- Everything below is painted through `src/ui/buffer.lua` at true CC terminal
--- sizes, then written out as ANSI truecolour. So this is not a mockup in a
--- drawing program - it is the actual renderer, the actual cell grid, and the
--- actual sixteen palette entries a computer would have. If it looks right
--- here it looks right in game.
---
--- The theme lives in this file rather than in `src/ui/theme.lua` on purpose:
--- the framework has no component layer yet, and shipping a theme that nothing
--- consumes would put dead code on ten turtles. Phase 5 promotes it.

package.path = table.concat({
  "src/?.lua",
  "tools/spec/?.lua",
  package.path,
}, ";")

local buffer = require("ui.buffer")

---------------------------------------------------------------------------
-- The palette
---------------------------------------------------------------------------

--- Sixteen slots, named by role rather than by colour.
---
--- The names are shadcn's, because the discipline is the transferable part: a
--- component never names a colour, it names a role, and swapping the theme is
--- then data rather than a search across every file. `ui.bar` picking red below
--- 15% is exactly the coupling this removes - the bar should ask for
--- `destructive` and let the theme decide what that is.
---
--- Slot numbers matter. 15 is the background because a CC terminal clears to
--- slot 15, so a cleared screen is already the right colour; 0 is the
--- foreground for the same reason in reverse.
local TOKENS = {
  foreground = 0, -- primary text
  primary = 1, -- solid action surface. Near-white in dark, near-black in light
  primaryFg = 2, -- text on `primary`
  mutedFg = 3, -- secondary text: labels, hints, column headings
  border = 4, -- hairlines and separators
  muted = 5, -- recessed fill: input wells, table stripes, disabled
  card = 6, -- raised surface, one step above the page
  accent = 7, -- the one colour that means "this"
  accentFg = 8, -- text on `accent`
  good = 9,
  warn = 10,
  destructive = 11,
  free1 = 12, -- app-owned: chart series, card suits, a game
  free2 = 13,
  free3 = 14,
  background = 15, -- the page itself
}

--- Tokens whose values a person has to be able to tell apart, because they can
--- appear in the same place. A status column shows `good`, `warn`,
--- `destructive`, and `mutedFg` for a parked turtle, so all four compete; the
--- free slots do not, because a chart series is not a status.
---
--- There used to be an `info` token here. It was cut rather than retuned: it
--- said nothing the fleet reports, and four semantic tones plus two text greys
--- do not fit on one luminance axis with room to spare (see the report at the
--- bottom of this file). Dropping the one nobody needed bought every other pair
--- about ten points of separation.
local SEMANTIC = { "good", "warn", "destructive", "mutedFg", "foreground" }

--- Dark is the default because a monitor wall in a dark base is the normal
--- viewing condition, and a bright page is a lamp on the wall.
local DARK = {
  [TOKENS.background] = 0x09090B,
  [TOKENS.card] = 0x18181B,
  [TOKENS.muted] = 0x27272A,
  [TOKENS.border] = 0x3F3F46,
  [TOKENS.mutedFg] = 0xA1A1AA,
  [TOKENS.foreground] = 0xFAFAFA,
  [TOKENS.primary] = 0xE4E4E7,
  [TOKENS.primaryFg] = 0x18181B,
  [TOKENS.accent] = 0x38BDF8,
  [TOKENS.accentFg] = 0x082F49,
  -- Chosen against two constraints at once, which is most of why they are not
  -- the obvious Tailwind picks: at least 4.5:1 against the page so the text is
  -- readable, and at least 20 points of greyscale apart so the meaning survives
  -- a non-advanced terminal. `good` is the darker green rather than the mint
  -- one, and `warn` is a pale amber rather than a saturated one, entirely to
  -- open that gap.
  [TOKENS.good] = 0x22C55E, -- grey 108, contrast 8.7
  [TOKENS.destructive] = 0xF43F5E, -- grey 133, contrast 5.4
  [TOKENS.warn] = 0xFDE68A, -- grey 207, contrast 16.0
  [TOKENS.free1] = 0xC084FC,
  [TOKENS.free2] = 0x2DD4BF,
  [TOKENS.free3] = 0x818CF8,
}

local LIGHT = {
  [TOKENS.background] = 0xFFFFFF,
  [TOKENS.card] = 0xFAFAFA,
  [TOKENS.muted] = 0xF4F4F5,
  [TOKENS.border] = 0xE4E4E7,
  [TOKENS.mutedFg] = 0x71717A,
  [TOKENS.foreground] = 0x09090B,
  [TOKENS.primary] = 0x18181B,
  [TOKENS.primaryFg] = 0xFAFAFA,
  [TOKENS.accent] = 0x0284C7,
  [TOKENS.accentFg] = 0xF0F9FF,
  -- Light has less room: everything has to be dark enough to read on white, so
  -- the whole semantic set is squeezed into the bottom half of the luminance
  -- range. The separation here is 18 points at its tightest against 25 for
  -- dark, which is a real and unavoidable difference between the two themes.
  [TOKENS.good] = 0x14532D, -- grey 49
  [TOKENS.warn] = 0x854D0E, -- grey 74
  [TOKENS.destructive] = 0xDC2626, -- grey 98
  [TOKENS.free1] = 0x9333EA,
  [TOKENS.free2] = 0x0D9488,
  [TOKENS.free3] = 0x4F46E5,
}

local T = TOKENS

---------------------------------------------------------------------------
-- Terminal output
---------------------------------------------------------------------------

local ESC = string.char(27)

local function rgb(value)
  return math.floor(value / 65536) % 256, math.floor(value / 256) % 256, value % 256
end

local function fgSeq(value)
  return ("%s[38;2;%d;%d;%dm"):format(ESC, rgb(value))
end

local function bgSeq(value)
  return ("%s[48;2;%d;%d;%dm"):format(ESC, rgb(value))
end

local RESET = ESC .. "[0m"

--- A screen port that keeps the cells so they can be printed.
local function capture(width, height)
  local cells = {}
  for y = 1, height do
    cells[y] = { text = string.rep(" ", width), fg = string.rep("0", width), bg = string.rep("f", width) }
  end
  local HEX = buffer.HEX
  local port = {
    size = function()
      return width, height
    end,
    blit = function(x, y, text, fg, bg)
      local row = cells[y]
      local function splice(into, part)
        return into:sub(1, x - 1) .. part .. into:sub(x + #part)
      end
      row.text, row.fg, row.bg = splice(row.text, text), splice(row.fg, fg), splice(row.bg, bg)
    end,
    clear = function() end,
    isColour = function()
      return true
    end,
    setPalette = function() end,
    setCursor = function() end,
  }
  local function index(char)
    return (HEX:find(char, 1, true) or 1) - 1
  end
  return port, cells, index
end

--- Print a captured grid, with a border so the edges of the screen are visible.
local function show(cells, palette, indexOf, width, label)
  local frameFg = 0x52525B
  print("")
  print(("  %s%s%s  %s%d x %d%s"):format(fgSeq(0xFAFAFA), label, RESET, fgSeq(frameFg), width, #cells, RESET))
  print(("  %s+%s+%s"):format(fgSeq(frameFg), string.rep("-", width), RESET))
  for y = 1, #cells do
    local row = cells[y]
    local out = { ("  %s|%s"):format(fgSeq(frameFg), RESET) }
    local lastFg, lastBg
    for x = 1, width do
      local fg = palette[indexOf(row.fg:sub(x, x))]
      local bg = palette[indexOf(row.bg:sub(x, x))]
      if fg ~= lastFg then
        out[#out + 1] = fgSeq(fg)
        lastFg = fg
      end
      if bg ~= lastBg then
        out[#out + 1] = bgSeq(bg)
        lastBg = bg
      end
      out[#out + 1] = row.text:sub(x, x)
    end
    out[#out + 1] = RESET .. fgSeq(frameFg) .. "|" .. RESET
    print(table.concat(out))
  end
  print(("  %s+%s+%s"):format(fgSeq(frameFg), string.rep("-", width), RESET))
end

---------------------------------------------------------------------------
-- Painting helpers, which are what the component layer will do for you
---------------------------------------------------------------------------

local function pad(text, width, align)
  text = tostring(text)
  if #text >= width then
    return text:sub(1, width)
  end
  local slack = width - #text
  if align == "right" then
    return string.rep(" ", slack) .. text
  end
  if align == "center" then
    local left = math.floor(slack / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", slack - left)
  end
  return text .. string.rep(" ", slack)
end

--- A card: a raised surface, drawn as a background change and nothing else.
---
--- This is the single most important adaptation of the shadcn look. On the web
--- a card is a 1-pixel border and a shadow, both of which are far thinner than
--- the text beside them. The nearest thing on a character grid is a box of
--- `+---+`, which is a full cell wide and therefore reads as *heavier* than the
--- content it surrounds - the opposite of the intended effect.
---
--- So elevation replaces outline. A card is a rectangle painted one step
--- lighter than the page, with no drawn edge at all. It reads as a panel at a
--- glance, costs no cells to the border, and degrades correctly on a
--- non-advanced terminal where the two greys stay distinguishable.
local function card(frame, x, y, width, height)
  frame:fill(x, y, width, height, " ", T.foreground, T.card)
end

--- A separator: one row of `border` as a background. The closest a cell grid
--- gets to a hairline, and used sparingly - elevation does most of this work.
local function separator(frame, x, y, width)
  frame:fill(x, y, width, 1, " ", T.border, T.border)
end

--- A button, in the four variants that turn out to be enough.
---
--- `primary` is a solid near-white slab with dark text, which is shadcn's dark
--- theme and looks startlingly good on a monitor. `secondary` is the recessed
--- fill. `ghost` is text on the surface it sits on. `destructive` is the only
--- one that is allowed to be a colour, which is what makes it read as a warning
--- rather than as decoration.
local VARIANTS = {
  primary = { fg = T.primaryFg, bg = T.primary },
  secondary = { fg = T.foreground, bg = T.muted },
  ghost = { fg = T.mutedFg, bg = nil },
  destructive = { fg = T.primaryFg, bg = T.destructive },
}

local function button(frame, x, y, label, variant, surface, focused)
  local style = VARIANTS[variant] or VARIANTS.secondary
  local bg = style.bg or surface
  local width = #label + 4
  frame:write(x, y, pad(" " .. label .. " ", width, "center"), style.fg, bg)
  -- The focus ring, one cell wide in the left gutter. A full outline would cost
  -- two rows and two columns; a gutter marker costs one column and is the only
  -- thing on screen that uses `accent` as a background, so it is unmistakable.
  if focused then
    frame:write(x - 1, y, " ", T.accentFg, T.accent)
  end
  return width
end

local function badge(frame, x, y, label, tone, surface)
  frame:write(x, y, " " .. label .. " ", tone, surface)
  return #label + 2
end

---------------------------------------------------------------------------
-- Screen one: the Fleet dashboard
---------------------------------------------------------------------------

local ROWS = {
  { id = 1, label = "miner-1", phase = "mining", fuel = 51200, pct = 0.82, tone = T.good },
  { id = 2, label = "miner-2", phase = "returning", fuel = 12400, pct = 0.31, tone = T.good },
  { id = 3, label = "miner-3", phase = "unloading", fuel = 47800, pct = 0.77, tone = T.good },
  { id = 4, label = "miner-4", phase = "no cap block", fuel = 640, pct = 0.02, tone = T.destructive },
  { id = 5, label = "miner-5", phase = "parked", fuel = 33100, pct = 0.55, tone = T.mutedFg },
  { id = 6, label = "miner-6", phase = "mining", fuel = 28900, pct = 0.48, tone = T.good },
}

local function count(value)
  if value >= 1000 then
    return ("%.1fk"):format(value / 1000)
  end
  return tostring(value)
end

local function paintFleet(frame)
  local width, height = frame:size()
  frame:clear(T.foreground, T.background)

  -- Header. No filled title bar: the page title is just the largest text on the
  -- screen, and a separator does the dividing. A solid coloured bar across the
  -- top is the single most dated thing about the current UI.
  frame:write(3, 2, "Fleet", T.foreground, T.background)
  local online = "4 of 6 online"
  frame:write(width - #online - 1, 2, online, T.mutedFg, T.background)
  separator(frame, 1, 3, width)

  frame:write(3, 5, pad("DEVICE", 12), T.mutedFg, T.background)
  frame:write(15, 5, pad("STATUS", 14), T.mutedFg, T.background)
  frame:write(29, 5, pad("FUEL", 7, "right"), T.mutedFg, T.background)

  for index, row in ipairs(ROWS) do
    local y = 6 + index
    local selected = index == 4
    local surface = selected and T.muted or T.background
    if selected then
      frame:fill(1, y, width, 1, " ", T.foreground, T.muted)
      frame:write(1, y, " ", T.accentFg, T.accent)
    end
    frame:write(3, y, pad(row.label, 12), T.foreground, surface)
    frame:write(15, y, pad(row.phase, 14), row.tone, surface)
    frame:write(29, y, pad(count(row.fuel), 7, "right"), T.mutedFg, surface)

    -- The meter. Track recessed, fill in `accent`, no border and no percentage
    -- label - the width is the number.
    --
    -- The track colour is chosen from the surface rather than fixed, and this
    -- is the one rule that elevation-instead-of-outline makes mandatory. A
    -- `muted` track on a `muted` selected row is invisible; the first version
    -- of this preview had exactly that bug and the selected turtle silently
    -- lost its fuel bar. On the web there are enough shades to always have one
    -- to spare. With sixteen slots there are not, so every component that
    -- recesses or raises has to be told what it is sitting on.
    local barX, barWidth = 38, 10
    local track = surface == T.muted and T.border or T.muted
    local filled = math.floor(row.pct * barWidth + 0.5)
    frame:fill(barX, y, barWidth, 1, " ", T.foreground, track)
    if filled > 0 then
      frame:fill(barX, y, filled, 1, " ", T.foreground, row.pct < 0.15 and T.destructive or T.accent)
    end
  end

  separator(frame, 1, height - 2, width)
  local x = 3
  x = x + button(frame, x, height - 1, "Deploy all", "primary", T.background) + 2
  x = x + button(frame, x, height - 1, "Recall", "secondary", T.background) + 2
  button(frame, x, height - 1, "Stop", "destructive", T.background)
end

---------------------------------------------------------------------------
-- Screen two: the component sampler
---------------------------------------------------------------------------

local function paintSampler(frame)
  local width = frame:size()
  frame:clear(T.foreground, T.background)

  frame:write(3, 2, "Components", T.foreground, T.background)
  separator(frame, 1, 3, width)

  frame:write(3, 5, "BUTTON", T.mutedFg, T.background)
  local x = 3
  x = x + button(frame, x, 6, "Primary", "primary", T.background) + 2
  x = x + button(frame, x, 6, "Secondary", "secondary", T.background) + 2
  button(frame, x, 6, "Ghost", "ghost", T.background)

  x = 4
  x = x + button(frame, x, 7, "Focused", "secondary", T.background, true) + 2
  button(frame, x, 7, "Delete", "destructive", T.background)

  frame:write(3, 9, "BADGE", T.mutedFg, T.background)
  x = 3
  x = x + badge(frame, x, 10, "online", T.good, T.muted) + 1
  x = x + badge(frame, x, 10, "stalled", T.warn, T.muted) + 1
  x = x + badge(frame, x, 10, "open shaft", T.destructive, T.muted) + 1
  badge(frame, x, 10, "idle", T.mutedFg, T.muted)

  frame:write(3, 12, "CARD", T.mutedFg, T.background)
  card(frame, 3, 13, 22, 5)
  frame:write(5, 14, "Sector 12", T.foreground, T.card)
  frame:write(5, 15, "shaft sealed", T.mutedFg, T.card)
  frame:write(5, 16, "137 blocks", T.mutedFg, T.card)

  frame:write(28, 12, "INPUT", T.mutedFg, T.background)
  frame:fill(28, 13, 21, 1, " ", T.foreground, T.muted)
  frame:write(29, 13, "-59", T.foreground, T.muted)
  frame:write(28, 15, "target depth", T.mutedFg, T.background)
  frame:fill(28, 16, 21, 1, " ", T.foreground, T.muted)
  frame:write(29, 16, "diamond", T.mutedFg, T.muted)
end

---------------------------------------------------------------------------
-- The greyscale check §11 asks for
---------------------------------------------------------------------------

local function greyscale(value)
  local r, g, b = rgb(value)
  return math.floor((r + g + b) / 3)
end

--- A non-advanced terminal renders every palette entry as `(r+g+b)/3`, so two
--- tokens that differ only in hue become the same grey. The row that says a
--- turtle is stuck then looks exactly like the row that says it is fine.
---
--- This is a real check with a real threshold, and it has already earned its
--- place: the first palette written for this preview put `warn` and
--- `destructive` **one point apart**, which nobody would have noticed until
--- somebody ran the fleet from a standard computer and could not tell a full
--- depot from an open shaft.
---
--- 20 points is the target. Dark clears it; light does not quite, and that is
--- reported rather than hidden - a light theme has to fit every token into the
--- dark half of the range to stay readable on white, so it has less room by
--- construction.
---
--- The standing rule, which no palette removes the need for: **never encode
--- meaning in colour alone.** The status column says "no cap block", and the
--- colour only makes it findable faster.
local function reportGreyscale(palette, label)
  local values = {}
  for _, name in ipairs(SEMANTIC) do
    values[#values + 1] = { name = name, index = TOKENS[name], grey = greyscale(palette[TOKENS[name]]) }
  end
  table.sort(values, function(a, b)
    return a.grey < b.grey
  end)

  local worst, worstPair = 255, ""
  for i = 2, #values do
    local delta = values[i].grey - values[i - 1].grey
    if delta < worst then
      worst, worstPair = delta, values[i - 1].name .. " / " .. values[i].name
    end
  end

  print("")
  print(("  %sgreyscale separation, %s%s  %s(all a non-advanced terminal shows)%s"):format(
    fgSeq(0xFAFAFA),
    label,
    RESET,
    fgSeq(0x71717A),
    RESET
  ))
  for i, entry in ipairs(values) do
    local gap = i > 1 and ("+%d"):format(entry.grey - values[i - 1].grey) or ""
    local swatch = bgSeq(palette[entry.index]) .. "    " .. RESET
    local grey = greyscale(palette[entry.index])
    local greySwatch = bgSeq(grey * 65536 + grey * 256 + grey) .. "    " .. RESET
    print(("    %s %s  %s%s %s%3d  %s%s"):format(
      swatch,
      greySwatch,
      fgSeq(0xE4E4E7),
      pad(entry.name, 12),
      fgSeq(0xA1A1AA),
      entry.grey,
      gap,
      RESET
    ))
  end
  local ok = worst >= 20
  print(("    %sclosest pair %s, %d apart - %s%s"):format(
    fgSeq(ok and 0x22C55E or 0xFDE68A),
    worstPair,
    worst,
    ok and "clears the 20 point target" or "under target, usable but tight",
    RESET
  ))
end

---------------------------------------------------------------------------

local function render(paint, palette, label)
  local width, height = 51, 19
  local port, cells, indexOf = capture(width, height)
  local frame = buffer.new(port, width, height)
  paint(frame)
  frame:present()
  show(cells, palette, indexOf, width, label)
end

print(("%sICOS 2 - proposed look%s"):format(fgSeq(0xFAFAFA), RESET))
print(("%s  painted through src/ui/buffer.lua at a real 51x19 computer terminal%s"):format(
  fgSeq(0xA1A1AA),
  RESET
))

render(paintFleet, DARK, "Fleet, dark")
render(paintSampler, DARK, "Components, dark")
render(paintFleet, LIGHT, "Fleet, light")

reportGreyscale(DARK, "dark")
reportGreyscale(LIGHT, "light")
print("")
