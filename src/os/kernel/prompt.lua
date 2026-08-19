--- Asking a person something, before the framework exists.
---
--- Setup runs on a machine with no role, which means no composition root, no
--- supervisor and nothing to mount a page onto - so it cannot use `ui/`. That
--- was the reason it printed lines and read strings, and the reason it looked
--- like a different program from the rest of the system.
---
--- It does not have to. `os/kernel/console.lua` is the buffer, which is the only
--- part of the renderer with no dependencies of its own, and a menu is a list
--- with one row highlighted. This is that: arrows, numbers, a mouse, and a
--- selection you can see.
---
--- ## Clickable, because half the fleet has no keyboard worth using
---
--- A Pocket Computer's keyboard is the player's, and a wall monitor has none at
--- all. `monitor_touch` and `mouse_click` are handled beside the arrow keys
--- rather than instead of them, so the same prompt works on a desktop, on a
--- handheld, and on a monitor somebody is standing in front of.
---
--- ## It is still not a UI framework
---
--- Two functions. No components, no reactive graph, no layout. Everything here
--- exists because setup needs it and setup cannot have the real thing; anything
--- that wants more than a list and a line wants `ui/`.

local console = require("os.kernel.console")

local T = console.TOKENS

local prompt = {}

--- CC keycodes, named.
---
--- The numbers rather than `keys.up`, because this file is required by specs
--- that have no CC globals - and a menu whose arrow keys only exist inside
--- Minecraft is a menu nobody can test.
prompt.KEY = {
  up = 200,
  down = 208,
  enter = 28,
  numpadEnter = 156,
  escape = 1,
  one = 2,
}

--- Where each entry is drawn, given the screen and how many there are.
---
--- Pure, and separate from the drawing, because "which row did they click on"
--- and "which row do I paint" have to agree exactly - and the way they stop
--- agreeing is one of them being computed in two places.
---
--- Two rows per entry when any entry has a detail line, one when none do. A list
--- that reserved space for details nobody supplied would waste half a Pocket
--- Computer's screen.
function prompt.layout(entries, top)
  local spacing = 1
  for _, entry in ipairs(entries) do
    if entry.detail then
      spacing = 2
    end
  end

  local rows = {}
  for index in ipairs(entries) do
    rows[index] = (top or 4) + (index - 1) * spacing
  end
  return rows, spacing
end

--- Which entry a click at `row` landed on, or nil.
function prompt.hit(rows, spacing, row)
  for index, at in ipairs(rows) do
    if row >= at and row < at + spacing then
      return index
    end
  end
  return nil
end

--- Ask somebody to pick one of a list.
---
--- Returns the index, or nil if they cancelled. `options.title` heads the
--- screen; `options.note` is a line under it, for the thing they need to know
--- before choosing rather than after.
---
--- Cancelling is always possible and always means "change nothing". A setup that
--- could not be backed out of is a setup somebody has to finish while guessing.
function prompt.choose(screen, entries, options)
  options = options or {}
  local selected = math.min(options.selected or 1, #entries)
  if #entries == 0 then
    return nil
  end

  local top = options.note and 6 or 5

  local function draw()
    local rows, spacing = prompt.layout(entries, top)

    screen:chrome(
      options.title or "Choose",
      options.step,
      options.footer or "up/down or click   enter choose   Q cancel"
    )

    if options.note then
      screen:panelLine(3, " " .. options.note, T.warn)
    end

    for index, entry in ipairs(entries) do
      local row = rows[index]
      local chosen = index == selected
      local label = ("  %d  %s"):format(index, entry.label)

      if chosen then
        -- A band across the whole width, in `accent` with the text in
        -- `accentFg`. Two tokens rather than one: a highlight that only changed
        -- the background leaves the text at whatever contrast it had, and on a
        -- monochrome terminal that is invisible.
        screen:band(row, label:sub(2), T.accentFg, T.accent)
      else
        screen:panelLine(row, label, T.foreground)
      end

      if spacing > 1 and entry.detail then
        screen:panelLine(row + 1, "     " .. entry.detail, chosen and T.foreground or T.mutedFg)
      end
    end

    screen:present()
    return rows, spacing
  end

  local rows, spacing = draw()

  while true do
    local event = { os.pullEvent() }
    local name = event[1]

    if name == "key" then
      local key = event[2]
      if key == prompt.KEY.up then
        selected = selected > 1 and selected - 1 or #entries
      elseif key == prompt.KEY.down then
        selected = selected < #entries and selected + 1 or 1
      elseif key == prompt.KEY.enter or key == prompt.KEY.numpadEnter then
        return selected
      elseif key == prompt.KEY.escape then
        return nil
      elseif key >= prompt.KEY.one and key < prompt.KEY.one + math.min(#entries, 9) then
        -- Typing the number picks *and* confirms. Somebody who knows what they
        -- want should not have to arrow to it and then press enter.
        return key - prompt.KEY.one + 1
      end
      rows, spacing = draw()
    elseif name == "char" and (event[2] == "q" or event[2] == "Q") then
      return nil
    elseif name == "mouse_click" or name == "monitor_touch" then
      -- A click selects and confirms in one, for the same reason a number does:
      -- on a monitor there is no second gesture available.
      --
      -- `mouse_click` is (button, x, y) and `monitor_touch` is (side, x, y), so
      -- the row is the fourth value either way - different meanings in the
      -- second slot, same position for the one that matters.
      local hit = prompt.hit(rows, spacing, event[4])
      if hit then
        return hit
      end
    elseif name == "mouse_scroll" then
      selected = math.max(1, math.min(#entries, selected + event[2]))
      rows, spacing = draw()
    elseif name == "term_resize" or name == "monitor_resize" then
      rows, spacing = draw()
    end
  end
end

--- Ask for a line of text.
---
--- Drawn through the console so the screen matches, then handed to `read` for
--- the editing - which is CC's own and knows about history, the cursor and
--- backspace. Reimplementing that would be a worse text field for no gain.
function prompt.text(screen, label, options)
  options = options or {}

  screen:chrome(options.title or "ICOS setup", options.step, "enter accepts the default")
  if options.note then
    screen:panelLine(3, " " .. options.note, T.mutedFg)
  end
  screen:panelLine(5, " " .. label, T.foreground)
  if options.hint then
    screen:panelLine(6, " " .. options.hint, T.mutedFg)
  end

  -- The field itself, drawn as a band so it reads as somewhere to type rather
  -- than as another line of prose. `read` writes on top of it.
  local _, height = screen:size()
  local field = math.min(7, height - 2)
  screen:band(field, "", T.foreground, T.background)
  screen:present()

  term.setCursorPos(2, field)
  term.setBackgroundColour(2 ^ T.background)
  term.setTextColour(2 ^ T.foreground)
  if options.default then
    write("[" .. options.default .. "] ")
  end

  local answer = (read() or ""):gsub("^%s*(.-)%s*$", "%1")
  if answer == "" then
    return options.default
  end
  return answer
end

--- Say something and wait for any key.
function prompt.tell(screen, title, lines, tone, step)
  screen:chrome(title, step, "press any key")
  for index, line in ipairs(lines) do
    screen:panelLine(2 + index, " " .. line, tone or T.foreground)
  end
  screen:present()

  while true do
    local event = os.pullEvent()
    if event == "key" or event == "mouse_click" or event == "monitor_touch" then
      return
    end
  end
end

return prompt
