--- The simulated world, which now lives in `src/adapters/sim/world.lua`.
---
--- It moved because it stopped being test scaffolding. A world that implements
--- CC's APIs over an in-memory block grid is an adapter in exactly the sense
--- docs/icos-2.md means: the same shape as `adapters/cc`, selected by the
--- composition root, and the only difference is which side of the port it sits
--- on. Leaving it under `tools/` made it look like a fixture that domain code
--- must not be built against, which is the opposite of the plan.
---
--- This file stays so every existing spec keeps requiring `support.world` and
--- passing unchanged. That the suite did pass unchanged is the proof the move
--- was mechanical; once the specs are rewritten against ports directly, delete
--- it.

return require("adapters.sim.world")
