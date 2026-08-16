--- door.lua - PIN-locked redstone door.
---
--- The computer emits a redstone signal out of one side while the door is
--- "open". Put a door, iron door, piston, or Create-style contraption on the
--- receiving end. No peripherals or extra items needed beyond redstone dust.
---
--- Press Ctrl+T to terminate and drop to the shell.

local ui = require("lib.ui")
local config = require("lib.config")

local CONFIG_PATH = ".door"

-- Defaults are written to .door on first run; edit that file in game with
-- `edit .door` rather than changing them here.
local defaults = {
  side = "back", -- which face of the computer powers the door
  pin = nil, -- set on first run
  openSeconds = 5, -- how long the door stays unlocked
  maxAttempts = 3, -- wrong PINs before a lockout
  lockoutSeconds = 30,
}

local cfg = config.load(CONFIG_PATH, defaults)

--- Walk the player through choosing a side and a PIN.
local function firstRunSetup()
  ui.header("Door Setup")
  print("No PIN set yet. Let's configure the lock.\n")

  local sides = { "back", "left", "right", "top", "bottom", "front" }
  local choice = ui.menu("Which side powers the door?", sides)
  if not choice then
    error("Setup cancelled", 0)
  end
  cfg.side = sides[choice]

  ui.header("Door Setup")
  print("Side: " .. cfg.side .. "\n")

  local pin
  while true do
    write("Choose a PIN (digits): ")
    pin = read("*")
    if #pin < 3 then
      printError("Too short - use at least 3 digits.")
    else
      write("Confirm PIN: ")
      if read("*") == pin then
        break
      end
      printError("PINs did not match, try again.")
    end
  end

  cfg.pin = pin
  config.save(CONFIG_PATH, cfg)

  ui.header("Door Setup")
  ui.center(5, "Saved.", colors.white)
  ui.center(7, "Edit " .. CONFIG_PATH .. " to change settings later.", colors.lightGray)
  sleep(2)
end

--- Power the door for cfg.openSeconds, counting down on screen.
local function openDoor()
  redstone.setOutput(cfg.side, true)
  for remaining = cfg.openSeconds, 1, -1 do
    ui.header("UNLOCKED")
    ui.center(5, "Door is open", colors.white)
    ui.center(7, "closing in " .. remaining .. "s", colors.lightGray)
    ui.footer("press any key to close now")

    -- Wait one second, but let a keypress cut it short.
    local timer = os.startTimer(1)
    while true do
      local event, id = os.pullEvent()
      if event == "timer" and id == timer then
        break
      elseif event == "key" then
        redstone.setOutput(cfg.side, false)
        return
      end
    end
  end
  redstone.setOutput(cfg.side, false)
end

--- Freeze the terminal after too many bad guesses.
local function lockout()
  for remaining = cfg.lockoutSeconds, 1, -1 do
    ui.header("LOCKED OUT")
    ui.center(5, "Too many failed attempts", colors.white)
    ui.center(7, remaining .. "s", colors.lightGray)
    sleep(1)
  end
end

local function main()
  if not cfg.pin then
    firstRunSetup()
  end

  -- Never leave the door powered from a previous crash.
  redstone.setOutput(cfg.side, false)

  local failures = 0
  while true do
    ui.header("LOCKED")
    ui.center(5, "Enter PIN", colors.white)
    term.setCursorPos(math.floor(ui.width / 2) - 5, 7)

    local entered = read("*")

    if entered == cfg.pin then
      failures = 0
      openDoor()
    else
      failures = failures + 1
      ui.header("DENIED")
      ui.center(5, "Incorrect PIN", colors.white)
      ui.center(7, (cfg.maxAttempts - failures) .. " attempt(s) left", colors.lightGray)
      sleep(1.5)

      if failures >= cfg.maxAttempts then
        lockout()
        failures = 0
      end
    end
  end
end

local ok, err = pcall(main)
redstone.setOutput(cfg.side, false) -- fail safe: never leave the door open
if not ok then
  ui.clear()
  printError(err)
end
