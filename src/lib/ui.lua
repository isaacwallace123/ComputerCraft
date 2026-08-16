--- Tiny screen helpers shared by the programs on this computer.
--- Standard (non-advanced) computers render colours as greyscale, so this
--- sticks to white / black / grey and never relies on hue to convey meaning.
local ui = {}

local W, H = term.getSize()
ui.width, ui.height = W, H

--- Reset colours and wipe the screen.
function ui.clear()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

--- Write `text` horizontally centred on row `y`.
function ui.center(y, text, color)
  term.setTextColor(color or colors.white)
  term.setCursorPos(math.max(1, math.floor((W - #text) / 2) + 1), y)
  term.write(text)
end

--- Clear the screen and draw an inverted title bar.
function ui.header(title)
  ui.clear()
  term.setBackgroundColor(colors.white)
  term.setTextColor(colors.black)
  term.setCursorPos(1, 1)
  term.write(string.rep(" ", W))
  term.setCursorPos(math.max(1, math.floor((W - #title) / 2) + 1), 1)
  term.write(title)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.setCursorPos(1, 3)
end

--- Write a hint line along the bottom of the screen.
function ui.footer(text)
  term.setTextColor(colors.lightGray)
  term.setCursorPos(2, H)
  term.clearLine()
  term.write(text)
  term.setTextColor(colors.white)
end

--- Arrow-key menu. `items` is a list of strings.
--- Returns the chosen index, or nil if the user pressed Q.
function ui.menu(title, items)
  local sel = 1
  while true do
    ui.header(title)
    for i, label in ipairs(items) do
      term.setCursorPos(3, 3 + i)
      if i == sel then
        term.setBackgroundColor(colors.white)
        term.setTextColor(colors.black)
        term.write(" " .. label .. " ")
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
      else
        term.write(" " .. label .. " ")
      end
    end
    ui.footer("up/down + enter    Q to quit")

    local _, key = os.pullEvent("key")
    if key == keys.up then
      sel = sel > 1 and sel - 1 or #items
    elseif key == keys.down then
      sel = sel < #items and sel + 1 or 1
    elseif key == keys.enter then
      return sel
    elseif key == keys.q then
      return nil
    end
  end
end

--- Ask a yes/no question. Returns a boolean.
function ui.confirm(prompt)
  term.setTextColor(colors.white)
  print(prompt .. " (y/n)")
  while true do
    local _, ch = os.pullEvent("char")
    if ch == "y" or ch == "Y" then
      return true
    elseif ch == "n" or ch == "N" then
      return false
    end
  end
end

return ui
