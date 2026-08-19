--- The console: what has happened, and a line to type on.
---
--- Two things stacked. The history grows upward and the prompt stays at the
--- bottom, which is the one layout decision here and it is not a preference: a
--- prompt that moved as the log grew would be a prompt somebody has to look for
--- between commands.
---
--- ## It shows the tail, and only the tail
---
--- No scrollback. A console on a 51x19 terminal shows the last dozen lines, and
--- the thing somebody wants after typing a command is the answer to *that*
--- command, which is the last line. Scrolling back through a session belongs to
--- the Logs page, which reads the same log from disk and is built for it.
---
--- That is why the history is handed in already trimmed: the view does not
--- decide how much to keep, because how much fits is a layout answer and how
--- much is worth keeping is not.

local theme = require("ui.theme")

local T = theme.TOKENS

local console = {}

--- What each kind of line looks like.
---
--- Three, matching the log port's three levels, and an `echo` for the command
--- somebody typed. The echo is muted rather than coloured because it is not
--- news - they know what they typed; it is there so the answer below it has
--- something to be an answer *to*.
console.TONES = {
  echo = T.mutedFg,
  info = T.foreground,
  warn = T.warn,
  error = T.destructive,
}

function console.tone(line)
  return console.TONES[line and line.level] or T.foreground
end

--- Build the page.
---
--- `options.lines` is a state object holding the visible history, oldest first.
--- `options.input` is the current text of the prompt and `options.onSubmit` is
--- called with it. Both belong to the caller for the reason every state object
--- here does: the app owns what it can act on.
function console.build(scope, options)
  local lines = options.lines
  local capacity = options.capacity or 10

  -- A fixed pool of rows over a changing list, which is D031. Rebuilding the
  -- children when a line arrives would re-solve the layout on every command;
  -- binding a fixed set of rows means a new line repaints the rows that
  -- changed and nothing else.
  local rows = {}
  for slot = 1, capacity do
    local line = scope:Computed(function(use)
      local list = use(lines)
      -- Anchored to the bottom: slot `capacity` is always the newest line, so
      -- the history grows upward into empty rows rather than the newest line
      -- moving down the screen as the log fills.
      local index = #list - capacity + slot
      return list[index]
    end)

    rows[#rows + 1] = scope:Text({
      Text = scope:Computed(function(use)
        local entry = use(line)
        return entry and tostring(entry.text or "") or ""
      end),
      Color = scope:Computed(function(use)
        return console.tone(use(line))
      end),
    })
  end

  local prompt = scope:Row({
    Height = 1,
    Children = {
      scope:Text({ Text = ">", Color = T.accent }),
      scope:Spacer({ Width = 1 }),
      scope:Field({
        Grow = 1,
        Value = options.input,
        Placeholder = options.placeholder or "type help",
        OnChange = options.onChange,
        OnSubmit = options.onSubmit,
      }),
    },
  })

  return scope:Page({
    Title = options.title or "Console",
    Status = options.status,
    Children = {
      scope:Column({ Grow = 1, Children = rows }),
      scope:Separator({}),
      prompt,
    },
  })
end

return console
