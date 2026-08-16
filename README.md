# 🐢 ICOS — Isaac's Cool Operating System

Welcome to ICOS: a friendly little operating system and turtle fleet controller for
CC: Tweaked 1.113.1 in Valhelsia 6 (Minecraft 1.20.1, Forge). It gives computers a
touch-friendly desktop, gives turtles a focused control panel, and lets the two work
together without hardcoded computer IDs. ✨

## 🌟 What ICOS can do

- 🖥️ Turn an attached monitor into an auto-scaling desktop with launchable apps.
- 📡 Discover turtles automatically and keep them as persistent paired devices.
- 🎮 Browse, deploy, recall, and configure individual turtles from the Devices app.
- ⌨️ Use the physical PC as a live fleet log and command console while the monitor
  stays touch-friendly.
- ⛏️ Run five focused mining jobs with automatic fuel and return-home safeguards.
- 🔄 Check for over-the-air updates automatically whenever ICOS boots.
- 📦 Update one turtle—or every connected turtle—from the Devices app.
- 🔊 Play short nostalgic boot, shutdown, success, and alert jingles when a speaker
  is attached.
- 🐢 Adapt the interface to the hardware: computers get the desktop, while turtles
  get only the controls and apps they can actually use.

> New here? Start with one base computer and one mining turtle. Get a short
> rare-ore run working end to end, then add the rest of the fleet—the tenth turtle
> pairs exactly like the first one.

**Source of truth is this folder.** In-game machines are deployment targets, never
where you edit. Everything here survives world resets, server wipes, and losing a
turtle to a creeper.

## 🚀 Quick install

On a fresh CC: Tweaked computer or turtle, paste this into CraftOS:

```text
wget run https://raw.githubusercontent.com/isaacwallace123/ComputerCraft/master/bootstrap.lua
```

Press Enter when asked for an access token because this repository is public. The
bootstrapper downloads the updater, pins the current commit, and installs everything
in `src/manifest.json`. Run `install` afterward to choose the machine's role.

## 📚 Documentation

The README is the friendly overview. Detailed technical and handoff documentation
lives in [`docs/`](docs/README.md):

- [Architecture](docs/architecture.md) — boot, desktop, fleet, miner, and updater flows.
- [Mining system](docs/mining.md) — algorithms, job contract, fuel safety, and adding jobs.
- [Network protocol](docs/network-protocol.md) — Rednet envelopes, commands, and telemetry.
- [Persistent state](docs/persistence.md) — every dotfile, owner, and migration rule.
- [Operations](docs/operations.md) — installation, deployment, recovery, and releases.
- [Decision log](docs/decisions.md) — why important choices were made.
- [AI handoff](docs/ai-handoff.md) — the fastest safe way for another agent to continue.

## 🗺️ Project layout

