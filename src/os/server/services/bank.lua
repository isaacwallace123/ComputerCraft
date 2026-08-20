--- The bank: the service that owns the ledger and the vault it is supposed to match.
---
--- The rules are all in `domain/bank/ledger.lua` and are not restated here. This
--- file is the half that touches the world: it owns the state, answers requests
--- about it, writes it to disk, and periodically counts what is physically in
--- the vault to see whether the books still describe reality.
---
--- ## Why the bank is a service and not an app
---
--- D018, the same rule that took sector leasing out of the Fleet page. A bank
--- that lived inside a page would stop accepting deposits the moment somebody
--- closed the page, and the person whose deposit was refused would be standing
--- somewhere else entirely. Services own state, apps read it.
---
--- ## Every write is immediate
---
--- The opposite of the device registry, and this is the clearest case in the
--- codebase for it. A lost heartbeat costs nothing, because the turtle sends
--- another one in two seconds. A lost *transfer* is money that left one account
--- and never arrived in the other, and nothing in the world will re-report it -
--- there is no second copy of somebody's savings.
---
--- So `persist.flush` after every mutation, and `bank` is not in
--- `persist.BATCHED`. The cost is a disk write per transaction, and transactions
--- are minutes apart on the busiest base anybody will build here.
---
--- ## The audit is the reason this has a loop
---
--- A ledger is a claim about a chest. The claim is worth nothing unless somebody
--- checks it, and a base is a place where people take things out of chests.
---
--- So when a vault peripheral has been named, the service counts the currency
--- item in it every so often and records the difference. It does **not**
--- correct anything: the ledger is the record of what people agreed to, and a
--- service that silently rewrote balances to match a chest somebody had raided
--- would be laundering the theft it exists to reveal.

local ledger = require("domain.bank.ledger")
local persist = require("os.server.services.persist")
local service = require("os.kernel.service")
local wire = require("domain.protocol.message")

local bank = {}

bank.PROTOCOL = wire.NAME

--- The message kind that carries a bank request, in both directions.
---
--- One kind for the question and the answer, like `mineplan` - and the answer
--- always carries the ledger *after* the change. A client that applied a change
--- and then displayed what it assumed would be showing something it inferred
--- rather than something the server confirmed, which for money is the difference
--- between a balance and a guess.
bank.KIND = "bank"

--- The section name this service persists under.
bank.SECTION = "bank"

--- How often the vault is counted, in seconds.
---
--- Thirty. Slow, on purpose: counting means calling `list` on an inventory
--- peripheral, which walks every slot, and a discrepancy that is thirty seconds
--- old is exactly as actionable as one that is one second old. Nobody puts a
--- chest back.
bank.AUDIT = 30

--- How many journal entries a client's mirror carries.
bank.DIGEST = 12

local function refuse(body, message)
  return { kind = bank.KIND, ok = false, requestId = body and body.requestId, message = message }
end

--- The reply every successful action sends: what happened, and the state after.
local function confirm(state, body, entry, note)
  return {
    kind = bank.KIND,
    ok = true,
    requestId = body and body.requestId,
    entry = entry,
    note = note,
    ledger = ledger.digest(state, bank.DIGEST),
  }
end

---------------------------------------------------------------------------
-- The vault
---------------------------------------------------------------------------

--- How many units of the currency item are physically in the vault.
---
--- Returns nil when there is nothing to count, which is three different
--- situations that all mean the same thing to a caller: no vault named, no
--- peripherals port on this machine, or the chest is gone. Distinguishing them
--- would be a page with three ways of saying "no number".
---
--- Counted by walking `list` rather than by asking for a total, because there is
--- no peripheral method that answers "how many of this item" - and because the
--- walk is what makes the count work for any inventory any mod provides, which
--- is the whole point of doing it through a peripheral name.
function bank.count(context)
  local state = context.state[bank.SECTION]
  if state == nil or state.vault == nil or context.peripherals == nil then
    return nil
  end

  local ok, contents = context.peripherals.call(state.vault, "list")
  if not ok or type(contents) ~= "table" then
    return nil
  end

  local unit = state.unit or ledger.UNIT
  local held = 0
  for _, item in pairs(contents) do
    if type(item) == "table" and item.name == unit then
      held = held + (tonumber(item.count) or 0)
    end
  end
  return held
end

