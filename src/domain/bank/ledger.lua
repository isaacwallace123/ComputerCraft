--- The ledger: accounts, balances, and the record of how they got that way.
---
--- Pure arithmetic over a table, with no clock, no radio and no disk - D041,
--- and it matters more here than anywhere else in the tree. Every rule that
--- keeps money from being invented or lost is in this file, which means every
--- one of them is a spec rather than a thing somebody watched work once.
---
--- ## Integers, always
---
--- Balances are whole units and nothing else. A Lua number is a double, and a
--- double serialised to a file and read back is a double *near* what was
--- written - so a system that stored 0.1 of anything would, given enough
--- transfers, hold a balance that is not a number anybody deposited. The unit is
--- whatever the base decides it is (a diamond, an ingot, a nugget); this file
--- only insists that there is no half of one.
---
--- ## A request is applied once
---
--- The single most important property, and the reason `request` is threaded
--- through every mutation. Rednet is not reliable in the direction that matters:
--- a reply can be lost after the server has already acted, and a client that
--- retries then sends a transfer the server has *already applied*. Retrying is
--- the correct client behaviour, so the ledger has to be the thing that makes it
--- safe.
---
--- So each mutation carries a caller-chosen id, and re-applying one returns the
--- original outcome without touching a balance. That turns "did my transfer go
--- through?" from a question with a dangerous answer into a question that can be
--- asked as many times as you like.
---
--- ## Balances are the truth, the journal is the story
---
--- The opposite of a classic event-sourced ledger, and deliberately. Replaying a
--- journal to derive balances would mean the journal can never be trimmed - and
--- this runs on a computer with a one-megabyte disk that has already filled
--- once. A trimmed journal under that design is not lost history, it is lost
--- money.
---
--- Here the balance is stored and the journal is a capped audit trail. Old
--- entries falling off the end costs the ability to say *when* something
--- happened, and costs nothing about what anybody has.

local ledger = {}

--- How many journal entries are kept.
---
--- Enough to answer "what happened to my money today" across a busy base, and
--- small enough that the file stays a few kilobytes. See the header for why
--- losing the oldest entries is safe here and would not be under event sourcing.
ledger.JOURNAL = 250

--- The largest balance an account may hold.
---
--- Not a policy about wealth - a guard against integer nonsense. Lua doubles
--- represent integers exactly up to 2^53, and a deposit that pushed a balance
--- past that would start rounding silently, which is the one failure mode this
--- file exists to prevent. Well below it, so no sum of two balances can reach it.
ledger.MAX = 2 ^ 40

--- How many ids a ledger remembers having applied.
---
--- The same cap as the journal and for the same reason. An id that has fallen
--- out of this table is one a retry could re-apply, so the window has to outlast
--- any client's retry loop - and a client still retrying after 250 transactions
--- of base activity has a problem no bookkeeping can fix.
ledger.SEEN = 250

--- What one unit is, unless the base says otherwise.
---
--- A label, not a rule. Nothing in this file cares what the unit is - the
--- arithmetic is the same for diamonds and for nuggets - but a page showing a
--- bare number is a page that cannot be read, and the answer to "units of what"
--- belongs with the balances rather than in whichever surface is drawing them.
ledger.UNIT = "minecraft:diamond"

function ledger.empty()
  return {
    accounts = {},
    journal = {},
    seq = 0,
    applied = {},
    unit = ledger.UNIT,
    -- The peripheral holding the physical currency, when a base has set one.
    -- Nil rather than auto-detected: picking the first attached inventory would
    -- mean a base that stores its diamonds in whichever chest was wired first,
    -- and being wrong about that is worse than not knowing.
    vault = nil,
  }
end