```
src/
  startup.lua        ICOS boot: update, detect hardware, launch the right shell
  install.lua        give a machine a role (the "deploy a turtle" step)
  update.lua         pull latest code from GitHub
  manifest.json      generated — the file list update.lua downloads

  core/              shared operating-system and service modules
    apps.lua         capability-aware application registry
    boot.lua         responsive boot/restart animations
    config.lua       table persistence with defaults
    console.lua      physical-PC fleet log, prompt, and remote commands
    desktop.lua      monitor desktop, windows, icons, and taskbar
    handheld.lua     touch-first Pocket Computer shell and app switching
    device.lua       computer/turtle/peripheral capability detection
    display.lua      primary/secondary monitor selection and automatic scaling
    log.lua          capped file log + in-memory ring buffer
    net.lua          rednet: one protocol, one envelope, modem discovery
    sound.lua        optional speaker boot, shutdown, and alert sounds
    ui.lua           drawing, works on a computer term or a monitor
    util.lua         formatting helpers
    version.lua      installed semantic version, reported by every device

  turtle/            turtle hardware, no job knowledge
    nav.lua          position tracking + safe movement
    fuel.lua         tank + carried-fuel accounting and lazy refuelling
    inv.lua          inventory queries, dumping, junk disposal
    ore.lua          what is worth mining + vein following
    geo.lua          optional Advanced Peripherals Geo Scanner adapter

  jobs/              what a turtle does, no I/O of its own
    quarry.lua       coordinated absolute-world excavation
    rare.lua         rare and modded-ore prospecting profile
    fuel_hunt.lua    coal-only prospecting profile
    resources.lua    iron/copper/zinc/andesite profile
    hollow.lua       three-block-high floor excavation at a chosen Y
    common/          shared return and fuel safety policy
    prospecting/     reusable branch-grid runner and ore profiles

  miner/             turtle lifecycle, telemetry, and remote commands
  fleet/             always-on service, controller sync, policy, roster, assignments

  apps/              entry points — the only files that wire things together
    miner.lua        turtle agent: run jobs, report, obey fleet orders
    fleet.lua        scalable overview and fleet-wide commands
    devices.lua      paired-device browser, detail pages, remote configuration
    automation.lua   unattended fleet policy
    operations.lua   shared-mine and coordinated-quarry control
    logs.lua         local/handheld fleet log viewer
    power.lua        animated restart and shutdown
    swarm.lua        deploy a line of turtles, then reclaim them
    scan.lua         Geo Scanner ore listing
    equip.lua        guarded modem swap

bootstrap.lua        one-shot installer for a fresh machine
AGENTS.md             short rules and routing for coding agents
docs/                 engineering, operations, decisions, and handoff memory
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

## 🧱 Hardware you actually need

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

### 📶 Fitting an ender modem

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

## 🛠️ Editor setup

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

## 🚀 Installing and deploying

### ➕ Adding a machine

1. Place it. Pull the code:
   - **Public repo:** `wget run https://raw.githubusercontent.com/isaacwallace123/ComputerCraft/master/bootstrap.lua`
   - **Private repo:** run `.\tools\print-bootstrap.ps1 -User me -Repo ComputerCraft -Token github_pat_xxx`,
     then in game type `lua` and press Ctrl+V.
2. Run `install`, pick a role.
3. Reboot. ICOS detects the hardware, asks for a valid use case, and enables
   automatic updates by default.

That's it! 🎉 A turtle finds the base station over Rednet **by name**, announces
itself, and appears in Fleet as a paired device. There are no IDs to copy and nothing
to add manually on the base. Adding the tenth turtle is the same three steps as the
first.

### 📤 Pushing changes

```powershell
.\tools\deploy.ps1 -Message "smarter fuel margin"
```

Regenerates the manifest, runs all checks, commits, and pushes. ICOS checks for that
update automatically on the next boot. A computer can also open the **Update** app;
on a turtle, hold a key during the boot animation and choose **Update now**.

### 📡 Fleet-wide over-the-air updates

The **Devices** list shows the ICOS version reported by every turtle. The current
version is green, a different version is yellow, and `unknown` means the turtle is
running an older build which predates version telemetry.

- Touch **update all** on the Devices list to update every connected turtle.
- Open one device and touch **update** to update only that turtle.
- A parked turtle starts immediately. A working turtle acknowledges the request,
  returns home through the normal safe recall path, then updates and reboots.

The command uses each turtle's existing `.update` configuration and the same
SHA-pinned, checksum-verified updater used at boot. The turtle must have HTTP enabled,
an update source configured, and currently be reachable over Rednet. An offline turtle
cannot receive the broadcast, but its normal boot-time auto-update catches it the next
time it starts.

> **One-time rollout note:** turtles showing `unknown` are too old to understand the
> new remote-update command. Reboot or update those once using their existing boot-time
> updater; after they report v1.1.0 or newer, all future updates can be sent from
> Devices.

### 🏷️ ICOS versions

ICOS uses the semantic version in `src/core/version.lua` as its single source of truth.
Every pull request merged into the default `master` branch changes that release version:

- `version:major` → incompatible or breaking change (`2.0.0`)
- `version:minor` → backward-compatible feature (`1.2.0`)
- no version label → backward-compatible fix/docs/internal change (`1.1.1`)

The `.github/workflows/icos-version.yml` workflow serializes merge events and commits
the appropriate bump directly after each merge. A deliberately pre-versioned release
PR is accepted as-is, so release PRs are not bumped twice.

### 🧠 Why the updater resolves a commit SHA first

`raw.githubusercontent.com` caches hard and **cannot be cache-busted**. Both of the
usual tricks were measured still serving a file from before the push:

| Approach | Result |
| --- | --- |
| `?t=<timestamp>` query string | stale |
| `Cache-Control: no-cache` header | stale |
| **commit SHA in the URL path** | **correct** |

