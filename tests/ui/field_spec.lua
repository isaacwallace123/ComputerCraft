--- Typing: the component every remaining interactive app was blocked on.
---
--- The console, setup, mine placement and the coordinate prompt all need a line
--- of text. Without one they would each have grown a `read()` loop over the top
--- of a running page, which is a second event loop fighting the first for the
--- keyboard.
---
--- Driven here with no screen and no keyboard: a spec writes down what somebody
--- typed and the framework cannot tell the difference.

local expect = require("support.expect")
local it = require("support.spec").it

local recorder = require("adapters.sim.screen")
local ui = require("ui.init")

local KEY = ui.input.KEY

--- A mounted tree with one field, and the state it writes back to.
local function fieldWith(props, width)
  local screen = recorder.new(width or 24, 4)
  local scope = ui.scoped()
  local text = scope:Value(props.Value or "")
  local submitted = {}

  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      local declared = {
        Value = text,
        Width = props.Width,
        Placeholder = props.Placeholder,
        MaxLength = props.MaxLength,
        Disabled = props.Disabled,
        OnChange = function(next)
          text:set(next)
        end,
        OnSubmit = function(value)
          submitted[#submitted + 1] = value
        end,
      }
      return s:Row({ Children = { s:Field(declared) } })
    end,
  })
  root:render()

  -- Focus it, the way a person would.
  root:handle("key", KEY.tab, false)
  return root, text, submitted, screen
end

--- Type a word, one character at a time, as CC delivers them.
local function typeIn(root, word)
  for index = 1, #word do
    root:handle("char", word:sub(index, index))
  end
end

it("typing goes to the caller's state, not into the component", function()
  -- The field stores nothing between frames. `runtime.define` resolves every
  -- state-object property before paint, so a field handed one would see the
  -- string and never the object - which is why the data flows down as a value
  -- and back as a call, like everything else here.
  local root, text = fieldWith({})
  typeIn(root, "mine")
  expect.equal(text:get(), "mine", "the caller's state has it")
end)

it("backspace removes one character and stops at empty", function()
  local root, text = fieldWith({ Value = "ab" })
  root:handle("key", KEY.backspace, false)
  expect.equal(text:get(), "a", "one gone")
  root:handle("key", KEY.backspace, false)
  expect.equal(text:get(), "", "and the other")
  root:handle("key", KEY.backspace, false)
  expect.equal(text:get(), "", "an empty field is not an error")
end)

it("enter submits and space does not", function()
  -- The runtime fires `OnClick` on the focused node for enter *and* space, so a
  -- field that submitted through `OnClick` would be a field that cannot type a
  -- space. This is why `OnSubmit` exists as its own property.
  local root, text, submitted = fieldWith({})
  typeIn(root, "mine at")
  expect.equal(text:get(), "mine at", "the space was typed, not swallowed")

  root:handle("key", KEY.enter, false)
  expect.equal(#submitted, 1, "submitted once")
  expect.equal(submitted[1], "mine at", "with what was typed")
end)

it("submitting does not clear the field - the caller decides that", function()
  -- A console clears on submit and a coordinate prompt keeps the value so it
  -- can be corrected. Neither is the component's business.
  local root, text, submitted = fieldWith({ Value = "50 50 64" })
  root:handle("key", KEY.enter, false)
  expect.equal(#submitted, 1, "submitted")
  expect.equal(text:get(), "50 50 64", "and left alone")
end)

it("a disabled field takes nothing", function()
  local root, text, submitted = fieldWith({ Value = "locked", Disabled = true })
  typeIn(root, "x")
  root:handle("key", KEY.backspace, false)
  root:handle("key", KEY.enter, false)
  expect.equal(text:get(), "locked", "unchanged")
  expect.equal(#submitted, 0, "and it did not submit")
end)

it("MaxLength stops typing rather than truncating afterwards", function()
  -- Truncating after the fact would let somebody watch characters they typed
  -- disappear, which reads as a bug rather than as a limit.
  local root, text = fieldWith({ MaxLength = 3 })
  typeIn(root, "abcdef")
  expect.equal(text:get(), "abc", "stopped at the limit")
end)

it("keys the field does not use are left for the screen", function()
  -- A page still binds its own keys while a field has focus. Claiming every key
  -- would make a console impossible to leave.
  local root = fieldWith({})
  local taken = root:handle("key", KEY.up, false)
  expect.falsy(taken, "not taken")
end)

it("a long line shows its tail, so you can see what you are typing", function()
  -- Showing the first N characters would hide the thing being typed, which is
  -- the one part of the line somebody is looking at.
  local root, _, _, screen = fieldWith({ Width = 6 }, 12)
  typeIn(root, "abcdefghij")
  root:render()

  local row = screen.rowText(1):sub(1, 6)
  expect.contains(row, "ij", "the end of the line is visible")
  expect.falsy(row:find("abc"), "and the start has scrolled off")
end)

it("a placeholder shows only when the field is empty and unfocused", function()
  local screen = recorder.new(20, 3)
  local scope = ui.scoped()
  local text = scope:Value("")
  local root = ui.mount({
    scope = scope,
    screen = screen.port,
    build = function(s)
      return s:Row({
        Children = {
          s:Field({ Value = text, Width = 12, Placeholder = "x z y", OnChange = function() end }),
        },
      })
    end,
  })
  root:render()

  expect.contains(screen.rowText(1), "x z y", "shown while empty and unfocused")

  root:handle("key", KEY.tab, false)
  root:render()
  expect.falsy(screen.rowText(1):find("x z y"), "and gone once focused")
end)
