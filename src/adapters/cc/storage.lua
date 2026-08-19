--- Storage port over CC's `fs`.
---
--- `write` is a replace, not an overwrite, and that is the entire reason this
--- adapter is more than four one-line wrappers. See the comment on it.

local storage = require("ports.storage")

local adapter = {}

function adapter.new()
  local impl = {}

  function impl.read(path)
    if not fs.exists(path) or fs.isDir(path) then
      return nil
    end
    local handle = fs.open(path, "r")
    if not handle then
      return nil
    end
    local text = handle.readAll()
    handle.close()
    return text
  end

  --- Write `text` to `path`, atomically as far as a reader is concerned.
  ---
  --- CC has no replace primitive. Writing in place means a reboot in the middle
  --- leaves a truncated file, and `.nav` truncated is a turtle that believes it
  --- is standing somewhere it is not - which is how a fleet ends up mining
  --- through its own base. So the replacement is written and closed complete
  --- under a `.tmp` name first, and only then moved over the live file.
  ---
  --- A reboot can still land in the delete/move window, which is why a reader
  --- that finds no file must also look for `path .. ".tmp"`; `adapters/cc/config.lua`
  --- does exactly that and this port keeps the same file naming so the two
  --- cannot drift apart while both exist.
  ---
  --- ## It returns false; it does not raise
  ---
  --- The port says `write` answers whether it worked, and for a long time it
  --- could not: `handle.write` **throws** when the disk is full, so the only
  --- failure it ever reported was `fs.open` returning nil - which is not the
  --- failure that happens. Everything downstream was written against the
  --- contract rather than the behaviour, and on a full disk all of it broke at
  --- once:
  ---
  ---   * `os/server/services/logrotate.lua` guards with
  ---     `if not storage.write(previous, text) then return 0 end`, specifically
  ---     so that a full disk does not lose the log it is trying to rotate. That
  ---     guard was unreachable.
  ---   * `persist` and `leases` are **critical** services that write through
  ---     here. Five throws each and the supervisor gives up on both permanently,
  ---     so a full disk stopped a server persisting its registry and leasing
  ---     sectors - the two things that keep two turtles out of one shaft.
  ---
  --- So every filesystem call below is guarded and the reason comes back with
  --- the false. The failure is still a real one and the caller still has to
  --- handle it; what changed is that it is now a value rather than an exception
  --- travelling up through a service loop.
  function impl.write(path, text)
    local temporary = path .. ".tmp"

    local ok, reason = pcall(function()
      local dir = fs.getDir(path)
      if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
      end

      if fs.exists(temporary) then
        fs.delete(temporary)
      end
      local handle = fs.open(temporary, "w")
      if not handle then
        return "could not open " .. temporary
      end

      -- Written and closed complete before the live file is touched, so a throw
      -- here leaves `path` exactly as it was. The half-written `.tmp` is
      -- harmless: a reader only falls back to it when `path` is missing, which
      -- it is not.
      local wrote = pcall(handle.write, text)
      pcall(handle.close)
      if not wrote then
        return "out of space writing " .. temporary
      end

      if fs.exists(path) then
        fs.delete(path)
      end
      fs.move(temporary, path)
      return nil
    end)

    if not ok then
      return false, "could not write " .. path .. ": " .. tostring(reason)
    end
    if reason ~= nil then
      return false, reason
    end

    -- Confirmed rather than assumed. `fs.move` is the one step whose failure
    -- would otherwise be reported as a success, and it is also the step that
    -- leaves the old file deleted - so a caller told "written" would have lost
    -- the very thing it was replacing.
    if not fs.exists(path) then
      return false, "wrote " .. temporary .. " but could not move it into place"
    end
    return true
  end

  function impl.list(path)
    if not fs.exists(path) or not fs.isDir(path) then
      return {}
    end
    return fs.list(path)
  end

  function impl.delete(path)
    if not fs.exists(path) then
      return true
    end
    fs.delete(path)
    return true
  end

  return storage.check(impl)
end

return adapter