--- Make a ledger read off disk safe to use.
---
--- Every field defaulted and every balance forced back to a non-negative
--- integer. A half-written file is arithmetic on nil at the first transfer
--- otherwise, and unlike the device registry nothing in the world re-reports a
--- balance: there is no second copy of somebody's savings.
function ledger.normalise(saved)
  local state = ledger.empty()
  if type(saved) ~= "table" then
    return state
  end

  for id, account in pairs(saved.accounts or {}) do
    if type(id) == "string" and type(account) == "table" then
      local balance = math.floor(tonumber(account.balance) or 0)
      state.accounts[id] = {
        id = id,
        name = type(account.name) == "string" and account.name or id,
        balance = math.max(0, math.min(ledger.MAX, balance)),
        opened = tonumber(account.opened),
        updated = tonumber(account.updated),
      }
    end
  end

  for _, entry in ipairs(saved.journal or {}) do
    if type(entry) == "table" and tonumber(entry.amount) then
      state.journal[#state.journal + 1] = entry
    end
  end

  state.seq = math.floor(tonumber(saved.seq) or #state.journal)

  for request, seq in pairs(saved.applied or {}) do
    if type(request) == "string" and tonumber(seq) then
      state.applied[request] = math.floor(seq)
    end
  end

  if type(saved.unit) == "string" and saved.unit ~= "" then
    state.unit = saved.unit
  end
  if type(saved.vault) == "string" and saved.vault ~= "" then
    state.vault = saved.vault
  end

  return state
end

--- The small version of a ledger, for sending to a client.
---
--- A client draws balances; it does not audit. Sending the whole journal every
--- three seconds would put two hundred and fifty entries on the radio to render
--- the six a page has room for, on the machine whose entire job is redrawing
--- rows - so the mirror carries the accounts, the total, and the tail.
---
--- Shaped like a ledger rather than like a report, so the same page code reads
--- either one. A client's copy simply has a shorter journal, which is exactly
--- what being a mirror means everywhere else in this system.
function ledger.digest(state, limit)
  local journal = {}
  local recent = ledger.history(state, nil, limit or 12)
  -- Back into oldest-first order, because `history` reverses and the digest is
  -- still a journal: a reader that reversed it again would get the tail
  -- backwards, and nothing about the shape would say so.
  for index = #recent, 1, -1 do
    journal[#journal + 1] = recent[index]
  end

  return {
    accounts = state.accounts,
    journal = journal,
    seq = state.seq,
    unit = state.unit,
    vault = state.vault,
    total = ledger.total(state),
    -- Deliberately not sent. `applied` is how the *server* refuses to apply a
    -- request twice, and a client that held a copy would be holding a promise
    -- it cannot keep.
    applied = nil,
  }
end

---------------------------------------------------------------------------
-- Accounts
---------------------------------------------------------------------------

--- Normalise an account id.
---
--- Lowercased and trimmed, because the id is usually a player name typed by a
--- person and `Steve` paying `steve` two different balances is a bug that looks
--- exactly like theft. Returns nil for anything that is not usable as a key.
function ledger.key(id)
  if type(id) ~= "string" then
    return nil
  end
  local trimmed = id:match("^%s*(.-)%s*$"):lower()
  if trimmed == "" or #trimmed > 24 then
    return nil
  end
  return trimmed
end

function ledger.account(state, id)
  local key = ledger.key(id)
  if key == nil then
    return nil
  end
  return state.accounts[key]
end

--- Open an account, or hand back the one that already exists.
---
--- Not an error to open twice. The alternative - refusing - would mean a client
--- whose "account created" reply was lost can never make progress, which is the
--- same delivery problem `request` solves for transfers, and it is cheaper to
--- make this operation naturally idempotent than to give it an id.
---
--- The second return says whether it was created, so a caller can tell somebody
--- "already open" without that being a failure.
function ledger.open(state, id, name, now)
  local key = ledger.key(id)
  if key == nil then
    return nil, "an account needs a name of 1 to 24 characters"
  end

  local existing = state.accounts[key]
  if existing then
    return existing, false
  end

  state.accounts[key] = {
    id = key,
    -- The name as typed, kept beside the folded key. The key is for looking up
    -- and the name is for showing, and a page that showed the key would be a
    -- page that renders everybody's name in lower case.
    name = type(name) == "string" and name ~= "" and name or id,
    balance = 0,
    opened = now,
    updated = now,
  }
  return state.accounts[key], true
end

--- Every account, richest first.
---
--- Sorted here rather than in the page, because two surfaces draw this list and
--- a base whose terminal and monitor disagree about the order is a base whose
--- numbers look like they are changing when they are not.
function ledger.accounts(state)
  local out = {}
  for _, account in pairs(state.accounts) do
    out[#out + 1] = account
  end
  table.sort(out, function(a, b)
    if a.balance ~= b.balance then
      return a.balance > b.balance
    end
    return a.id < b.id
  end)
  return out
end

--- What the bank holds altogether.
function ledger.total(state)
  local sum = 0
  for _, account in pairs(state.accounts) do
    sum = sum + account.balance
  end
  return sum
end

---------------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------------

--- Is this a number of units that can be moved?
---
--- Whole, positive, and finite. Zero is refused rather than accepted as a no-op,
--- because a zero transfer is always a caller that computed an amount wrongly
--- and quietly succeeding would hide it.
---
--- A fraction is **refused, not rounded**, and that is the difference between
--- this and every other number in the codebase - `leases` floors a sector index
--- and is right to. Flooring 1.5 here would move one unit in answer to a request
--- for one and a half, and the person who typed it would have no way to know
--- which of the two happened. There is no half of a diamond, so there is no
--- reading of that request that is safe to guess at.
function ledger.amountOf(value)
  local amount = tonumber(value)
  -- `amount ~= amount` is the test for NaN, which arrives here as the result of
  -- somebody's arithmetic rather than as something typed - and which passes
  -- every comparison below without it.
  if amount == nil or amount ~= amount or amount == math.huge then
    return nil
  end
  if amount % 1 ~= 0 then
    return nil
  end
  if amount < 1 or amount > ledger.MAX then
    return nil
  end
  return amount
end

--- Remember that a request was applied, forgetting the oldest when full.
local function remember(state, request, seq)
  if request == nil then
    return
  end
  state.applied[request] = seq

  -- Counted by walking rather than kept as a running total, because a total
  -- would drift the moment `normalise` dropped a malformed entry - and a drifted
  -- count either grows this table without bound or evicts ids that are still
  -- live. It is at most 250 keys, once per transaction.
  local count = 0
  local oldest, oldestSeq = nil, math.huge
  for id, applied in pairs(state.applied) do
    count = count + 1
    if applied < oldestSeq then
      oldest, oldestSeq = id, applied
    end
  end
  if count > ledger.SEEN and oldest then
    state.applied[oldest] = nil
  end
end

--- Append to the audit trail, trimming the front when it is full.
local function post(state, entry)
  state.seq = state.seq + 1
  entry.seq = state.seq
  state.journal[#state.journal + 1] = entry

  if #state.journal > ledger.JOURNAL then
    table.remove(state.journal, 1)
  end
  return entry
end

--- The entry a request produced, if it has already been applied.
function ledger.replay(state, request)
  if request == nil then
    return nil
  end
  local seq = state.applied[request]
  if seq == nil then
    return nil
  end
  for _, entry in ipairs(state.journal) do
    if entry.seq == seq then
      return entry
    end
  end
  -- Applied, but old enough to have fallen off the journal. Still a refusal to
  -- apply it again: the point is that the money moved once, and being unable to
  -- say when is not a reason to move it twice.
  return { seq = seq, trimmed = true }
end

--- Money into the bank from outside it.
---
--- `from` is nil, and that is what makes a deposit distinguishable from a
--- transfer in the journal. Somebody auditing the bank needs to see where the
--- total went up, because that is the point where a person handed over something
--- real and the record is the only thing that says they did.
function ledger.deposit(state, id, amount, request, now, note)
  local replayed = ledger.replay(state, request)
  if replayed then
    return replayed, "already applied"
  end

  local account = ledger.account(state, id)
  if account == nil then
    return nil, "no such account"
  end

  local units = ledger.amountOf(amount)
  if units == nil then
    return nil, "a deposit is a whole number of units"
  end
  if account.balance + units > ledger.MAX then
    return nil, "that would overflow the account"
  end

  account.balance = account.balance + units
  account.updated = now

  local entry = post(state, {
    at = now,
    kind = "deposit",
    to = account.id,
    amount = units,
    note = note,
    balance = account.balance,
  })
  remember(state, request, entry.seq)
  return entry
end

--- Money out of the bank to outside it.
---
--- Refused rather than allowed to go negative. An overdraft is a loan, a loan is
--- a policy, and a ledger that silently made one would be a ledger whose total
--- no longer matches what the base is actually holding - which is the number the
--- whole thing is for.
function ledger.withdraw(state, id, amount, request, now, note)
  local replayed = ledger.replay(state, request)
  if replayed then
    return replayed, "already applied"
  end

  local account = ledger.account(state, id)
  if account == nil then
    return nil, "no such account"
  end

  local units = ledger.amountOf(amount)
  if units == nil then
    return nil, "a withdrawal is a whole number of units"
  end
  if units > account.balance then
    return nil, ("%s has %d, not %d"):format(account.name, account.balance, units)
  end

  account.balance = account.balance - units
  account.updated = now

  local entry = post(state, {
    at = now,
    kind = "withdraw",
    from = account.id,
    amount = units,
    note = note,
    balance = account.balance,
  })
  remember(state, request, entry.seq)
  return entry
end

--- Move units between two accounts.
---
--- One journal entry rather than a paired withdrawal and deposit. The pair would
--- be two rows that mean nothing apart, and a trim that dropped one of them
--- would leave an audit trail showing money appearing out of nowhere - which is
--- indistinguishable from the failure this whole file guards against.
---
--- The two sides are also applied together with no yield between them. That is
--- free here and worth naming: this is a cooperatively scheduled system, so
--- "atomic" means "contains no yield", and the day somebody puts a log write
--- between these two lines is the day money can disappear mid-transfer.
function ledger.transfer(state, fromId, toId, amount, request, now, note)
  local replayed = ledger.replay(state, request)
  if replayed then
    return replayed, "already applied"
  end

  local from = ledger.account(state, fromId)
  local to = ledger.account(state, toId)
  if from == nil then
    return nil, "no such account: " .. tostring(fromId)
  end
  if to == nil then
    return nil, "no such account: " .. tostring(toId)
  end
  if from.id == to.id then
    return nil, "that is the same account"
  end

  local units = ledger.amountOf(amount)
  if units == nil then
    return nil, "a transfer is a whole number of units"
  end
  if units > from.balance then
    return nil, ("%s has %d, not %d"):format(from.name, from.balance, units)
  end
  if to.balance + units > ledger.MAX then
    return nil, "that would overflow the destination"
  end

  from.balance = from.balance - units
  to.balance = to.balance + units
  from.updated = now
  to.updated = now

  local entry = post(state, {
    at = now,
    kind = "transfer",
    from = from.id,
    to = to.id,
    amount = units,
    note = note,
    balance = from.balance,
  })
  remember(state, request, entry.seq)
  return entry
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

--- The journal, newest first, optionally for one account.
---
--- Reversed rather than left in insertion order, because the question anybody
--- asks a transaction list is "what just happened" and a page that answered it
--- with the oldest surviving entry would be a page nobody reads twice.
function ledger.history(state, id, limit)
  local key = nil
  if id ~= nil then
    key = ledger.key(id)
  end
  local out = {}

  for index = #state.journal, 1, -1 do
    local entry = state.journal[index]
    if key == nil or entry.from == key or entry.to == key then
      out[#out + 1] = entry
      if limit and #out >= limit then
        break
      end
    end
  end

  return out
end

--- What one entry did, in one line.
---
--- In the domain because both surfaces and the console want the same sentence,
--- and three copies of it is three chances for the arrow to point the wrong way.
function ledger.describe(entry)
  if type(entry) ~= "table" then
    return ""
  end
  if entry.kind == "deposit" then
    return ("in  %d  %s"):format(entry.amount or 0, entry.to or "?")
  end
  if entry.kind == "withdraw" then
    return ("out %d  %s"):format(entry.amount or 0, entry.from or "?")
  end
  return ("%d  %s to %s"):format(entry.amount or 0, entry.from or "?", entry.to or "?")
end

return ledger
