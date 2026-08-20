--- The seam that makes a button work on the machine that owns the state.
---
--- Written after an in-world report that Deploy, Recall and Stop did nothing on
--- the base station and worked from every other computer. The cause was not in
--- any of those pages: rednet does not loop back, so a server broadcasting to
--- itself was addressing a message to a listener that cannot exist.
---
--- No radio here and no supervisor - a fake transport and a fake dispatcher are
--- enough, because the whole question is which of the two a page's message goes
--- down.

local expect = require("support.expect")
local it = require("support.spec").it

local request = require("os.kernel.request")
local wire = require("domain.protocol.message")

--- A transport that remembers rather than sends.
local function recorder()
  local sent = {}
  return sent,
    {
      broadcast = function(message, protocol)
        sent[#sent + 1] = { message = message, protocol = protocol }
      end,
    }
end

it("a remote request goes out stamped, so a rolling update can read it", function()
  local sent, transport = recorder()

  local ask = request.remote(transport, "icos")
  expect.truthy(ask({ kind = "want", id = 7, mode = "deploy" }))

  expect.equal(#sent, 1)
  expect.equal(sent[1].protocol, "icos")

  -- Stamped here rather than by each caller. The version field is what makes a
  -- device on an old build safe against a new server, and "the app forgot to
  -- stamp it" is a failure with no error message.
  expect.equal(sent[1].message.v, wire.VERSION)
end)

it("a machine with no radio refuses rather than throwing", function()
  local ask = request.remote(nil, "icos")

  -- A headless spec context and a computer whose modem was broken off look the
  -- same from here, and neither is a reason to take the page down.
  expect.falsy(ask({ kind = "want" }))
end)

it("a loopback request reaches the handlers instead of the air", function()
  local seen = {}
  local ask = request.loopback({ marker = true }, function(context, sender, message)
    seen[#seen + 1] = { context = context, sender = sender, message = message }
    return { { kind = "want_result", ok = true } }
  end, 5)

  local replies = ask({ kind = "want", id = 7, mode = "deploy" })

  expect.equal(#seen, 1, "the server's own dispatcher was called")
  expect.truthy(seen[1].context.marker, "with the context it belongs to")

  -- The machine's own id, not a special value. A handler that treated "from
  -- myself" differently would grow a second code path that only ever runs on a
  -- base with a monitor, which is the least tested machine in the fleet.
  expect.equal(seen[1].sender, 5)
  expect.equal(seen[1].message.v, wire.VERSION, "stamped on this path too")

  -- And the reply is in hand, which is the one thing the radio path cannot do.
  expect.equal(#replies, 1)
end)

it("a page picks the sender off the context and cannot tell which it got", function()
  local sent, transport = recorder()

  local remote = request.of({ transport = transport }, "icos")
  remote({ kind = "want" })
  expect.equal(#sent, 1, "no request function means the radio")

  local delivered = 0
  local local_ = request.of({
    transport = transport,
    request = function()
      delivered = delivered + 1
      return {}
    end,
  })
  local_({ kind = "want" })

  expect.equal(delivered, 1, "a request function wins")
  expect.equal(#sent, 1, "and nothing went out twice")
end)

it("a context that is not one is not a crash", function()
  -- Every spec that builds a context by hand goes through here, and so does
  -- every machine on a build older than this file.
  expect.falsy(request.of(nil)({ kind = "want" }))
  expect.falsy(request.of({})({ kind = "want" }))
end)