So `update.lua` spends one API call on `/repos/USER/REPO/branches/BRANCH` to resolve
the branch to the commit it currently points at, then fetches every file from
SHA-pinned paths. Those URLs are immutable, so they are never stale — and every push
produces a new SHA, which is a new URL. If the lookup fails it falls back to the branch
name and says so.

### 🧾 Why `manifest.json` must not have a BOM

`tools\make-manifest.ps1` writes it with `[System.IO.File]::WriteAllText` and an
explicit no-BOM encoder, **not** `Set-Content -Encoding utf8` — Windows PowerShell 5.1
always adds a BOM there, and a leading `EF BB BF` makes CC's `textutils.unserialiseJSON`
reject the file. That surfaces as "manifest.json is malformed" on every machine at
once, which looks like a bad push rather than an encoding problem. `update.lua` also
strips a BOM defensively.

### 🔐 Private repositories

`raw.githubusercontent.com` ignores auth headers, so `update.lua` switches to the
GitHub contents API (`Accept: application/vnd.github.raw`, which returns the plain file
rather than base64 — CC has no base64 decoder) whenever a token is configured.

> **Token hygiene.** The token is stored in plain text in `.update` on the machine.
> Anyone who can reach it in game, the server admin, and anyone with the world files
> can read it. Use a **fine-grained** PAT scoped to that **one repository**,
> `Contents: Read-only`, with an expiry. If that's not acceptable, keep the repo public
> — it's Minecraft Lua — and keep real secrets out of it entirely.

## 🎭 Machine roles

| Role | App | What it does |
| --- | --- | --- |
| `fleet` | Fleet desktop app | Hosts rednet, keeps the roster, and renders the dashboard |
| `miner` | Miner turtle app | Runs the selected job and heartbeats status every 2s |
| `utility` | Hardware-dependent | Offers only tools supported by that machine |

On computers, an attached monitor becomes the ICOS desktop. Its text scale is chosen
automatically, and Fleet, Devices, Update, Power, and hardware-specific apps appear
only when they can run. Every maximized page owns one title bar, with a Windows-style
taskbar for switching and closing apps. ICOS Home is the permanent page and cannot be
closed.

ICOS Home shows the installed version, saved role, and detected modem. Fleet and
Devices remain visible on a fleet-role computer even when the modem is missing, so a
hardware problem produces an explicit offline screen instead of silently removing the
apps. If Home reports the wrong role, type `setup` on the physical PC; if it reports
`NO MODEM DETECTED`, check the modem attachment and reopen Fleet. The PC console's
`about` command prints the same diagnosis.

The computer's own screen becomes a keyboard-driven console whenever the desktop is
on a monitor. It shows the same persistent log Fleet writes and accepts commands such
as `status`, `recall all`, `deploy miner-2`, `refresh`, and
`open devices miner-1`. Type `help` there for the complete list. `update`, `setup`,
`reboot`, and `exit` also live there, so no keyboard-only shell is stranded on a
touch monitor.

With two or more attached monitors, ICOS automatically chooses the physically largest
wall for the desktop and gives Fleet the largest remaining wall. The main Fleet page
then uses its full height for miners while the second wall shows the complete haul,
aggregate totals, and touchable previous/next paging. Attach or replace that second
monitor while Fleet is open and it is detected automatically; unplug it and the compact
haul summary falls back onto the primary page.

Turtles never get the desktop. They get a compact, capability-filtered launcher; if
only one normal app is valid (the usual mining-turtle case), it starts automatically.
Hold any key during the short boot animation to skip autorun and open system tools.
This is the recovery path for updating, changing roles, or fixing a broken job.

If a speaker is attached, ICOS plays short boot, shutdown, ready, error, and alert
jingles. Use the **Power** app or **Restart ICOS** for the shutdown animation and
sound; Ctrl+R remains CraftOS's immediate hard reset.

## 📡 The Fleet dashboard

Open the **Fleet** app to see one row per turtle: name, phase, position, fuel,
progress, and time since last heartbeat. Rows go yellow after 10s of silence, red
after 60s, cyan when
parked and waiting for orders.

Each reporting turtle is treated as a paired device. Touch its Fleet row to switch to
the **Devices** app focused on that turtle. The device list includes each turtle's ICOS
version. From its detail page ICOS can update, deploy, or recall only that turtle,
switch its job, forget its pairing, refresh its state, or edit its job settings.
Each job publishes its own settings, with touch controls and scrolling for longer
forms such as the quarry's world-coordinate corners. Commands target that turtle's ID
and acknowledged with a useful success or refusal message.

