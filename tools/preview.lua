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
--- The palettes here mirror `src/ui/theme.lua`, which is where they live now.
--- They are duplicated rather than imported so that a person can edit one and
--- see the result without touching shipped code; if they drift, the theme file
--- is the one that is right.

package.path = table.concat({
  "src/?.lua",
  "tools/spec/?.lua",
  package.path,
}, ";")

local buffer = require("ui.render.buffer")

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
    cells[y] =
      { text = string.rep(" ", width), fg = string.rep("0", width), bg = string.rep("f", width) }
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
local function show(cells, palette, indexOf, width, label, blits)
  local frameFg = 0x52525B
  print("")
  print(
    ("  %s%s%s  %s%d x %d, %d blits%s"):format(
      fgSeq(0xFAFAFA),
      label,
      RESET,
      fgSeq(frameFg),
      width,
      #cells,
      blits or 0,
      RESET
    )
  )
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
-- The screens, built with the real framework
---------------------------------------------------------------------------

local ui = require("ui.init")
local fleetScreen = require("apps.fleet.view")
local devicesScreen = require("apps.devices.view")

local ROSTER = {
  { id = 1, label = "miner-1", phase = "mining", fuel = 82000, fuelLimit = 100000, online = true },
  {
    id = 2,
    label = "miner-2",
    phase = "returning",
    fuel = 31000,
    fuelLimit = 100000,
    online = true,
  },
  {
    id = 3,
    label = "miner-3",
    phase = "unloading",
    fuel = 77000,
    fuelLimit = 100000,
    online = true,
  },
  {
    id = 4,
    label = "miner-4",
    phase = "no cap block",
    fuel = 2000,
    fuelLimit = 100000,
    online = true,
    alert = true,
  },
  { id = 5, label = "miner-5", phase = "parked", fuel = 55000, fuelLimit = 100000, online = false },
  { id = 6, label = "miner-6", phase = "mining", fuel = 48000, fuelLimit = 100000, online = true },
}

local function buildFleet(scope)
  return fleetScreen.build(scope, {
    devices = scope:Value(ROSTER),
    selected = scope:Value(4),
    capacity = 6,
    onDeploy = function() end,
    onRecall = function() end,
    onStop = function() end,
  })
end

--- The densest page in ICOS: a list, a detail panel, selection, and scrolling.
--- The acceptance test section 14 of the framework plan set for the project.
local function buildDevices(scope)
  local roster = {}
  for index, entry in ipairs(ROSTER) do
    roster[index] = {
      id = entry.id,
      label = entry.label,
      phase = entry.phase,
      job = index % 2 == 0 and "rare" or "resources",
      fuel = entry.fuel,
      fuelLimit = entry.fuelLimit,
      since = index * 47,
      alert = entry.alert,
    }
  end
  local selected = scope:Value(4)
  return devicesScreen.build(scope, {
    devices = scope:Value(roster),
    selected = selected,
    capacity = 6,
    onSelect = function(device)
      selected:set(device.id)
    end,
    onDeploy = function() end,
    onRecall = function() end,
    onStop = function() end,
    onSetting = function() end,
  })
end

--- The same page with the settings editor showing, which is the half of the
--- acceptance test in section 14 that the first rebuild missed.
local function buildSettings(scope)
  local roster = {}
  for index, entry in ipairs(ROSTER) do
    roster[index] = {
      id = entry.id,
      label = entry.label,
      phase = index == 5 and "parked" or entry.phase,
      job = "rare",
      fuel = entry.fuel,
      fuelLimit = entry.fuelLimit,
      since = index * 47,
      settings = { targetY = -59, veinBudget = 64, veinRadius = 8, scanEvery = 100 },
    }
  end
  local selected = scope:Value(5)
  return devicesScreen.build(scope, {
    devices = scope:Value(roster),
    selected = selected,
    capacity = 6,
    editing = scope:Value(true),
    onSelect = function(device)
      selected:set(device.id)
    end,
    onSetting = function() end,
  })
end

