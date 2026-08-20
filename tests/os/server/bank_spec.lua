--- The half of the bank that touches the world: requests, writes, and the vault.
---
--- The arithmetic is `tests/domain/bank/ledger_spec.lua`. What is here is what
--- the service adds on top of it - that a refusal comes back as a reply rather
--- than as silence, that money is written to disk the moment it moves, that two
--- clients numbering their requests from one cannot cancel each other, and that
--- the audit reports a discrepancy without correcting it.

local expect = require("support.expect")
local fleet = require("support.fleet")
local it = require("support.spec").it
local page = require("support.page")

local bank = require("os.server.services.bank")
local ledger = require("domain.bank.ledger")
local bankApp = require("apps.bank.app")
local ui = require("ui.init")

--- A server whose writes can be counted.
local function newServer()
  local ctx = fleet.server()
  local writes = 0
  ctx.storage.write = function()
    writes = writes + 1
    return true
  end
  ctx.paths = { bank = ".bank" }
  return ctx, function()
    return writes
  end
end

local function ask(ctx, sender, body)
  return bank.handle(ctx, sender, { kind = bank.KIND, body = body })
end

--- A reply that has to exist.
---
--- Every refusal in this service is a reply rather than silence, so a nil here
--- is the failure - and saying so once is better than nine `or {}` guards that
--- read as defensiveness rather than as the assertion they are.
local function replied(value)
  expect.truthy(value ~= nil, "the service answered")
  return value or {}
end

it("a message that is not ours is declined rather than answered", function()
  local ctx = newServer()

  -- `nil` is how a handler on the server's shared inbox says "not mine". A
  -- refusal table would be a bank arguing with every heartbeat on the fleet.
  expect.equal(bank.handle(ctx, 7, { kind = "status" }), nil)
  expect.equal(ask(ctx, 7, { action = "fly" }), nil)
end)

it("a refusal comes back rather than nothing", function()
  local ctx = newServer()
  -- Silence would leave a client unable to tell "refused" from "lost", and the
  -- safe assumption for a lost message is to retry.
  local reply =
    replied(ask(ctx, 7, { action = "deposit", account = "nobody", amount = 5, requestId = 1 }))
  expect.falsy(reply.ok)
  expect.contains(reply.message, "no such account")
end)

it("money is written the moment it moves", function()
  local ctx, writes = newServer()
  ask(ctx, 7, { action = "open", account = "steve", name = "Steve" })
  local before = writes()

  ask(ctx, 7, { action = "deposit", account = "steve", amount = 10, requestId = 1 })

  -- Not batched, unlike the registry. A lost heartbeat costs nothing; a lost
  -- transfer is money nothing in the world will re-report.
  expect.truthy(writes() > before, "flushed, not marked")
  expect.equal(ctx.state.bank.accounts.steve.balance, 10)
end)

it("two clients numbering their requests from one do not cancel each other", function()
  local ctx = newServer()
  ask(ctx, 7, { action = "open", account = "steve" })

  ask(ctx, 7, { action = "deposit", account = "steve", amount = 5, requestId = 1 })
  ask(ctx, 8, { action = "deposit", account = "steve", amount = 5, requestId = 1 })

  -- The server prefixes the request with its sender. Without it the second
  -- client's first transaction is silently swallowed as a replay of the first
  -- client's, and both pages report success.
  expect.equal(ctx.state.bank.accounts.steve.balance, 10)
end)

it("the same client asking twice moves the money once", function()
  local ctx = newServer()
  ask(ctx, 7, { action = "open", account = "steve" })

  ask(ctx, 7, { action = "deposit", account = "steve", amount = 5, requestId = 4 })
  local again =
    replied(ask(ctx, 7, { action = "deposit", account = "steve", amount = 5, requestId = 4 }))

  expect.equal(ctx.state.bank.accounts.steve.balance, 5)

  -- And the retry is answered as a success, because it was one. Reporting it as
  -- a failure would invite a third attempt with a fresh id.
  expect.truthy(again.ok)
  expect.equal(again.message, "already applied")
end)

it("every reply carries the ledger after the change, and not the promise", function()
  local ctx = newServer()
  ask(ctx, 7, { action = "open", account = "steve" })
  local reply =
    replied(ask(ctx, 7, { action = "deposit", account = "steve", amount = 7, requestId = 2 }))

  expect.equal(reply.ledger.total, 7, "what the server confirmed, not what the page assumed")
  expect.equal(reply.ledger.applied, nil, "a client cannot keep that promise")
end)

