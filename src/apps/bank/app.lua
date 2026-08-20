--- Bank: who has what, and what the vault says about it.
---
--- The reading half of `domain/bank/ledger.lua`. Balances, the audit trail, and
--- four buttons that ask the server to move something - it holds no money and
--- decides nothing, which is D018 and is the reason the bank is a service.
---
--- ## The selected row is the account
---
--- Every action needs an account, and typing a name for each one on a
--- 51-column screen would be a form nobody fills in twice. So the table is the
--- subject: select a row, then deposit, withdraw or pay. The one field that is
--- not the selection is the *other* party in a transfer, and the same field
--- opens an account, because those are the only two moments a name has to be
--- typed rather than picked.
---
--- ## What it will not do
---
--- Move anything by itself. A page that reconciled the vault would be a page
--- that could quietly write off a discrepancy, and the discrepancy is the one
--- thing here worth looking at - see the audit note in the bank service.

local ledger = require("domain.bank.ledger")
local reactive = require("ui.state.reactive")
local request = require("os.kernel.request")
local theme = require("ui.theme")

local T = theme.TOKENS

local app = {}

--- The message that asks the server to do something with the books.
---
--- Built as a pure function so a spec can assert on the shape without a radio,
--- which is the same reason `apps/fleet/app.lua` has `intent`.
function app.intent(action, fields)
  if type(action) ~= "string" then
    return nil
  end
  local body = { action = action }
  for key, value in pairs(fields or {}) do
    body[key] = value
  end
  return { kind = "bank", body = body }
end

--- One row per account.
function app.rows(state)
  if type(state) ~= "table" then
    return {}
  end

  local rows = {}
  for _, account in ipairs(ledger.accounts(state)) do
    rows[#rows + 1] = {
      id = account.id,
      name = account.name,
      balance = tostring(account.balance),
      -- An empty account is not a fault, but it is the row somebody is looking
      -- for when a payment did not arrive.
      tone = account.balance > 0 and T.foreground or T.mutedFg,
    }
  end
  return rows
end

function app.columns()
  return {
    { Title = "Account", Grow = 1, Key = "name" },
    {
      Title = "Balance",
      Width = 10,
      Key = "balance",
      Align = "right",
      Tone = function(row)
        return row.tone
      end,
    },
  }
end

--- The headline: what the bank holds, and whether the chest agrees.
---
--- The drift wins the line when there is one. A total is a number somebody
--- glances at; a vault that is forty short is the reason they opened the page.
function app.summary(state, vault)
  if type(state) ~= "table" then
    return "waiting for the server", T.mutedFg
  end

  local total = ledger.total(state)
  local count = #ledger.accounts(state)

  if type(vault) == "table" and vault.drift ~= 0 then
    if vault.drift < 0 then
      return ("vault is %d short of the books"):format(-vault.drift), T.destructive
    end
    return ("%d unbanked in the vault"):format(vault.drift), T.warn
  end

  if type(vault) == "table" then
    return ("%d banked, vault agrees"):format(total), T.good
  end

  return ("%d across %d account%s"):format(total, count, count == 1 and "" or "s"), T.mutedFg
end

--- The bottom line: the last thing the server said, or the last thing that
--- happened.
---
--- The note wins while there is one, because it is the answer to the button
--- somebody just pressed and a page that replaced it with history would be a
--- page that never confirms anything.
function app.footer(state, note)
  if note ~= nil and note ~= "" then
    return note
  end
  if type(state) ~= "table" then
    return "no ledger on this machine"
  end
  local recent = ledger.history(state, nil, 1)[1]
  if recent == nil then
    return "nothing has moved yet"
  end
  return ledger.describe(recent)
end