--- Compare the vault against the books.
---
--- Written to `state.vault`, which is state with no path in `server.PATHS` and
--- is therefore never persisted. That separation is the point. The ledger is
--- what people agreed to and belongs on disk; the audit is an observation about
--- right now and belongs nowhere permanent - a stale discrepancy read off a file
--- after a reboot would be a theft alert about a chest nobody has looked in yet.
---
--- It lives on `state` rather than on the context so that a page reads it the
--- same way on a server as on a client, where it arrives over the mirror. A page
--- that had to know which kind of machine it was drawing on would be a page with
--- two ways of being wrong.
function bank.audit(context)
  local state = context.state[bank.SECTION]
  if state == nil then
    return nil
  end

  local held = bank.count(context)
  if held == nil then
    context.state.vault = nil
    return nil
  end

  local banked = ledger.total(state)
  context.state.vault = {
    at = context.clock.now(),
    held = held,
    banked = banked,
    -- Positive means the chest holds more than anybody has claimed, which is
    -- somebody's un-deposited change. Negative means the chest holds less than
    -- the books say, which is the number worth a red row.
    drift = held - banked,
  }
  return context.state.vault
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------

--- Point the bank at the chest its currency lives in.
---
--- Checked against the attached peripherals rather than taken on trust, because
--- a typo here produces a vault that never audits and a page that says "no
--- vault" forever - which looks identical to not having set one.
function bank.setVault(context, state, body)
  local name = body.vault

  if name == nil or name == "" then
    state.vault = nil
    persist.flush(context, bank.SECTION)
    return confirm(state, body, nil, "vault cleared")
  end

  if type(name) ~= "string" then
    return refuse(body, "a vault is a peripheral name")
  end
  if context.peripherals == nil then
    return refuse(body, "this machine cannot see peripherals")
  end

  local found = false
  for _, entry in ipairs(context.peripherals.list()) do
    if entry.name == name then
      found = true
    end
  end
  if not found then
    return refuse(body, "nothing attached is called " .. name)
  end

  state.vault = name
  if type(body.unit) == "string" and body.unit ~= "" then
    state.unit = body.unit
  end
  persist.flush(context, bank.SECTION)

  return confirm(state, body, nil, "vault set to " .. name)
end

--- Answer a bank request.
---
--- Returns a reply, or nil when the message is not one of ours. Every refusal is
--- a reply rather than silence: a client that asked to move money and heard
--- nothing cannot tell "refused" from "lost", and the safe assumption for a lost
--- message is to retry - which is the exact case the ledger's request ids exist
--- to survive, and there is no reason to make them do that work unnecessarily.
function bank.handle(context, sender, message)
  if type(message) ~= "table" or message.kind ~= bank.KIND then
    return nil
  end
  local body = message.body
  if type(body) ~= "table" then
    return nil
  end

  local state = context.state[bank.SECTION]
  if state == nil then
    return refuse(body, "this machine has no ledger")
  end

  local now = context.clock.now()
  local action = body.action

  if action == "read" then
    return confirm(state, body, nil, nil)
  end

  if action == "vault" then
    return bank.setVault(context, state, body)
  end

  if action == "open" then
    local account, created = ledger.open(state, body.account, body.name, now)
    if account == nil then
      return refuse(body, created)
    end
    persist.flush(context, bank.SECTION)
    return confirm(state, body, nil, created and ("opened " .. account.name) or "already open")
  end

  -- The three that move money. The request id is the sender's own, prefixed
  -- with who sent it: two clients that each numbered their requests from one
  -- would otherwise cancel each other's transfers, and each would see its own
  -- as having succeeded.
  local request = nil
  if body.requestId ~= nil then
    request = tostring(sender) .. ":" .. tostring(body.requestId)
  end

  local entry, reason
  if action == "deposit" then
    entry, reason = ledger.deposit(state, body.account, body.amount, request, now, body.note)
  elseif action == "withdraw" then
    entry, reason = ledger.withdraw(state, body.account, body.amount, request, now, body.note)
  elseif action == "transfer" then
    entry, reason = ledger.transfer(state, body.from, body.to, body.amount, request, now, body.note)
  else
    return nil
  end

  if entry == nil then
    return refuse(body, reason)
  end

  persist.flush(context, bank.SECTION)

  -- `reason` is "already applied" on a replay, and it goes back as a note on a
  -- *successful* reply rather than as a refusal. That is the whole idempotence
  -- contract seen from the client's side: asking twice is safe, and the second
  -- answer is the same as the first.
  return confirm(state, body, entry, reason)
end

bank.service = service.define({
  id = "bank",
  requires = { "clock", "state", "storage", "serialise" },

  -- Not critical, and the distinction is the one `os/kernel/service.lua`
  -- describes: a fleet with no bank still mines. What a stopped bank costs is
  -- the vault audit - requests are answered on the inbox, which `discovery`
  -- owns - so a base whose bank service has given up still banks, and simply
  -- stops noticing that its chest disagrees.
  critical = false,

  run = function(context)
    while true do
      bank.audit(context)
      context.clock.sleep(context.auditSeconds or bank.AUDIT)
      if coroutine.isyieldable() then
        coroutine.yield()
      end
    end
  end,
})

return bank
