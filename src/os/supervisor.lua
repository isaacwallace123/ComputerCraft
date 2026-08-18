--- Runs services, and keeps running the others when one dies.
---
--- §8 of docs/icos-2.md, and the reason it exists is one sentence of CC
--- semantics: **`parallel.waitForAny` returns when *any* coroutine finishes.**
--- So today an error escaping the fleet service stops discovery, lease handling,
--- policy, logging and persistence together — a bug in the auto-recovery policy
--- takes sector leasing down with it, and on a server it would take GPS down
--- with it too, which breaks navigation for the whole fleet.
---
--- This resumes each service itself. One dying is one dying.
---
--- ## Cooperative, and that cannot be enforced from here
---
--- CC gives cooperative multitasking and nothing else. A service that does not
--- yield starves every other service on the machine, and no runtime built on
--- `coroutine` can preempt it. §8 calls this a review rule; the most this file
--- can do is *notice* — `slowest` reports how long each service ran between
--- yields, so a starving service shows up as a number on the Services page
--- rather than as a machine that feels sluggish.
---
--- ## Give up loudly, never quietly
---
--- The mining stall counter (D025) learned this: back off, then stop and say so,
--- rather than retrying forever while looking healthy. A service that has given
--- up is `stopped` with a reason attached, and a **critical** one that gives up
--- makes the whole machine report unhealthy. A supervisor that silently
--- restarted a crash-looping service for an hour would be worse than no
--- supervisor at all, because the dashboard would say everything was fine.
---
--- ## Plain Lua, and therefore testable
---
--- `coroutine` is core Lua, not a CC global, and the clock is injected. So the
--- whole restart-and-backoff story is exercised by a spec that advances time by
--- hand — including the parts that only happen after five failures and eight
--- seconds, which nobody would ever wait for in a world.

local supervisor = {}

--- How long to wait before restarting, per consecutive failure.
---
--- Doubling from one second, capped at thirty. The cap matters more than the
--- curve: an uncapped exponential reaches hours by the twelfth failure, and a
--- service that would have recovered on its own is then held down by its own
--- backoff long after the cause has gone.
supervisor.BACKOFF = { 1, 2, 4, 8, 16, 30 }

--- Consecutive failures before a service is abandoned.
---
--- Five, matching the panel sketch in §8. Enough that a transient - a peripheral
--- detached and reattached, a modem out of range at boot - is ridden out, and
--- few enough that a genuine crash loop is reported within a minute rather than
--- being absorbed forever.
supervisor.GIVE_UP_AFTER = 5

local Supervisor = {}
Supervisor.__index = Supervisor

--- `options.clock` is a clock port. `options.onError` is called with the service
--- id and the error, for the log; the supervisor never prints.
function supervisor.new(options)
  options = options or {}
  return setmetatable({
    clock = assert(options.clock, "supervisor needs a clock port"),
    onError = options.onError,
    giveUpAfter = options.giveUpAfter or supervisor.GIVE_UP_AFTER,
    services = {},
    order = {},
  }, Supervisor)
end

