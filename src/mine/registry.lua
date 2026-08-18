--- Moved to `domain/mine/registry.lua`.
---
--- See `src/mine/plan.lua` for why the alias is here. Note that the registry is
--- not yet free of `core/config` and `os.epoch`; the header of the moved file
--- says what still has to happen and why it did not happen in the same change.
---
--- New code requires `domain.mine.registry`. Delete this once the specs do.

return require("domain.mine.registry")