function app.mount(scope, context, options)
  options = options or {}
  local tick = options.tick or scope:Value(0)

  local books = scope:Computed(function(use)
    use(tick)
    return context.state and context.state.bank or nil
  end)

  local vault = scope:Computed(function(use)
    use(tick)
    return context.state and context.state.vault or nil
  end)

  local rows = scope:Computed(function(use)
    return app.rows(use(books))
  end)

  local selected = options.selected or scope:Value(nil)
  local who = scope:Value("")
  local amount = scope:Value("")
  local note = scope:Value(nil)

  local ask = request.of(context, options.protocol)

  --- A caller-chosen id, so a retry cannot move money twice.
  ---
  --- Counted from a clock reading rather than from one, because a page that
  --- numbered its requests from one would restart at one after a reboot and its
  --- second session would replay the first session's ids - which the ledger
  --- would dutifully refuse as already applied, silently dropping every real
  --- transaction. See `domain/bank/ledger.lua`.
  local counter = context.clock and context.clock.now() or 0
  local function nextId()
    counter = counter + 1
    return counter
  end

  --- Send one action and show whatever came back immediately.
  ---
  --- On a server the reply is in hand, because `request` delivered locally. On a
  --- client there is nothing to show yet and the next mirror carries the result
  --- three seconds later - so the note is set optimistically to nothing rather
  --- than to a guess about what the server will say.
  local function act(action, fields)
    fields = fields or {}
    fields.requestId = nextId()

    local message = app.intent(action, fields)
    if message == nil then
      return
    end

    local replies = ask(message)
    note:set(nil)

    if type(replies) == "table" then
      for _, reply in ipairs(replies) do
        if type(reply) == "table" and reply.kind == "bank" then
          note:set(reply.message or (reply.ok and "done" or "refused"))
        end
      end
    end
  end

  --- The amount currently typed, or nil when it is not a number to move.
  local function units()
    return ledger.amountOf(reactive.peek(amount))
  end

  local function account()
    return reactive.peek(selected)
  end

  --- Nothing selected, or nothing typed, disables the three that move money.
  ---
  --- Derived rather than stored, so there is no second piece of state that can
  --- disagree with the field it describes - the same rule the Automation page's
  --- switches follow.
  local idle = scope:Computed(function(use)
    use(tick)
    return use(selected) == nil or ledger.amountOf(use(amount)) == nil
  end)

  local canOpen = scope:Computed(function(use)
    return ledger.key(use(who)) == nil
  end)

  local canPay = scope:Computed(function(use)
    return use(idle) or ledger.key(use(who)) == nil
  end)

  local children = {
    scope:Table({
      Columns = app.columns(),
      Rows = rows,
      Selected = selected,
      Capacity = options.capacity or 5,
      OnSelect = function(row)
        selected:set(row and row.id or nil)
      end,
    }),
    scope:Separator({}),
  }

  -- A monitor has no keyboard, so it gets the books and nothing to press.
  -- D020, and enforced twice: the callbacks are absent here *and* the input port
  -- on that surface cannot yield a keystroke.
  if not options.readOnly then
    children[#children + 1] = scope:Row({
      Height = 1,
      Children = {
        scope:Field({
          Grow = 1,
          Value = amount,
          Placeholder = "amount",
          MaxLength = 12,
          OnChange = function(text)
            amount:set(text)
          end,
        }),
        scope:Button({
          Text = "In",
          Size = "sm",
          Variant = "primary",
          Disabled = idle,
          OnClick = function()
            act("deposit", { account = account(), amount = units() })
          end,
        }),
        scope:Button({
          Text = "Out",
          Size = "sm",
          Disabled = idle,
          OnClick = function()
            act("withdraw", { account = account(), amount = units() })
          end,
        }),
      },
    })

    children[#children + 1] = scope:Row({
      Height = 1,
      Children = {
        scope:Field({
          Grow = 1,
          Value = who,
          Placeholder = "other account",
          MaxLength = 24,
          OnChange = function(text)
            who:set(text)
          end,
        }),
        scope:Button({
          Text = "Pay",
          Size = "sm",
          Variant = "primary",
          Disabled = canPay,
          OnClick = function()
            act("transfer", {
              from = account(),
              to = reactive.peek(who),
              amount = units(),
            })
          end,
        }),
        scope:Button({
          Text = "Open",
          Size = "sm",
          Disabled = canOpen,
          OnClick = function()
            local name = reactive.peek(who)
            act("open", { account = name, name = name })
            who:set("")
          end,
        }),
      },
    })
  end

  children[#children + 1] = scope:Muted({
    Height = 1,
    Text = scope:Computed(function(use)
      return app.footer(use(books), use(note))
    end),
  })

  return scope:Page({
    Title = "Bank",
    Status = scope:Computed(function(use)
      return (app.summary(use(books), use(vault)))
    end),
    Children = children,
  })
end

return app
