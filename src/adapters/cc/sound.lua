--- Speaker jingles.
---
--- An adapter, not ICOS 1. It was in `legacy/` because that is where `core/`
--- was dismantled to (D039), and it stayed there long enough to become one of
--- the three things `startup.lua`, `install.lua` and `update.lua` all reached
--- into `legacy/` for. Nothing in it knows what an ICOS 1 role is, or that
--- there are two operating systems: it wraps a peripheral, which is the
--- definition of an adapter.
---
--- Every call is a no-op when there is no speaker attached, so callers never
--- have to check first - a turtle without a speaker just boots silently.
---
--- Notes are `speaker.playNote(instrument, volume, pitch)` with pitch in
--- semitones 0-24, which is two octaves starting at F#3. Sequences are written
--- as {instrument, volume, pitch, holdSeconds}.

local sound = {}

local speaker = peripheral.find("speaker")

function sound.available()
  return speaker ~= nil
end

--- Rising, warm, resolves upward. The one you want to hear when a base comes
--- back after a server restart.
local BOOT = {
  { "bass", 0.9, 5, 0.02 },
  { "bell", 1.0, 12, 0.13 },
  { "bell", 1.0, 16, 0.13 },
  { "chime", 0.9, 19, 0.13 },
  { "chime", 0.7, 24, 0.28 },
}

--- The same shape, inverted.
local SHUTDOWN = {
  { "chime", 0.8, 21, 0.11 },
  { "bell", 0.8, 16, 0.11 },
  { "bell", 0.7, 12, 0.11 },
  { "bass", 0.7, 5, 0.20 },
}

local TUNES = {
  boot = BOOT,
  shutdown = SHUTDOWN,
  ready = {
    { "pling", 0.8, 17, 0.07 },
    { "pling", 0.8, 21, 0.12 },
  },
  error = {
    { "bass", 1.0, 4, 0.14 },
    { "bass", 1.0, 2, 0.24 },
  },
  alert = {
    { "bit", 0.9, 18, 0.08 },
    { "bit", 0.9, 14, 0.08 },
    { "bit", 0.9, 18, 0.14 },
  },

  ---------------------------------------------------------------------------
  -- Feedback
  ---------------------------------------------------------------------------
  --
  -- The five above are *events*: things that happened to the machine. These are
  -- *answers*: a person did something and the machine is saying whether it
  -- worked. They are deliberately much shorter - a jingle that takes a fifth of
  -- a second to say "yes" is a jingle somebody turns off, because they will hear
  -- it a hundred times an hour and only notice it when it is late.
  --
  -- Pitch carries the meaning and length carries the weight. Up is yes, down is
  -- no, flat is "I heard you", and the only long one is the one that means a job
  -- finished - which is the only feedback worth hearing from another room.

  --- A control was operated. One note, barely there.
  click = {
    { "hat", 0.35, 18, 0.03 },
  },

  --- The thing you asked for happened.
  confirm = {
    { "pling", 0.7, 19, 0.05 },
    { "pling", 0.7, 24, 0.09 },
  },

  --- It did not, and it is your input rather than a fault.
  ---
  --- Distinct from `error`, which is the machine failing. A refusal is a
  --- conversation - the turtle is not parked, the field has no cells - and it
  --- should not sound like something broke.
  deny = {
    { "bass", 0.6, 10, 0.05 },
    { "bass", 0.6, 7, 0.11 },
  },

  --- A turtle reached where it was going.
  arrive = {
    { "bell", 0.6, 16, 0.06 },
    { "bell", 0.5, 19, 0.10 },
  },

  --- A job finished. The one feedback tone meant to carry across a room.
  complete = {
    { "chime", 0.9, 12, 0.10 },
    { "chime", 0.9, 16, 0.10 },
    { "chime", 0.9, 19, 0.10 },
    { "chime", 0.8, 24, 0.26 },
  },

  --- Somebody is being asked something and has not answered.
  ---
  --- Two low notes far enough apart to read as a question rather than a fault.
  --- Played once, never repeated: a prompt that nagged would be a prompt people
  --- learn to ignore, which defeats the only thing it is for.
  prompt = {
    { "bit", 0.5, 12, 0.07 },
    { "bit", 0.5, 15, 0.12 },
  },
}

--- Every name `play` knows, for a caller that wants to check rather than guess.
---
--- Exposed because a typo in a tune name is silent by design - `play` returns
--- false and the machine carries on - and a silent failure that only shows up as
--- "the speaker stopped working" is worth being able to assert against.
function sound.names()
  local out = {}
  for name in pairs(TUNES) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- Is this a tune we know?
function sound.knows(name)
  return TUNES[name] ~= nil
end

--- Play a named jingle. Blocks for its duration, so run it in parallel with an
--- animation rather than before one.
---
--- The feedback tones are short enough to play inline: `click` is thirty
--- milliseconds, which is less than a screen repaint, so a button that plays one
--- does not feel slower for it.
function sound.play(name)
  local tune = TUNES[name]
  if not tune or not speaker then
    return false
  end

  for _, step in ipairs(tune) do
    -- pcall: a full speaker queue returns false, but a bad instrument name
    -- throws, and a jingle must never be able to stop a boot.
    pcall(speaker.playNote, step[1], step[2], step[3])
    sleep(step[4] or 0.12)
  end

  return true
end

--- One-off note, for UI feedback.
function sound.blip(pitch, instrument)
  if not speaker then
    return false
  end
  pcall(speaker.playNote, instrument or "pling", 0.6, pitch or 18)
  return true
end

return sound
