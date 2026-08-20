--- The thing that makes a screen change when nothing was pressed.
---
--- Every page derives what it shows from `context.tick`, and until this existed
--- nothing advanced it. A page computed once and held that picture for as long
--- as it was open - so a server's Fleet page said one turtle while the client
--- beside it said four, because the server had rendered once when one turtle was
--- known and never again.
---
--- That is worse than a slow screen. A stale page does not look stale; it looks
--- *wrong*, and what somebody notices is two machines disagreeing rather than
--- the age of either.
---
--- ## A service, because sleeping is what services do
---
--- The first attempt put the clock in `ui/host.lua`'s idle branch: give the loop
--- a timeout, bump the tick when `pull` returns nothing. That works on a real
--- terminal, where `pull` waits a second before returning nothing - and spins at
--- full speed on one whose port returns instantly, which is a null port, a
--- scripted one that has run out, and a machine whose keyboard has died.
---
--- A refresh mechanism that turns a broken input into a hot loop is worse than
--- no refresh. Here the wait is `clock.sleep`, which yields to the supervisor
--- like every other service, and a dead input port stays dead rather than
--- becoming busy.
---
--- ## It queues an event as well as setting a value
---
--- Both are needed and they do different things. The value is what the page's
--- `Computed` depends on; the event is what wakes `host.run` so the render at
--- the bottom of its loop happens. Setting the value alone would mark the tree
--- dirty and leave it that way until somebody pressed a key.

local service = require("os.kernel.service")

local ticker = {}

--- Seconds between repaints.
---
--- One. The numbers on these pages come from heartbeats that arrive every two,
--- so faster would redraw the same screen; slower and a device going offline
--- takes longer to appear than it took to happen.
---
--- A repaint costs one blit per row that actually changed, which for a table of
--- similar rows is close to nothing - the expensive thing would be recomputing
--- ten pages, and only the open one exists.
ticker.EVERY = 1

--- The event queued to wake a screen.
ticker.EVENT = "icos_tick"

--- Advance the tick, and wake anything drawing.
---
--- Separated from the loop for the usual reason: a spec drives this directly and
--- asserts the value moved, without a clock or a screen.
function ticker.beat(context)
  if context.tick then
    context.tick:set(context.tick:get() + 1)
  end
  if os and os.queueEvent then
    os.queueEvent(ticker.EVENT)
  end
  return context.tick and context.tick:get() or nil
end

ticker.service = service.define({
  id = "ticker",
  requires = { "clock" },

  -- Not critical. A machine whose screen has stopped refreshing is still
  -- answering turtles, and on a headless server this service has nothing to
  -- wake - it runs anyway rather than being conditional, because a machine that
  -- gains a monitor should not need a reboot to start repainting.
  critical = false,

  run = function(context)
    while true do
      ticker.beat(context)
      context.clock.sleep(context.tickEvery or ticker.EVERY)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return ticker