--- Register a service. See `os/service.lua` for the manifest shape.
function Supervisor:add(definition)
  if type(definition) ~= "table" or type(definition.id) ~= "string" then
    error("supervisor: a service needs an id", 2)
  end
  if type(definition.run) ~= "function" then
    error("supervisor: " .. tostring(definition.id) .. " needs a run function", 2)
  end
  if self.services[definition.id] then
    error("supervisor: duplicate service " .. definition.id, 2)
  end

  local entry = {
    id = definition.id,
    definition = definition,
    critical = definition.critical == true,
    state = "stopped",
    restarts = 0,
    failures = 0,
    lastError = nil,
    lastErrorAt = nil,
    retryAt = nil,
    slowest = 0,
  }
  self.services[definition.id] = entry
  self.order[#self.order + 1] = entry
  return entry
end

--- Everything a service was promised, checked before it is started.
---
--- A service declares `requires = { "transport", "storage" }`. Starting one
--- whose ports are absent produces a nil-index somewhere inside its loop, on a
--- machine with no screen, at whatever moment it first happens to reach that
--- line. Refusing up front turns that into one legible line on the Services
--- page - which is the same reasoning as `ports/contract.lua` checking an
--- adapter at construction.
local function missingPorts(definition, context)
  local missing = {}
  for _, name in ipairs(definition.requires or {}) do
    if context[name] == nil then
      missing[#missing + 1] = name
    end
  end
  return missing
end

local function fail(self, entry, reason, now)
  entry.failures = entry.failures + 1
  entry.lastError = reason
  entry.lastErrorAt = now
  entry.thread = nil

  if self.onError then
    self.onError(entry.id, reason, entry.failures)
  end

  if entry.failures >= self.giveUpAfter then
    entry.state = "stopped"
    entry.retryAt = nil
    entry.gaveUp = true
    return
  end

  local wait = supervisor.BACKOFF[math.min(entry.failures, #supervisor.BACKOFF)]
  entry.state = "waiting"
  entry.retryAt = now + wait * 1000
end

--- Create the coroutine. It is not resumed here.
---
--- `restarts` counts how many times this service has been brought back over the
--- life of the machine and is what the panel shows; `failures` counts the
--- current consecutive run and decides the backoff, and is cleared by a
--- successful resume. Two different questions - "is this flaky" and "is this
--- crash-looping right now" - so two different numbers.
local function spawn(self, entry, context, now)
  local missing = missingPorts(entry.definition, context)
  if #missing > 0 then
    fail(self, entry, "missing ports: " .. table.concat(missing, ", "), now)
    return false
  end

  if entry.everStarted then
    entry.restarts = entry.restarts + 1
  end
  entry.everStarted = true

  entry.thread = coroutine.create(entry.definition.run)
  entry.state = "running"
  entry.filter = nil
  entry.primed = false
  entry.startedAt = now
  return true
end

--- Start every registered service.
function Supervisor:start(context)
  self.context = context or {}
  local now = self.clock.now()
  for _, entry in ipairs(self.order) do
    if entry.state == "stopped" and not entry.gaveUp then
      spawn(self, entry, self.context, now)
    end
  end
  return self
end

--- Clear a service's failure count and start it again.
---
--- The operator's "I have fixed it, try again". Deliberately manual: a
--- supervisor that reset its own counter on a timer would turn "gave up after
--- five failures" into "retries forever, slowly", which is the state this is
--- designed to make visible rather than to reach.
function Supervisor:revive(id)
  local entry = self.services[id]
  if entry == nil then
    return false
  end
  entry.failures, entry.gaveUp, entry.lastError = 0, nil, nil
  entry.retryAt = nil
  if entry.state ~= "running" then
    spawn(self, entry, self.context or {}, self.clock.now())
  end
  return true
end

--- Resume every service that is waiting for this event, and restart any whose
--- backoff has elapsed. Returns how many are running.
---
--- The event filter is CC's own: a coroutine that yields a string is asking to
--- be resumed only for that event, which is what `os.pullEvent(name)` compiles
--- down to. Honouring it here means an existing service loop needs no changes
--- to run under this rather than under `parallel`.
function Supervisor:step(event)
  local now = self.clock.now()

  for _, entry in ipairs(self.order) do
    if entry.state == "waiting" and entry.retryAt and now >= entry.retryAt then
      spawn(self, entry, self.context or {}, now)
    end

    if entry.state == "running" and entry.thread then
      local name = event and event[1]
      if not entry.primed or entry.filter == nil or entry.filter == name or name == "terminate" then
        local started = self.clock.now()

        -- The first resume passes the context, because that is what `run` was
        -- declared to take. Every resume after it passes the event, because by
        -- then the coroutine is parked inside a `pullEvent` and that is what it
        -- is waiting for. Getting this backwards hands a service its first event
        -- as its context and every event thereafter as nothing at all.
        local results
        if entry.primed then
          results = { coroutine.resume(entry.thread, table.unpack(event or {})) }
        else
          entry.primed = true
          results = { coroutine.resume(entry.thread, self.context or {}) }
        end

        local elapsed = self.clock.now() - started
        if elapsed > entry.slowest then
          entry.slowest = elapsed
        end

        local ok = results[1]
        if not ok then
          fail(self, entry, tostring(results[2]), now)
        elseif coroutine.status(entry.thread) == "dead" then
          -- A service that returns has finished, and a service is defined as
          -- running for the life of the machine - so returning is a fault, not a
          -- success. Treated as a failure so it backs off rather than being
          -- restarted in a tight loop; a `run` that falls off the end every time
          -- would otherwise spin the machine at full speed forever.
          fail(self, entry, "service returned", now)
        else
          entry.filter = results[2]
          entry.failures = 0
        end
      end
    end
  end

  return self:running()
end

function Supervisor:running()
  local count = 0
  for _, entry in ipairs(self.order) do
    if entry.state == "running" then
      count = count + 1
    end
  end
  return count
end

--- What the Services page reads. Never printed from here: a supervisor that
--- drew would be a service that draws, which §8 forbids.
function Supervisor:health(now)
  now = now or self.clock.now()
  local rows = {}
  for _, entry in ipairs(self.order) do
    rows[#rows + 1] = {
      id = entry.id,
      state = entry.state,
      critical = entry.critical,
      restarts = entry.restarts,
      failures = entry.failures,
      gaveUp = entry.gaveUp == true,
      lastError = entry.lastError,
      since = entry.lastErrorAt and (now - entry.lastErrorAt) / 1000 or nil,
      retryIn = entry.retryAt and math.max(0, (entry.retryAt - now) / 1000) or nil,
      slowest = entry.slowest,
    }
  end
  return rows
end

--- Is this machine doing its job?
---
--- Unhealthy means a critical service has given up. A non-critical one that has
--- given up degrades quietly and is reported; a critical one is the difference
--- between a server that is slightly wrong and a server that is not a server.
--- GPS is the example that matters: an outage there breaks navigation for the
--- whole fleet, and it must not be possible for a bug in the auto-recovery
--- policy to cause one.
function Supervisor:healthy()
  for _, entry in ipairs(self.order) do
    if entry.critical and (entry.gaveUp or entry.state == "stopped") then
      return false, entry.id .. ": " .. tostring(entry.lastError or "stopped")
    end
  end
  return true
end

--- Stop everything. The machine is going down, not a service failing.
function Supervisor:stop()
  for _, entry in ipairs(self.order) do
    entry.thread = nil
    entry.state = "stopped"
    entry.retryAt = nil
  end
end

return supervisor