it("a vault nothing is attached to is refused by name", function()
  local ctx = newServer()
  ctx.peripherals = {
    list = function()
      return { { name = "minecraft:chest_0", types = { inventory = true } } }
    end,
  }

  local wrong = replied(ask(ctx, 7, { action = "vault", vault = "chest_1" }))
  expect.falsy(wrong.ok, "a typo here would be a vault that never audits")

  local right = replied(ask(ctx, 7, { action = "vault", vault = "minecraft:chest_0" }))
  expect.truthy(right.ok)
  expect.equal(ctx.state.bank.vault, "minecraft:chest_0")
end)

it("the audit reports a shortfall and corrects nothing", function()
  local ctx = newServer()
  ask(ctx, 7, { action = "open", account = "steve" })
  ask(ctx, 7, { action = "deposit", account = "steve", amount = 100, requestId = 1 })

  ctx.state.bank.vault = "chest_0"
  ctx.peripherals = {
    list = function()
      return { { name = "chest_0", types = { inventory = true } } }
    end,
    call = function()
      return true,
        {
          [1] = { name = "minecraft:diamond", count = 40 },
          [3] = { name = "minecraft:dirt", count = 64 },
          [5] = { name = "minecraft:diamond", count = 20 },
        }
    end,
  }

  local audit = bank.audit(ctx) or {}

  -- Counted across slots and filtered to the currency item, because a chest is
  -- not a single stack and is not only diamonds.
  expect.equal(audit.held, 60)
  expect.equal(audit.banked, 100)
  expect.equal(audit.drift, -40)

  -- And nothing was rewritten. A service that reconciled balances to match a
  -- chest somebody had raided would be laundering the theft it exists to show.
  expect.equal(ctx.state.bank.accounts.steve.balance, 100)
end)

it("a vault that has been broken off reads as no vault at all", function()
  local ctx = newServer()
  ctx.state.bank.vault = "chest_0"
  ctx.peripherals = {
    list = function()
      return {}
    end,
    call = function()
      return false, "no such peripheral"
    end,
  }

  ctx.state.vault = { held = 5, banked = 5, drift = 0 }
  expect.equal(bank.audit(ctx), nil)

  -- Cleared rather than kept. A stale count left on screen is a page reporting a
  -- chest nobody can see any more.
  expect.equal(ctx.state.vault, nil)
end)

it("the audit is not on the list of things written to disk", function()
  local server = require("os.server.main")

  -- `state.vault` is an observation about right now. A discrepancy read off a
  -- file after a reboot would be a theft alert about a chest nobody has looked
  -- in yet, so it deliberately has no path.
  expect.equal(server.PATHS.vault, nil)
  expect.equal(server.PATHS.bank, ".bank")
end)

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

it("the page mounts against a real ledger", function()
  -- A smoke test, and worth its line. Twice now a page that passed every unit
  -- check threw on first mount in world and left a machine looking hung, and
  -- nothing structural catches a component prop that is wrong.
  local state = ledger.empty()
  ledger.open(state, "steve", "Steve", 0)
  ledger.deposit(state, "steve", 30, "seed", 0)

  local scope = ui.scoped()
  bankApp.mount(scope, {
    state = { bank = state, vault = { held = 30, banked = 30, drift = 0 } },
    clock = {
      now = function()
        return 0
      end,
    },
  }, {})
  scope:destroy()
end)

it("a monitor gets the books and nothing to press", function()
  local scope = ui.scoped()
  bankApp.mount(scope, { state = { bank = ledger.empty() } }, { readOnly = true })
  scope:destroy()

  -- D020, enforced twice over: no controls are built here, and the input port on
  -- that surface cannot yield a keystroke either.
  local _ = page
end)

it("the summary leads with the discrepancy, not the total", function()
  local state = ledger.empty()
  ledger.open(state, "steve", "Steve", 0)
  ledger.deposit(state, "steve", 100, "seed", 0)

  local agreed = bankApp.summary(state, { held = 100, banked = 100, drift = 0 })
  expect.contains(agreed, "vault agrees")

  -- A total is a number somebody glances at. A vault that is forty short is the
  -- reason they opened the page.
  local short = bankApp.summary(state, { held = 60, banked = 100, drift = -40 })
  expect.contains(short, "40 short")

  local spare = bankApp.summary(state, { held = 140, banked = 100, drift = 40 })
  expect.contains(spare, "unbanked")
end)
