# ComputerCraft — Valhelsia 6

A monitored turtle fleet for CC: Tweaked 1.113.1 (Minecraft 1.20.1, Forge), with
Advanced Peripherals 0.7.41r available.

**Source of truth is this folder.** In-game machines are deployment targets, never
where you edit. Everything here survives world resets, server wipes, and losing a
turtle to a creeper.

## Layout

```
src/
  startup.lua        boot: read this machine's role, hand over to its app
  install.lua        give a machine a role (the "deploy a turtle" step)
  update.lua         pull latest code from GitHub
  manifest.json      generated — the file list update.lua downloads

  core/              no dependencies on turtles, jobs, or each other
    config.lua       table persistence with defaults
    log.lua          capped file log + in-memory ring buffer
    net.lua          rednet: one protocol, one envelope, modem discovery
    ui.lua           drawing, works on a computer term or a monitor
    util.lua         formatting helpers

  turtle/            turtle hardware, no job knowledge
    nav.lua          position tracking + safe movement
    fuel.lua         fuel level, limit, refuelling
    inv.lua          inventory queries and dumping

  jobs/              what a turtle does, no I/O of its own
    quarry.lua       rectangular pit, resumable

  apps/              entry points — the only files that wire things together
    miner.lua        turtle agent: run a job, report to base
    fleet.lua        base station: roster + monitor dashboard
    scan.lua         Geo Scanner ore listing

bootstrap.lua        one-shot installer for a fresh machine
tools/               PowerShell helpers, run from the repo root
types/               CC: Tweaked definitions (gitignored — see setup.ps1)
```

The dependency rule is one-directional: `apps` → `jobs` → `turtle` → `core`. Nothing
in `core` knows a turtle exists, and nothing in `jobs` touches the screen or the
network — jobs take a `report(phase, detail)` callback and the app decides what that
means. That is what lets the same quarry code drive a local screen and a remote
dashboard without knowing about either.

Every entry point starts with `package.path = "/?.lua;/?/init.lua;" .. package.path`
so `require("core.ui")` resolves from the filesystem root. Without it CC resolves
requires relative to the running program's own directory, and anything in `apps/`
would look for `apps/core/ui.lua`.

## Hardware you actually need

| | |
| --- | --- |
| Base station | Advanced computer + **modem** + advanced monitor |
| Each turtle | Advanced mining turtle + **modem** |

**The modems are not optional for tracking.** Turtles mine perfectly well without one;
you just get no telemetry.

Two wireless modems — one on the base, one on a turtle — are enough for a working
fleet. Range is 64 blocks, measured base-to-turtle, rising linearly above y=96 to 384
at world height. What that means in practice:

- **Put the base computer at the quarry site**, not back at your main base. Distance is
  measured from it, so 200 blocks away means offline the whole time.
- **Depth is what eats the budget.** A quarry from y=64 down to bedrock is ~120 blocks
  of separation — well past 64. Depth 32 (the default) stays in range the whole way.
- **Going out of range is not a failure.** The turtle keeps mining and the dashboard
  shows it stale. And since every layer ends with a trip home, a deep turtle pops back
  into range and re-syncs at each layer boundary.

**Ender modems** (8 stone + eye of ender) remove all of this — unlimited range, works
across dimensions, and none of the placement rules above apply. No code changes are
needed: `core/net.lua` picks any modem reporting `isWireless()`, which ender modems do.

### Fitting an ender modem

**Base computer:** break the old wireless modem off and place the ender modem against
any face. Don't leave both attached — `net.lua` opens the first wireless modem it
finds and there's no API to tell an ender modem from a plain one.

**Turtle:** put the ender modem in any inventory slot and run `equip` (or "Swap modem"
in the boot menu). Do *not* run `turtle.equipLeft/Right` by hand — a turtle has two
upgrade slots, both are already full, and equipping on the wrong side swaps out the
**pickaxe**, leaving a turtle that can't mine. `apps/equip.lua` finds the side that
currently holds a modem and replaces only that one.

> Both upgrade slots stay full: pickaxe on one side, modem on the other. A Geo Scanner
> upgrade won't fit on the same turtle — use the Geo Scanner *block* on the base
> computer, or a separate scout turtle.

## Editor setup

One extension does the real work: **`sumneko.lua`**. With `types/cc-tweaked/library`
it gives autocomplete, hover docs and type checking for every CC API.

```powershell
code --install-extension sumneko.lua
.\tools\setup.ps1          # clones the type definitions into types\
```

`.luarc.json` wires it up and is checked in. It disables `param-type-mismatch` and
`undefined-field` — not laziness: the definition set declares its string enums
(`fs.openMode`, `os.locale`) with a legacy annotation syntax LuaLS 3.19 reads as
*including the quote characters*, so every correct `fs.open(path, "w")` gets flagged.
With them off `tools\check.ps1` is clean; with them on you get ~129 false positives.

Also configured: `johnnymorganz.stylua` (formatting, `.stylua.toml`) and
`kampfkarren.selene-vscode` (linting, `selene.toml` + `cc-tweaked.yaml`).

**Skip `jackmacwindows.vscode-computercraft`.** It registers a second completion
provider on `.lua`, so it competes with sumneko rather than adding to it, and its API
data targets CC: Tweaked 1.100.0 — older than this pack.

## Deploying

### Adding a machine

