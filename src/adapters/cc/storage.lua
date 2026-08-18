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
  --- that finds no file must also look for `path .. ".tmp"`; `core/config.lua`
  --- does exactly that and this port keeps the same file naming so the two
  --- cannot drift apart while both exist.
  function impl.write(path, text)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then
      fs.makeDir(dir)
    end

    local temporary = path .. ".tmp"
    if fs.exists(temporary) then
      fs.delete(temporary)
    end
    local handle = fs.open(temporary, "w")
    if not handle then
      return false, "could not write " .. temporary
    end
    handle.write(text)
    handle.close()

    if fs.exists(path) then
      fs.delete(path)
    end
    fs.move(temporary, path)
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