--- Every component, on one page, so a change to the design system can be seen
--- rather than reasoned about.
local function buildSampler(scope)
  local T = ui.tokens
  return scope:Page({
    Title = "Components",
    Children = {
      scope:Muted({ Text = "BUTTON" }),
      scope:Row({
        Gap = 2,
        Height = 1,
        Children = {
          scope:Button({ Text = "Primary", Variant = "primary" }),
          scope:Button({ Text = "Secondary" }),
          scope:Button({ Text = "Ghost", Variant = "ghost" }),
        },
      }),
      scope:Row({
        Gap = 2,
        Height = 1,
        Children = {
          scope:Button({ Text = "Focused", Focused = true }),
          scope:Button({ Text = "Delete", Variant = "destructive" }),
          scope:Button({ Text = "Disabled", Disabled = true }),
        },
      }),
      scope:Spacer({ Height = 1 }),

      scope:Muted({ Text = "BADGE" }),
      scope:Row({
        Gap = 1,
        Height = 1,
        Children = {
          scope:Badge({ Text = "online", Tone = T.good }),
          scope:Badge({ Text = "stalled", Tone = T.warn }),
          scope:Badge({ Text = "open shaft", Tone = T.destructive }),
          scope:Badge({ Text = "idle" }),
        },
      }),
      scope:Spacer({ Height = 1 }),

      scope:Muted({ Text = "CARD  and  METER" }),
      scope:Row({
        Gap = 2,
        Grow = 1,
        Children = {
          scope:Card({
            Width = 22,
            Padding = 1,
            Children = {
              scope:Text({ Text = "Sector 12" }),
              scope:Muted({ Text = "shaft sealed" }),
              scope:Muted({ Text = "137 blocks" }),
            },
          }),
          scope:Column({
            Grow = 1,
            Gap = 1,
            Children = {
              scope:Meter({ Value = 0.82, Height = 1 }),
              scope:Meter({ Value = 0.31, Height = 1 }),
              scope:Meter({ Value = 0.05, Tint = T.destructive, Height = 1 }),
            },
          }),
        },
      }),
    },
    Actions = {
      scope:Button({ Text = "Save", Variant = "primary" }),
      scope:Button({ Text = "Cancel", Variant = "ghost" }),
    },
  })
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
    values[#values + 1] =
      { name = name, index = TOKENS[name], grey = greyscale(palette[TOKENS[name]]) }
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
  print(
    ("  %sgreyscale separation, %s%s  %s(all a non-advanced terminal shows)%s"):format(
      fgSeq(0xFAFAFA),
      label,
      RESET,
      fgSeq(0x71717A),
      RESET
    )
  )
  for i, entry in ipairs(values) do
    local gap = i > 1 and ("+%d"):format(entry.grey - values[i - 1].grey) or ""
    local swatch = bgSeq(palette[entry.index]) .. "    " .. RESET
    local grey = greyscale(palette[entry.index])
    local greySwatch = bgSeq(grey * 65536 + grey * 256 + grey) .. "    " .. RESET
    print(
      ("    %s %s  %s%s %s%3d  %s%s"):format(
        swatch,
        greySwatch,
        fgSeq(0xE4E4E7),
        ui.format.pad(entry.name, 12),
        fgSeq(0xA1A1AA),
        entry.grey,
        gap,
        RESET
      )
    )
  end
  local ok = worst >= 20
  print(
    ("    %sclosest pair %s, %d apart - %s%s"):format(
      fgSeq(ok and 0x22C55E or 0xFDE68A),
      worstPair,
      worst,
      ok and "clears the 20 point target" or "under target, usable but tight",
      RESET
    )
  )
end

---------------------------------------------------------------------------

--- Mount a screen, render one frame, and print the cells.
---
--- Through the whole stack - reactive graph, layout solver, components, cell
--- diff, screen port - at a real terminal size. Nothing here is a mockup, and
--- the blit count is reported beside each screen because a preview that looked
--- right while costing a full repaint would be hiding the thing that matters.
local function render(build, palette, label)
  local width, height = 51, 19
  local port, cells, indexOf = capture(width, height)
  local scope = ui.scoped()
  local root = ui.mount({ scope = scope, screen = port, build = build })
  local blits = root:render()
  show(cells, palette, indexOf, width, label, blits)
  root:destroy()
end

print(("%sICOS 2 - proposed look%s"):format(fgSeq(0xFAFAFA), RESET))
print(
  ("%s  painted through src/ui/buffer.lua at a real 51x19 computer terminal%s"):format(
    fgSeq(0xA1A1AA),
    RESET
  )
)

render(buildFleet, DARK, "Fleet, dark")
render(buildDevices, DARK, "Devices, dark")
render(buildSettings, DARK, "Devices settings, dark")
render(buildSampler, DARK, "Components, dark")
render(buildFleet, LIGHT, "Fleet, light")

reportGreyscale(DARK, "dark")
reportGreyscale(LIGHT, "light")
print("")
