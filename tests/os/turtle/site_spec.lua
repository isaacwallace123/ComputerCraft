--- The sector client, and the link that lets one module serve two protocols.
---
--- `os/turtle/site.lua` is called by the prospecting jobs, which are shared by
--- ICOS 1 and ICOS 2. It therefore cannot know which protocol it is on, and the
--- failure if it guesses wrong is the quiet kind: every claim falls through to
--- the offline path, every turtle picks a sector from its own computer ID, and
--- the fleet mines happily in the wrong places while nothing reports an error.

local expect = require("support.expect")
local scenario = require("support.scenario")
local it = require("support.spec").it

local function fresh()
  scenario.new({ groundY = 64 })
  return require("os.turtle.site")
end

it("with no link attached, nothing is sent and the turtle goes offline", function()
  -- The honest state for a machine with no radio, and the one every spec that
  -- does not care about the network runs in.
  local site = fresh()
  site.attach(nil)

  local state, why = site.claim("rare@-59", 0, 0)
  expect.truthy(state, "still returns a state")
  expect.falsy(state.fromBase, "and says it did not come from the base")
  expect.truthy(why, "with a reason: " .. tostring(why))
end)

it("the body sent is ICOS 1's, whichever protocol carries it", function()
  -- The property that makes one module serve both. `leases.lua` kept ICOS 1's
  -- body deliberately and changed only the envelope; if this file ever starts
  -- shaping the envelope itself, that stops being true and the bridge breaks
  -- with it.
  local site = fresh()
  local sent = {}
  site.attach({
    broadcast = function(body)
      sent[#sent + 1] = body
      return true
    end,
  })

  site.claim("rare@-59", 3, 7)

  expect.equal(#sent, 1, "one message")
  expect.equal(sent[1].action, "claim", "an action")
  expect.equal(sent[1].workKey, "rare@-59", "the work key")
  expect.equal(sent[1].sector, 3, "the preferred sector")
  expect.equal(sent[1].frontier, 7, "and how far it had got")
  expect.truthy(sent[1].requestId, "with a request id to match the reply against")

  site.attach(nil)
end)

it("a reply that matches the request is taken", function()
  local site = fresh()
  local plan = require("domain.mine.plan")
  local asked = nil
  site.attach({
    broadcast = function(body)
      asked = body
      -- Answered from inside the send, because `claim` polls the mailbox and a
      -- spec has no second coroutine to answer from.
      site.deliver({
        kind = "mine_result",
        requestId = body.requestId,
        ok = true,
        sector = 5,
        frontier = 2,
        plan = plan.normalise({
          configured = true,
          centreX = 0,
          centreZ = 0,
          surfaceY = 64,
          cellSize = 16,
          maxRing = 2,
          minRing = 1,
        }),
      })
      return true
    end,
  })

  local state = site.claim("rare@-59", 0, 0)
  expect.truthy(asked, "it asked")
  expect.equal(state.sector, 5, "took the sector it was given")
  expect.equal(state.frontier, 2, "and the frontier with it")
  expect.truthy(state.fromBase, "recorded as authoritative")

  site.attach(nil)
end)

it("a reply to somebody else's request is ignored", function()
  -- A delayed answer to an earlier claim must not assign this job the wrong
  -- sector. The request id is the whole of the defence.
  local site = fresh()
  site.attach({
    broadcast = function()
      site.deliver({ kind = "mine_result", requestId = "someone-else", ok = true, sector = 9 })
      return true
    end,
  })

  local state = site.claim("rare@-59", 0, 0)
  expect.falsy(state.sector == 9, "did not take the stray sector")
  expect.falsy(state.fromBase, "and fell through to offline")

  site.attach(nil)
end)

it("an explicit refusal is authoritative and is not second-guessed", function()
  -- Falling back after a refusal could resurrect an old grid after the base
  -- moved, or reopen a sector the configured capacity has exhausted.
  local site = fresh()
  site.attach({
    broadcast = function(body)
      site.deliver({
        kind = "mine_result",
        requestId = body.requestId,
        ok = false,
        message = "every sector in the plan is exhausted",
      })
      return true
    end,
  })

  local state, why = site.claim("rare@-59", 0, 0)
  expect.truthy(why, "refused with a reason")
  expect.contains(why, "exhausted", "passed through to the turtle's own log")
  expect.truthy(state.fromBase, "and recorded as an answer, not as silence")

  site.attach(nil)
end)

it("progress and surface reports are fire and forget", function()
  -- Neither waits for an answer, because the local copy is saved either way and
  -- a turtle whose base is gone must keep its own progress.
  local site = fresh()
  local sent = {}
  site.attach({
    broadcast = function(body)
      sent[#sent + 1] = body
      return true
    end,
  })

  site.report("rare@-59", 4, 6, 12, false)
  site.surface(4, { state = "open", headY = 71, headOffset = 2, reason = "no cap block" })

  expect.equal(#sent, 2, "both went out")
  expect.equal(sent[1].action, "report", "progress")
  expect.equal(sent[2].action, "surface", "and what was seen at the head")
  expect.equal(sent[2].state, "open", "carrying the state")

  site.attach(nil)
end)
