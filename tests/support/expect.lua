--- Assertions with messages worth reading when something fails at 3am.

local expect = {}

local function describe(value)
  if type(value) == "table" then
    local parts = {}
    for name, entry in pairs(value) do
      parts[#parts + 1] = ("%s=%s"):format(tostring(name), tostring(entry))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(value)
end

function expect.equal(actual, wanted, note)
  if actual ~= wanted then
    error(
      ("%s: expected %s, got %s"):format(note or "value", describe(wanted), describe(actual)),
      2
    )
  end
end

function expect.truthy(value, note)
  if not value then
    error(("%s: expected a truthy value, got %s"):format(note or "value", describe(value)), 2)
  end
end

function expect.falsy(value, note)
  if value then
    error(("%s: expected a falsy value, got %s"):format(note or "value", describe(value)), 2)
  end
end

function expect.contains(haystack, needle, note)
  if not tostring(haystack):find(needle, 1, true) then
    error(("%s: expected %q to contain %q"):format(note or "text", tostring(haystack), needle), 2)
  end
end

function expect.near(actual, wanted, slack, note)
  if math.abs(actual - wanted) > slack then
    error(
      ("%s: expected %s within %s of %s"):format(
        note or "value",
        tostring(actual),
        tostring(slack),
        tostring(wanted)
      ),
      2
    )
  end
end

return expect