Below that is the compact **haul summary** — the fleet's combined take, most plentiful
first. It uses two lines regardless of how many item types have been found, with a
`+N more` count instead of consuming the miner list.
This is the number actually worth watching: not how many blocks were dug, but how much
diamond, iron and andesite came back. Turtles report their haul with every heartbeat,
and the base sums it across the whole fleet.

If a second monitor is attached, this summary moves to its own **Fleet Haul** wall.
That wall has room for every item type across paged columns, and the reclaimed rows on
the main monitor are immediately used for more miners.

The footer provides touch controls for scrolling, fleet-wide recall/deploy, and a
status refresh. The visible range in the header makes a fleet of 10–20 miners
easy to navigate; mouse wheels and arrow/Page Up/Page Down also work on local screens.

The roster is persisted, so after a server restart the dashboard still lists every
known turtle as offline until it checks back in — a turtle that has gone quiet is
exactly the one you want to see. Use **forget** on a device page to remove its pairing.

If a GPS cluster is in range, turtles report **world** coordinates instead of
job-relative ones, so you can actually go and find the thing. Without GPS it falls
back to coordinates relative to that turtle's own start point.

## 🎮 Controlling the fleet

From the base station:

| Key | |
| --- | --- |
| `X` | **Recall** — every turtle abandons its job, walks home, and parks |
| `G` | **Deploy** — every parked turtle re-homes where it stands and starts a fresh job |
| `R` | Request fresh status from every turtle |
| `Q` | Quit |

Fleet-wide orders are broadcast. Device-page orders are addressed to one computer ID,
so deploying `miner-1` does not move `miner-2`.

On a parked turtle itself, press `D` to start another run, `C` to configure the
current job, `J` to change jobs, or `Q` to exit. While working, `R` recalls it. These
controls are also clickable on an advanced turtle's screen.

Turtles **park** rather than exit when a job ends, is recalled, or fails. A parked
turtle is still on the dashboard and still listening — which is what makes both of
these one keypress instead of a walk around the base.

**Moving your operation** is the reason recall exists: press `X`, wait for everyone to
come home and park, physically pick up and re-place the turtles and chests wherever
you like, then press `G`. On deploy each turtle calls `nav.setHome()` where it now
stands, so the new spot becomes its reference point — no reconfiguration.

A recall is not treated as a failure. The turtle finishes its walk home, empties its
inventory into the chest, and keeps its haul.

The old 95% parked display was not a stuck turtle: 95–100% represents the return trip.
ICOS now persists why a turtle parked, and repeatable prospecting runs roll straight into a
fresh cycle after unloading. A new deploy can still be refused safely—for example,
when the turtle does not have the minimum safe-trip fuel—but that reason is shown on
both the PC and turtle.
While parked, the fuel display compares **all fuel aboard** with the next job's
estimate, rather than comparing only the tank with the zero-block walk home.

## ⛏️ Mining jobs

Each turtle picks a job on first boot (`.node` remembers it), and you can switch it
later from its Devices page or with `J` on the turtle. There are five modes:

| Job | Default | What it optimizes for |
| --- | --- | --- |
| **Quarry** | configured world box | Every block from `topY` to `bottomY`, divided evenly across all parked turtles |
| **Rare** | Y -59 | Diamond, redstone, emerald, ancient debris, and uncommon modded `_ore` blocks |
| **Fuel** | Y 96 | Coal ore only; coal stays aboard as fuel reserve |
| **Hollow** | Y -30 | A rectangular, three-block-high empty floor |
| **Resources** | Y 16 | Iron, copper, zinc, and andesite |

The three prospecting modes use the same efficient branch grid: one main corridor,
ribs every three blocks, and recursive vein following. That spacing exposes every
block in the volume without blindly excavating all the stone. Turtles take independent
random bearings, so a fleet spreads out instead of duplicating one tunnel.

If a prospecting turtle exposes an Advanced Peripherals Geo Scanner, it first targets
matching blocks within its scan radius, then runs the complete branch grid as a
fallback. A blocked scanner target is skipped safely; lava is never opened just to
reach an ore. Without the peripheral, the exact same jobs continue with normal
inspection.

> A standard mining turtle already uses both upgrade slots for its pickaxe and modem,
> so it cannot also carry the scanner upgrade. Scanner-assisted mining is optional for
> compatible/modded hardware; the branch grid is the normal fleet path.

