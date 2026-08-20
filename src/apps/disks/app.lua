--- Disks: what drives are attached, what is in them, and what is on it.
---
--- The thing a base station accumulates and nothing could see. A drive with a
--- floppy in it is the only storage in ComputerCraft that survives the computer
--- being broken, so it is where a fleet's records belong - and until this page
--- there was no way to know a disk was even present without walking to the
--- drive and looking.
---
--- ## Every read is allowed to fail
---
--- A drive is a block somebody can break while this page is drawing it, and a
--- floppy is a thing somebody can take out mid-read. So each field comes back
--- through `peripherals.call`, which answers `false` rather than raising, and a
--- disk that vanished between two calls shows as absent rather than taking the
--- page with it.
---
--- ## It reads, and it labels
---
--- Deliberately not a file manager. Copying, deleting and editing on a floppy
--- are things CC's own shell does well, and a worse copy of `cp` on a 51-column
--- screen would be a worse copy of `cp`. What it adds is the thing the shell
--- cannot: every drive at once, and which of them have anything in them.
---
--- Labelling is the exception, because an unlabelled floppy is indistinguishable
--- from every other unlabelled floppy the moment it leaves the drive - and that
--- is a problem you only notice once you have four.

local format = require("ui.format")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

--- Everything one drive can tell us.
---
--- Each field is a separate guarded call rather than a wrapped peripheral,
--- because a drive that is emptied halfway through should report the fields it
--- managed rather than nothing at all.
function app.inspect(ports, name)
  local function ask(method)
    local ok, value = ports.peripherals.call(name, method)
    if not ok then
      return nil
    end
    return value
  end

  local present = ask("isDiskPresent") == true

  return {
    name = name,
    present = present,
    label = present and ask("getDiskLabel") or nil,
    id = present and ask("getDiskID") or nil,
    mount = present and ask("getMountPath") or nil,
    data = present and ask("hasData") == true or false,
    audio = present and ask("hasAudio") == true or false,
    title = present and ask("getAudioTitle") or nil,
  }
end

--- Every drive attached to this machine.
function app.drives(ports)
  local out = {}
  for _, entry in ipairs(ports.peripherals.list()) do
    if entry.types and entry.types.drive then
      out[#out + 1] = app.inspect(ports, entry.name)
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- What a drive's row says about itself.
---
--- A music disc is called out separately from data, because the two look
--- identical in every other way and somebody wondering where their fleet backup
--- went is owed the answer "that one is Cat".
function app.describe(drive)
  if not drive.present then
    return "empty", T.mutedFg
  end
  if drive.audio then
    return drive.title and ("music: " .. tostring(drive.title)) or "music", T.accent
  end
  if drive.data then
    return drive.label or "unlabelled", drive.label and T.good or T.warn
  end
  return "blank", T.mutedFg
end

--- The files on a mounted disk, with their sizes.
---
--- Read through the storage port, because a mount path is an ordinary directory
--- once CC has attached it - which is the detail that makes a floppy useful and
--- is easy to miss.
function app.contents(ports, drive, limit)
  if drive == nil or not drive.mount then
    return {}
  end

  local names = ports.storage.list(drive.mount) or {}
  table.sort(names)

  local out = {}
  for index, name in ipairs(names) do
    if index > (limit or 8) then
      break
    end
    out[#out + 1] = { name = name }
  end
  return out
end

function app.columns()
  return {
    { Title = "Drive", Width = 12, Key = "name" },
    {
      Title = "Contents",
      Grow = 1,
      Key = "summary",
      Tone = function(row)
        return row.tone
      end,
    },
    { Title = "ID", Width = 5, Key = "diskId", Align = "right" },
  }
end

--- Rows for the table, with the derived fields flattened onto them.
function app.rows(ports)
  local rows = {}
  for _, drive in ipairs(app.drives(ports)) do
    local summary, tone = app.describe(drive)
    rows[#rows + 1] = {
      name = drive.name,
      summary = summary,
      tone = tone,
      diskId = drive.id and tostring(drive.id) or "",
      drive = drive,
    }
  end
  return rows
end

function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)

  local ports = {
    peripherals = context.peripherals,
    storage = context.storage,
  }

  local rows = scope:Computed(function(use)
    use(tick)
    if ports.peripherals == nil then
      return {}
    end
    return app.rows(ports)
  end)

  local selected = options.selected or scope:Value(nil)

  local status = scope:Computed(function(use)
    local list = use(rows)
    if ports.peripherals == nil then
      return "no peripheral access on this machine"
    end
    local loaded = 0
    for _, row in ipairs(list) do
      if row.drive.present then
        loaded = loaded + 1
      end
    end
    return ("%d drive%s, %d loaded"):format(#list, #list == 1 and "" or "s", loaded)
  end)

  --- The selected disk's files.
  local files = scope:Computed(function(use)
    local id = use(selected)
    for _, row in ipairs(use(rows)) do
      if row.name == id then
        local names = app.contents(ports, row.drive, options.capacity or 6)
        if #names == 0 then
          return row.drive.present and "nothing on it" or "no disk"
        end
        local parts = {}
        for index, file in ipairs(names) do
          parts[index] = file.name
        end
        return format.ellipsis(table.concat(parts, "  "), 46)
      end
    end
    return "select a drive to see what is on it"
  end)

  return scope:Page({
    Title = "Disks",
    Status = status,
    Children = {
      scope:Table({
        Columns = app.columns(),
        Rows = rows,
        Selected = selected,
        Capacity = options.capacity or 6,
        OnSelect = function(row)
          selected:set(row and row.name or nil)
        end,
      }),
      scope:Separator({}),
      scope:Muted({ Text = files, Height = 1 }),
    },
  })
end

return app
