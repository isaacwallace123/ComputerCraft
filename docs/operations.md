# Operations

## Fresh installation

On a new CC: Tweaked computer or turtle:

```text
wget run https://raw.githubusercontent.com/isaacwallace123/ComputerCraft/master/bootstrap.lua
```

Leave the token blank for the public repository. The configured default branch is
`master`, not `main`. After download, choose a role and label; setup reboots the
machine automatically.

For a private repository, use `tools\print-bootstrap.ps1` on the development computer
and paste its generated Lua command into the in-game `lua` prompt. Do not publish the
token-bearing command.

## Minimum hardware

- Base: advanced computer, modem, and preferably an advanced monitor.
- Handheld: advanced Pocket Computer with a wireless or ender modem upgrade.
- Miner: advanced mining turtle with pickaxe and modem.
- Recommended for unattended mining: ender modems and chunk loading.
- Optional: speaker, secondary haul monitor, GPS cluster, compatible Geo Scanner.

The modem is mandatory for control and telemetry but not for the mining loop itself.
A standard mining turtle cannot simultaneously hold pickaxe, modem, and Geo Scanner
because it has only two upgrade slots.

## Base screens

The base computer's own terminal runs the complete ICOS desktop and is the place for
Devices, Auto Recovery, Mine Control, Update, Setup, Terminal, Power, and Fleet
Console. An attached monitor is a separate display-only desktop: it opens Fleet Status
automatically and can switch to a read-only Fleet Log. Monitor touches may page data,
but cannot send fleet commands or change configuration.

This split is automatic. App definitions declare whether they require operational
input, and ICOS removes those apps from surfaces without a keyboard.

## Handheld controller

Install ICOS on an Advanced Pocket Computer and choose **Fleet handheld**. Existing
Pocket installations that used the old Fleet role migrate automatically. The handheld
boots into a touch-first shell with a permanent Home/System row and includes Fleet,
Devices, Auto Recovery, Mine Control, Fleet Log, Update, Terminal, Setup, Power, and
Ore Scan when a compatible scanner is attached.

Fleet handheld is offered even when the Pocket has no modem so setup never collapses
to a confusing Utility-only choice. The shell works offline, but live telemetry and
commands require a wireless or ender modem upgrade; attach one and reboot ICOS.
Capability detection uses the modem type trait rather than only a peripheral's primary
type, so combined devices such as an Advanced Ender Pocket Computer are recognised.

**Auto Recovery** controls conservative responses to routine pauses. It can resume a
turtle once fuel is sufficient, retry an unload after depot space is freed, recheck
missing setup prerequisites, and optionally update parked turtles one at a time. It
does not choose or assign new work. The two network entries only control status polling
and Pocket synchronization frequency.

**Mine Control** configures the shared prospecting grid used to prevent scattered,
one-use shafts. It chooses the grid centre, sector size, outer extent, and protected
radius around the base. Its separate quarry action replaces the jobs of currently
connected, parked miners with one bounded coordinated quarry after confirmation.

### Starting diamond mining

Open **Mine Control → Start diamond mining**. On the first run, choose **Locate base
with GPS** or **Enter base coordinates**. ICOS then performs the formerly separate
steps as one operation: it creates the standard shared grid, protects the base with a
64-block requested keepout, assigns Rare prospecting at Y -59 to all connected parked
miners, and queues them to start. If a mine already exists, the shortcut preserves its
geometry and only assigns the parked fleet.

Each turtle still needs its one-time world heading. Run **System tools → Set position**
on a turtle after placing it, or after physically moving or turning it. With GPS, ICOS
fills the coordinates automatically and only asks which way the turtle faces.

**A turtle without a world position will not deploy.** The shared mine is defined in
world coordinates, so every prospecting job refuses to launch without one. This is the
usual reason a fleet-wide order starts some turtles and not others — newly added miners
have never been given theirs. Start diamond mining now names them in its result, and
Devices shows `run where on this turtle` as the park reason. Run Set position on each and
deploy again.

### Building a GPS constellation

GPS is optional, but it removes coordinate typing. Build it in one permanently loaded
chunk using four hosts and four Ender modems (ordinary wireless modems work only at
limited range). Keep the hosts in the same dimension as the fleet. Arrange them in
three dimensions: three must not be in a straight line, and the fourth must be above
or below their plane. A roughly 5×5×5 or 10×10×10 arrangement works well.

Install ICOS on each host and choose **GPS host** in Setup. Use F3 **Targeted Block**
to enter that computer or turtle block's exact X/Y/Z when prompted—not the modem's
position. The role saves those coordinates in `.gps` and boots directly into the GPS
beacon; it does not run the fleet desktop or register as a base.

Setup always offers **GPS host** on turtles so a dedicated Chunky Turtle can be given
its role before its upgrades are arranged. It still needs an equipped wireless or
Ender modem to serve requests; Setup shows a warning when one is not detected.

