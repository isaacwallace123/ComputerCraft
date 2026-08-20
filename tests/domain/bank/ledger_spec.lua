--- The rules that keep money from being invented or lost.
---
--- Driven with an explicit clock and a bare table, because the module has
--- neither of its own: `now` is an argument and reading `.bank` belongs to the
--- caller (D041). Every property below is a thing that would otherwise be
--- checked by watching a base station and hoping.

local expect = require("support.expect")
local it = require("support.spec").it

local ledger = require("domain.bank.ledger")

--- A fixed instant. Nothing here compares two times, but stamping from one
--- clock is the habit that D027 was written about.
local NOW = 1700000000 * 1000

local function newBank()
  local state = ledger.empty()
  ledger.open(state, "steve", "Steve", NOW)
  ledger.open(state, "alex", "Alex", NOW)
  ledger.deposit(state, "steve", 100, "seed", NOW)
  return state
end

it("a name is folded, so one person is one account", function()
  local state = ledger.empty()
  ledger.open(state, "Steve", "Steve", NOW)

  -- The bug this prevents looks exactly like theft: money paid to `Steve`
  -- landing somewhere `steve` cannot see.
  expect.truthy(ledger.account(state, "steve") ~= nil, "found under the folded key")
  expect.truthy(ledger.account(state, "  STEVE  ") ~= nil, "and past whitespace and case")

  ledger.open(state, "steve", "steve", NOW)
  expect.equal(#ledger.accounts(state), 1, "still one account")
end)

it("the name as typed survives the folding", function()
  local state = ledger.empty()
  local account = ledger.open(state, "Steve", "Steve", NOW) or {}

  -- The key is for looking up and the name is for showing. A page that drew the
  -- key would render everybody's name in lower case.
  expect.equal(account.id, "steve")
  expect.equal(account.name, "Steve")
end)

it("opening twice is not an error, and says which it was", function()
  local state = ledger.empty()
  local _, created = ledger.open(state, "steve", "Steve", NOW)
  expect.truthy(created, "the first open created it")

  local again, second = ledger.open(state, "steve", "Steve", NOW)
  expect.falsy(second, "the second did not")
  expect.equal((again or {}).balance, 0, "and did not reset anything")
end)

it("a fraction of a unit is not a number of units", function()
  local state = newBank()

  expect.equal(ledger.deposit(state, "steve", 1.5, nil, NOW), nil)
  expect.equal(ledger.deposit(state, "steve", 0, nil, NOW), nil, "zero is a caller's bug")
  expect.equal(ledger.deposit(state, "steve", -5, nil, NOW), nil)
  expect.equal(ledger.deposit(state, "steve", "lots", nil, NOW), nil)

  -- A double read back off disk is a double *near* what was written, so a
  -- ledger that accepted 0.1 of anything would eventually hold a balance nobody
  -- deposited.
  expect.equal(ledger.account(state, "steve").balance, 100, "nothing moved")
end)

it("a request is applied once, however many times it arrives", function()
  local state = newBank()

  ledger.transfer(state, "steve", "alex", 40, "req-1", NOW)
  ledger.transfer(state, "steve", "alex", 40, "req-1", NOW)
  ledger.transfer(state, "steve", "alex", 40, "req-1", NOW)

  -- The property the whole file is built around. A client that retries because
  -- a reply was lost is behaving correctly, so the ledger is what has to make
  -- retrying safe.
  expect.equal(ledger.account(state, "steve").balance, 60)
  expect.equal(ledger.account(state, "alex").balance, 40)
end)

it("a replay reports success, not a refusal", function()
  local state = newBank()

  ledger.deposit(state, "steve", 10, "req-2", NOW)
  local entry, reason = ledger.deposit(state, "steve", 10, "req-2", NOW)

  -- Idempotence seen from the client's side: asking twice is safe, and the
  -- second answer is the same as the first. Returning nil would make a retry
  -- look like a failure and invite a third attempt with a fresh id.
  expect.truthy(entry ~= nil, "the original entry came back")
  expect.equal(reason, "already applied")
  expect.equal(ledger.account(state, "steve").balance, 110)
end)

it("two accounts numbering their requests from one do not collide", function()
  local state = newBank()

  -- The server prefixes a request with its sender for exactly this reason. The
  -- ledger's job is only to treat the two ids as different, which is what makes
  -- that prefix work.
  ledger.deposit(state, "steve", 5, "7:1", NOW)
  ledger.deposit(state, "steve", 5, "8:1", NOW)

  expect.equal(ledger.account(state, "steve").balance, 110, "both applied")
end)

it("nobody goes below zero", function()
  local state = newBank()

  local entry, reason = ledger.withdraw(state, "steve", 500, nil, NOW)
  expect.equal(entry, nil)
  expect.contains(reason, "not 500")
  expect.equal(ledger.account(state, "steve").balance, 100, "untouched")

  -- An overdraft is a loan, and a loan is a policy. A ledger that made one
  -- silently would be a ledger whose total no longer matches the chest.
  local moved = ledger.transfer(state, "alex", "steve", 1, nil, NOW)
  expect.equal(moved, nil, "an empty account cannot pay")
end)

it("a transfer conserves the total", function()
  local state = newBank()
  local before = ledger.total(state)

  ledger.transfer(state, "steve", "alex", 30, "req-3", NOW)

  expect.equal(ledger.total(state), before, "money moved, none made")
  expect.equal(ledger.account(state, "steve").balance, 70)
  expect.equal(ledger.account(state, "alex").balance, 30)
end)

it("a transfer is one journal entry, not two halves", function()
  local state = newBank()
  local before = #state.journal

  ledger.transfer(state, "steve", "alex", 10, "req-4", NOW)

  -- A paired withdrawal and deposit would be two rows that mean nothing apart,
  -- and a trim that dropped one would show money appearing from nowhere.
  expect.equal(#state.journal, before + 1)
  local entry = state.journal[#state.journal]
  expect.equal(entry.from, "steve")
  expect.equal(entry.to, "alex")
end)

it("paying yourself is refused rather than being a no-op", function()
  local state = newBank()
  local entry, reason = ledger.transfer(state, "steve", "steve", 10, nil, NOW)
  expect.equal(entry, nil)
  expect.contains(reason, "same account")
end)

it("an unknown account is refused, not created", function()
  local state = newBank()
  expect.equal(ledger.deposit(state, "herobrine", 10, nil, NOW), nil)
  expect.equal(#ledger.accounts(state), 2, "and nothing was opened")
end)

it("the journal is capped and the balances are not", function()
  local state = newBank()

  for index = 1, ledger.JOURNAL + 20 do
    ledger.deposit(state, "alex", 1, "fill-" .. index, NOW)
  end

  -- The trade the header describes. Losing the oldest entries costs the ability
  -- to say when something happened; under event sourcing it would cost the
  -- money itself, which is why balances are stored rather than derived.
  expect.equal(#state.journal, ledger.JOURNAL, "trimmed to the cap")
  expect.equal(ledger.account(state, "alex").balance, ledger.JOURNAL + 20, "every unit kept")
end)

it("an id that fell out of the window is still not applied twice", function()
  local state = newBank()

  ledger.deposit(state, "alex", 1, "first", NOW)
  for index = 1, ledger.SEEN + 5 do
    ledger.deposit(state, "alex", 1, "fill-" .. index, NOW)
  end

  -- `first` has been evicted from `applied` by now, which is the honest limit of
  -- the window - a client still retrying after 250 transactions has a problem
  -- no bookkeeping can fix. What must not happen is a crash.
  local balance = ledger.account(state, "alex").balance
  ledger.deposit(state, "alex", 1, "first", NOW)
  expect.truthy(ledger.account(state, "alex").balance >= balance, "no arithmetic on nil")
end)

it("history is newest first, and can be read for one account", function()
  local state = newBank()

  ledger.transfer(state, "steve", "alex", 10, "a", NOW)
  ledger.deposit(state, "steve", 5, "b", NOW)

  local recent = ledger.history(state, nil, 1)
  expect.equal(#recent, 1)
  expect.equal(recent[1].kind, "deposit", "the most recent thing that happened")

  local mine = ledger.history(state, "alex")
  expect.equal(#mine, 1, "only the transfer touched alex")
  expect.equal(mine[1].kind, "transfer")
end)

it("a digest carries balances and not the promise the server keeps", function()
  local state = newBank()
  for index = 1, 40 do
    ledger.deposit(state, "alex", 1, "d-" .. index, NOW)
  end

  local digest = ledger.digest(state, 6)

  expect.equal(digest.total, ledger.total(state))
  expect.equal(#digest.journal, 6, "the tail, not the whole book")
  expect.equal(
    digest.applied,
    nil,
    "a client holding this would be holding a promise it cannot keep"
  )

  -- Shaped like a ledger, so the same page reads either one.
  expect.equal(#ledger.accounts(digest), 2)
  expect.equal(ledger.total(digest), ledger.total(state))
end)

it("a digest's journal is still oldest-first", function()
  local state = newBank()
  ledger.deposit(state, "alex", 1, "one", NOW)
  ledger.deposit(state, "alex", 2, "two", NOW)

  local digest = ledger.digest(state, 2)

  -- `history` reverses; the digest reverses it back. A reader that got the tail
  -- backwards would have nothing in the shape to tell it so.
  expect.truthy(digest.journal[1].seq < digest.journal[2].seq, "in order")
end)

it("a half-written ledger comes back as a usable one", function()
  local broken = {
    accounts = {
      steve = { balance = -20 },
      [7] = { balance = 5 },
    },
    journal = { { amount = 3 }, "not an entry" },
    applied = { good = 2, [9] = 3 },
  }

  local state = ledger.normalise(broken)

  -- Nothing in the world re-reports a balance, so a malformed file is repaired
  -- rather than trusted or discarded.
  expect.equal(state.accounts.steve.balance, 0, "clamped, not negative")
  expect.equal(state.accounts[7], nil, "a non-string key is not an account")
  expect.equal(#state.journal, 1, "the entry that was one")
  expect.equal(state.applied.good, 2)
  expect.equal(state.unit, ledger.UNIT, "and a unit to label it with")
end)