### ♻️ Autonomous fuel and repeat runs

Rare, Fuel, and Resources turtles keep working after an unload. Each cycle picks a
fresh route, mines, returns to the chest, drops only loot, and launches again.
**Recall** from Fleet, Devices, or the PC console is the stop button: the current cycle
unwinds, the turtle comes home, unloads, and parks. Quarry and Hollow are finite because
restarting the same cleared volume would only waste fuel.

Fuel in inventory is a reserve, not loot. Coal, charcoal, coal blocks, lava buckets,
and other detected fuels stay aboard when the turtle unloads. The dashboard's fuel
number includes the tank plus known carried fuel; a device detail page also shows the
tank/reserve breakdown. Empty buckets left after burning lava are ordinary loot and
are deposited normally.

Before every potentially outward move—including travel, shafts, quarry sweeps, and
ore-vein detours—the turtle checks the exact planned return route plus a job-specific
safety margin. It loads fuel lazily, one item at a time. When another step would spend
the return reserve, it stops mining automatically, walks home, unloads, and parks with
`fuel reserve reached` instead of becoming stranded.

The launch budget includes the real Manhattan route, climb to cruise altitude, descent,
return, and a safety allowance. It does not demand enough fuel for every optional
branch in advance: the live guard can shorten a cycle, and mined coal can extend it.

> **AFK still needs chunk loading.** ICOS can make the turtle autonomous, but it cannot
> make an unloaded Minecraft chunk tick. Use a Chunky Turtle or your server's chunk
> loader, and confirm the server itself keeps running with no players online.

### 💎 Focused prospecting

Rare deliberately excludes coal, iron, copper, zinc, and andesite so its vein budget
is spent on valuable targets. Resources keeps those common building ores instead.
Fuel matches coal ores only and runs high by default, where coal is plentiful. You can
adjust distance, target Y, and tunnel length per turtle from Devices; modpack-specific
rare blocks that contain `_ore` are detected automatically.

Junk is dropped where it is mined. `turtle.inspect` reports block names such as
`deepslate_iron_ore`, while inventory contains drops such as `raw_iron`, so detection
and disposal intentionally use separate rules. Unknown modded drops are kept rather
than accidentally thrown away.

### 🕳️ Three-high hollow floor

Hollow travels to the configured distance and middle Y (default **-30**), then sweeps
a serpentine rectangle. At every cell it clears the block above and below the turtle,
producing a continuous three-block-tall space. Width and length are configurable from
Devices. A protected block, lava, or unbreakable block stops the job and reports the
exact obstruction instead of falsely marking that cell complete.

### 🏗️ Coordinated quarry

Quarry uses an absolute Minecraft rectangle and vertical range. First run the **Where**
app on every worker so it knows its world position and heading. Then type this on the
base computer's physical console:

```text
quarry <x1> <z1> <x2> <z2> <topY> <bottomY>
```

ICOS assigns every connected parked miner a non-overlapping, balanced range of cells.
Each pass clears two vertical blocks, all workers save their exact layer/cell after
every step, and the whole box is covered once with no overlapping work. If the box has
fewer horizontal cells than parked turtles, only the useful number are assigned.

Quarry configuration from the older relative width/length/depth format is intentionally
not reused: after updating, assign a fresh absolute rectangle before deploying. This
prevents an old `.quarry` file from being mistaken for world coordinates.

### 📦 The depot

A double chest is a *single* inventory, so two turtles standing on its two halves
already share it. That is the whole trick — no code knows about a "depot", each turtle
just empties into the chest it is standing on, and they happen to be the same one.

```
 SIDE VIEW                TOP-DOWN

  [T1][T2]                [T1][T2]      turtles
  [ double chest ]        [C ][C ]      one inventory
  [ hopper ]
  [ barrel ]              hopper under either half drains the whole chest
  [ barrel ]
```

Put a hopper under either half and it pulls from the whole chest into bulk storage
below. That matters more than it sounds: the shared depot's one real failure mode is
backing up, and a hopper draining it continuously is what stops that happening.

Scaling past two: a row of chests, one turtle on each, hoppers underneath feeding a
common line. Turtles do not need to be near the computer — ender modems have unlimited
range.

If the depot *is* full when a turtle gets home, the drop silently does nothing, so the
job reports `depot full` and the row goes red rather than parking as though it had
finished. A turtle holding a load it cannot put down is stuck, not done.