One host may be a stationary Chunky Turtle with an Ender modem in its other upgrade
slot. Selecting **GPS host** makes it both a coordinate beacon and, when Advanced
Peripherals chunk loading is enabled, the loader for the shared host chunk. The other
three hosts can be ordinary computers. Keep all four powered. Test from the ICOS base
Terminal with `gps locate`; it should print three coordinates.

GPS host setup displays X, Y, and Z on a separate confirmation screen before saving.
If a host configured by ICOS v1.2.5 lost a negative Y or Z sign, update it and run
**Setup / change role → GPS host** again on that device. Re-enter its F3 Targeted Block
coordinates and verify every sign on the confirmation screen. All four hosts must
advertise their real coordinates before `gps locate` can be trusted.

The stationary base must be running ICOS, but no dashboard app needs to be open. An
ender modem is strongly recommended: ordinary wireless range and chunk loading still
apply. Mine Control actions on the handheld execute at the base, so mine plans, sector
leases, and coordinated quarry assignments remain authoritative rather than becoming
a second local copy.

## Running ICOS 2 in a test world

`startup.lua` still boots ICOS 1, and will until the switch is tested in a world. To run an
ICOS 2 machine by hand:

    icos2 status      build the machine, print which services start, stop
    icos2             boot the role in .node and run it until Ctrl-T
    icos2 server      force a role, for a machine that has not been set up

The roles are `server`, `client`, `turtle` and `mobile` - form factors, not jobs. A mining
turtle and a farming turtle are both `turtle`; what they do is the job in `.node`.

Nothing is written that ICOS 1 reads, so a reboot puts the machine back exactly as it was.
`.mine` is shared with ICOS 1 deliberately - the shape is identical, so leases and surveyed
shaft heads survive in both directions. `.fleet2`, `.desired` and `.policy2` are new names
precisely so that a rollback never reads them.

Start with `status`. The failures worth finding first are all in the wiring - no wireless
modem, no saved position, a role with no operating system - and they are discovered when
the ports are built and the services registered, which is what `status` does and what
reading a config file would not.

## Testing in a local world

