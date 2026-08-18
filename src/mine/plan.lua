--- Moved to `domain/mine/plan.lua`.
---
--- Sector geometry was always pure arithmetic over a table, which is why it was
--- the first thing to go into `domain/` - it needed no changes at all to get
--- there. This alias exists so the spec suite could be run before and after the
--- move without editing a single test, which is the only proof available that a
--- live fleet's shaft coordinates still come out identical.
---
--- New code requires `domain.mine.plan`. Delete this once the specs do.

return require("domain.mine.plan")