All five jobs unload into a chest **directly below the turtle's home block** and retain
anything usable as fuel. A chest that cannot accept the haul is reported as
`depot full`; it is never disguised as a successful park.

### 🛡️ How ICOS avoids losing a turtle

- **Position is written to disk after every *confirmed* move** — only once the game
  says the move happened, so the count cannot drift.
- **It never takes a step it cannot walk back from.** Before each outward move it checks
  tank fuel plus carried coal, fuel blocks, or lava against the walk home and safety
  margin. Fuel is burned only when the next physical move needs it.
- **Progress is checkpointed at cell or tunnel granularity.** A reboot resumes the
  saved layer and cell rather than restarting an entire excavation.
- **Gravel and mobs are retried, bedrock is not.** A blocked move digs; if nothing
  solid is there, something alive is, so it attacks. 100 failed attempts ends the job
  cleanly instead of grinding forever.
- **Lava is left sealed** rather than dug into and flooding the pit.
- **A full inventory triggers a round trip** home and back to the exact block it left.

Ctrl+T is safe at any time.

## 🤖 Swarm — deploying and reclaiming turtles

`apps/swarm.lua` turns one turtle into a deployer. Load it with turtle items and
chests, run `swarm`, pick **Deploy**: it walks out and every `spacing` blocks plants a
chest with a worker turtle standing on top of it. Each worker boots into its own
`startup`, joins the fleet, and appears on the dashboard. Press `G` on the base and
they all start mining.

**Reclaim** walks the same line in reverse: empties each chest, digs up the worker,
digs up the chest, and brings everything home. The chest is emptied *before* it is
broken — break it first and the contents scatter on the ground and despawn.

Placed turtles keep their computer ID and their entire filesystem, so a reclaimed
turtle redeployed later is still configured. That makes the squad portable: build it
once, then pack it up and carry it to the next outpost. 🎒

> **Why chest-underneath, not chest-behind.** A turtle placed by another turtle ends up
> facing a direction we cannot control, so "drop behind me" is a coin flip. "Drop below
> me" always hits the chest it is standing on. Every mining job therefore uses the
> same chest-below convention.

**What this is not:** turtles crafting brand-new turtles out of ore they just mined.
That needs smelting, and turtles cannot smelt. These are pre-built turtles being
carried, planted, and picked back up.

## 🔧 Development tools

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

### 🗂️ Source layout

Entry points in `src/apps/` are intentionally thin. Long-lived behavior is grouped by
domain so new features do not turn one app into a thousand-line state machine:

| Folder | Responsibility |
| --- | --- |
| `src/miner/` | Turtle state/telemetry, Rednet commands, and autonomous lifecycle |
| `src/fleet/` | Shared paired-device roster and fleet-domain helpers |
| `src/jobs/` | Job definitions, with return/fuel rules in `jobs/common/` |
| `src/turtle/` | Hardware primitives: navigation, inventory, ore, and fuel accounting |
| `src/turtle/fuel/` | Fuel-value catalogue and future fuel-policy extensions |
| `src/core/` | Platform-neutral desktop, UI, config, logging, and networking |

The miner entrypoint is now composition only; its previous UI, networking, state, and
job-loop responsibilities live in focused modules. Fleet and Devices share one roster
module instead of maintaining duplicate pairing and timeout rules.

## 🧭 Suggested upgrade path

| Upgrade | Why |
| --- | --- |
| **Ender modems** | Prerequisite for any tracking at depth. Do this first. |
| **Chunky Turtle** (AP) | Keeps its own chunk loaded, so turtles mine while you're away. The real "mine for me" unlock. |
| **Geo Scanner** (AP) | Optional targeted prospecting on hardware that can expose it alongside mining. |
| **GPS cluster** | 4 computers + 4 modems high up. World coordinates on the dashboard. |
| **Inventory Manager** (AP) | Push items straight into your own inventory. |

## ⌨️ Handy in-game commands

| | |
| --- | --- |
| `Ctrl+T` (hold) | terminate the running program |
| `Ctrl+R` (hold) | reboot |
| `edit <file>` | built-in editor — useful for `.node`, `.quarry`, `.update` |
| `lua` | interactive REPL |
| `help <topic>` | built-in docs |

Full API reference: <https://tweaked.cc/> · Advanced Peripherals: <https://docs.advanced-peripherals.de/>