1. Place it. Pull the code:
   - **Public repo:** `wget run https://raw.githubusercontent.com/USER/REPO/main/bootstrap.lua`
   - **Private repo:** run `.\tools\print-bootstrap.ps1 -User me -Repo ComputerCraft -Token github_pat_xxx`,
     then in game type `lua` and press Ctrl+V.
2. Run `install`, pick a role.
3. Reboot.

That's it. A turtle finds the base station over rednet **by name**, announces itself,
and the base adds it to the roster — there is nothing to configure on the base side,
and no IDs to write down anywhere. Adding the tenth turtle is the same three steps as
the first.

### Pushing changes

```powershell
.\tools\deploy.ps1 -Message "smarter fuel margin"
```

Regenerates the manifest, runs all checks, commits, pushes. Then run `update` on any
in-game machine and reboot.

### Private repos

`raw.githubusercontent.com` ignores auth headers, so `update.lua` switches to the
GitHub contents API (`Accept: application/vnd.github.raw`, which returns the plain file
rather than base64 — CC has no base64 decoder) whenever a token is configured.

> **Token hygiene.** The token is stored in plain text in `.update` on the machine.
> Anyone who can reach it in game, the server admin, and anyone with the world files
> can read it. Use a **fine-grained** PAT scoped to that **one repository**,
> `Contents: Read-only`, with an expiry. If that's not acceptable, keep the repo public
> — it's Minecraft Lua — and keep real secrets out of it entirely.

## Roles

| Role | App | What it does |
| --- | --- | --- |
| `fleet` | `apps/fleet.lua` | Hosts the rednet protocol, keeps the roster, paints the monitor |
| `miner` | `apps/miner.lua` | Runs the quarry job and heartbeats status every 2s |
| `utility` | — | No autorun; boots to the menu |

`startup.lua` waits three seconds before launching the role app. That pause is the
escape hatch — a turtle with a broken job is never an unrecoverable brick.

## The dashboard

`fleet` shows one row per turtle: name, phase, position, fuel bar, layer progress, and
time since last heartbeat. Rows go yellow after 10s of silence and red after 60s. The
footer aggregates blocks mined, items delivered, and total moves across the fleet.

The roster is persisted, so after a server restart the dashboard still lists every
known turtle as offline until it checks back in — a turtle that has gone quiet is
exactly the one you want to see. Press `R` on the base to clear the roster.

If a GPS cluster is in range, turtles report **world** coordinates instead of
job-relative ones, so you can actually go and find the thing. Without GPS it falls
back to coordinates relative to that turtle's own start point.

## The quarry

1. Turtle at the near-left corner of the area.
2. **Chest directly behind it.**
3. Coal or charcoal in any slot.

The pit extends forward and to the right. Each pass clears two layers, so depth 32 is
16 passes. One stack of coal (~5,120 fuel) comfortably covers an 8×8×32. Start with
4×4×16 to watch it behave.

### How it avoids losing a turtle

- **Position is written to disk after every *confirmed* move** — only once the game
  says the move happened, so the count cannot drift.
- **It never takes a step it cannot walk back from.** Before each move it checks that
  fuel still covers the distance home plus a 64-block margin, and burns mined coal one
  lump at a time to top up.
- **Every layer starts from home.** After an interruption it walks back to the chest
  and re-runs the current layer, mostly gliding through air it already mined. Far
  easier to get right than partial-layer bookkeeping.
- **Gravel and mobs are retried, bedrock is not.** A blocked move digs; if nothing
  solid is there, something alive is, so it attacks. 100 failed attempts ends the job
  cleanly instead of grinding forever.
- **Lava is left sealed** rather than dug into and flooding the pit.
- **A full inventory triggers a round trip** home and back to the exact block it left.

Ctrl+T is safe at any time.

## Tools

| | |
| --- | --- |
| `tools\setup.ps1` | One-time: clone the type definitions |
| `tools\check.ps1` | LuaLS + selene + stylua over the repo |
| `tools\deploy.ps1` | Manifest, checks, commit, push |
| `tools\make-manifest.ps1` | Regenerate `src/manifest.json` |
| `tools\print-bootstrap.ps1` | Private-repo installer one-liner to clipboard |
| `tools\link-world.ps1` | Junction a *singleplayer* world's computer to `src\` for fast iteration |
| `tools\unlink-world.ps1` | Undo that before zipping a world |

`check.ps1` deliberately looks for selene and stylua in VS Code's `globalStorage`
before falling back to `PATH` — there are rokit shims of the same name on PATH that
refuse to run without a `rokit.toml`.

## Upgrade path

| Upgrade | Why |
| --- | --- |
| **Ender modems** | Prerequisite for any tracking at depth. Do this first. |
| **Chunky Turtle** (AP) | Keeps its own chunk loaded, so turtles mine while you're away. The real "mine for me" unlock. |
| **Geo Scanner** (AP) | `scan` turns blind quarrying into targeted digging. |
| **GPS cluster** | 4 computers + 4 modems high up. World coordinates on the dashboard. |
| **Inventory Manager** (AP) | Push items straight into your own inventory. |

## In-game commands

| | |
| --- | --- |
| `Ctrl+T` (hold) | terminate the running program |
| `Ctrl+R` (hold) | reboot |
| `edit <file>` | built-in editor — useful for `.node`, `.quarry`, `.update` |
| `lua` | interactive REPL |
| `help <topic>` | built-in docs |

Full API reference: <https://tweaked.cc/> · Advanced Peripherals: <https://docs.advanced-peripherals.de/>