The fastest loop by a wide margin: point a singleplayer computer's filesystem straight at
`src\` and skip publishing entirely. Save in the editor, reboot the computer in game, and
it is running the new code. No commit, no push, no `update`.

```powershell
.\tools\link-world.ps1 -List
.\tools\link-world.ps1 -World "CC Testing" -Id 0
```

That replaces `<instance>\saves\<world>\computercraft\computer\0\` with a directory
junction to `src\`. Junctions need no administrator rights. Place a computer in the world
first — the first one placed gets ID 0 — and re-run with `-Id n` for a second machine, or
after making a new world.

`-Instance` defaults to the Valhelsia 6 CurseForge path; pass it explicitly for any other
launcher or pack.

Undo it before zipping or sharing the world, because a junction is not portable and the
receiving machine sees an empty computer:

```powershell
.\tools\unlink-world.ps1 -World "CC Testing" -CopyBack
```

**This is for a singleplayer world on your own machine only.** On a server the computer's
files live on the host, so use the normal route: `make-manifest`, push, then `update` in
game.

### What a linked computer writes into your working tree

The junction goes both ways. Everything the OS persists — `.node`, `.nav`, `.mine`,
`.log`, a job file, and a `.tmp` beside each during a save — is written into `src\` and
shows up in `git status`. They are all listed in `.gitignore`, so this is safe; but if a
new dotfile appears in a diff, that is why, and it belongs in `.gitignore` rather than in
a commit. A turtle that gets as far as mining writes six of them within a minute.

`.settings` is CC's own, written when you use the `set` program.

### Seeing the ICOS 2 UI framework

The framework is built but deliberately not wired into the desktop — the running fleet
still uses `legacy/shell/ui.lua`, and putting a framework screen on the desktop is a change that
touches live machines. To look at it, run it by hand on a linked computer:

```text
apps/showcase
```

It mounts the rebuilt Fleet and Devices pages plus a motion page against a fake roster,
using the real `adapters/cc` screen and input ports, and **reports the frame cost along the
bottom**: frames, mean blit count, and milliseconds per frame. Keys are `1`–`3` to switch
page, `tab` to move focus, `enter`/`space` to press, and `q` to quit.

Those numbers are the point. Every figure in `docs/ui-framework.md` section 12 was measured
on desktop Lua with a conservative 10× margin assumed for Cobalt, and that section says to
re-measure on hardware before trusting the margin. This is how. It is also the gate on two
pieces of work: wiring the framework into the desktop, and building the Blackjack showcase,
which is a full-screen animated canvas — the one workload D037 says does not fit a
contended scheduling slice.

An advanced (gold) computer shows the palette properly. A standard one is worth a look too,
since it renders the same theme flattened to greyscale, which is the case
`docs/ui-design.md` designs the semantic colours around.

## Normal deployment workflow

From the repository root:

```powershell
.\tools\make-manifest.ps1
.\tools\check.ps1
git diff --check
```

Run `.\tools\spec.ps1` as well after touching turtle behaviour: it executes the mining
logic against a simulated world, including cutting power at every step of a cycle and
checking the ground afterwards.

Review the diff, then commit and push only when intended. `tools\deploy.ps1` combines
manifest generation, checks, commit, and push, so do not run it merely to verify work.

Installed machines check for updates on boot when `.node.autoUpdate` is enabled. You
can also use Update on the base or update/update-all in Devices.

## Starting a coordinated quarry

1. Park every participating turtle over its chest.
2. Run the Where system tool on each turtle and enter its world position and heading.
3. Confirm every turtle appears connected and parked in Devices.
4. Use Mine Control on the base/handheld, or run this in Fleet Console on the base
   desktop:

   ```text
   quarry <x1> <z1> <x2> <z2> <topY> <bottomY>
   ```

5. Watch command results and the first few movements before leaving the fleet.

Start with a small safe box. The area must not include the turtles' home chests,
computers, or infrastructure you expect the quarry to remove; protected blocks stop
the affected worker.

## Recovery

### Apps are missing

Check the base role and modem first. Home deliberately shows Fleet and Devices for a
fleet-role computer even without a modem, but other capability-filtered apps can be
hidden when hardware is absent. Open Setup on the physical desktop to correct role.

### Turtle is parked

Open Devices and read `parkKind`, detail, fuel required, and tank/reserve breakdown.
Common reasons are recall, return reserve, depot full, blocked/protected block, or a
completed finite job. Fix the cause before deploy.

### A sector shaft was left open

Prospecting keeps every sector shaft capped except while a turtle is inside it, and the
base records which sectors have an open head. Mine Control reports that count; it is the
one figure on the screen that is about safety rather than throughput.

A sector recorded as open is leased out ahead of all other ground, so the next turtle to
ask for work goes and caps it. Most openings repair themselves this way without anyone
doing anything.

A turtle that could not close a head parks with an error naming the sector and the
shaft's X/Z:

- **no cap block** — the turtle had no safe filler and no wall it could mine for one.
  Put a stack of cobblestone in its inventory and deploy again.
- **no sealable shaft head for sector N** — every column along that sector's trunk is
  under water or lava, or blocked. The turtle already tried sliding the head along the
  trunk. Clear the liquid, or move the mine centre or keep-out so that sector is not
  used.
- **could not find the shaft head** — an older open shaft whose surface could not be
  identified within 16 blocks of the plan's surface Y. Cap it by hand at the reported
  coordinates.

A single wet block at the sector's centre is no longer a problem: the descent probes
outward along the trunk for a column it can seal and remembers where it settled.

### Nothing is being mined

A turtle that mines nothing and advances no frontier for two cycles hands its sector back
to the base and is given different ground. After four such cycles it parks with
`no progress in 4 cycles` and the last stop reason.

This is the expected response to ground that cannot be worked — a lava lake across the
trunk, a sector under an ocean. Read the reason, then either clear the obstruction or
move the mine. It is not a fault in the turtle; it is the fleet declining to commute all
night for nothing.

### Shafts opened before ICOS v1.2.7

Builds up to v1.2.7 left every sector shaft permanently open. Those holes are not
repaired by an update on their own — a turtle only seals a shaft it visits.

1. **Recall the whole fleet first.** Never update or redeploy while turtles are
   underground; an active job must not be reinterpreted mid-route.
2. Update the parked turtles and deploy them again.
3. On the next visit to each already-open sector, the descent recognises the open
   column by its walls and caps it flush with the ground. That closes each existing
   hole the first time its sector is worked again.

That repair only happens for sectors the fleet actually revisits, and only when the
descent can identify the head. Do not rely on it for a hole you can already see: recall
the fleet and fill or cover those openings by hand. The four shafts opened by the
v1.2.6 fleet near X 138, Z -1032/-1080/-1128/-1176 are in that category — cover them
yourself and treat any automatic sealing as a bonus.

### Turtle is offline

Offline means no recent heartbeat, not necessarily failed mining. Check wireless
range, modem attachment, chunk loading, and whether the server is ticking the chunk.
An ender modem solves range but not unloaded chunks.

### Update fails

Inspect `.update-result`, confirm HTTP is enabled, verify `.update`, and confirm the
manifest was regenerated and pushed. A private source also needs a valid read token.

### Recover the shell

Hold a key during the ICOS splash to enter system tools. From CraftOS, `startup`
launches ICOS, `update.lua` runs the updater, and `install.lua` changes role.

## Release/version workflow

`src/core/version.lua` is the installed version. The merge workflow uses labels:

- `version:major` for breaking compatibility
- `version:minor` for backward-compatible features
- no version label for fixes, documentation, or internal changes

The current mining/fleet feature set is a minor release. Do not manually bump the
version in an ordinary feature branch unless intentionally preparing a release PR.
