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

The stationary base must be running ICOS, but no dashboard app needs to be open. An
ender modem is strongly recommended: ordinary wireless range and chunk loading still
apply. Mine Control actions on the handheld execute at the base, so mine plans, sector
leases, and coordinated quarry assignments remain authoritative rather than becoming
a second local copy.

## Normal deployment workflow

From the repository root:

```powershell
.\tools\make-manifest.ps1
.\tools\check.ps1
git diff --check
```

Review the diff, then commit and push only when intended. `tools\deploy.ps1` combines
manifest generation, checks, commit, and push, so do not run it merely to verify work.

Installed machines check for updates on boot when `.node.autoUpdate` is enabled. You
can also use Update on the base or update/update-all in Devices.

## Starting a coordinated quarry

1. Park every participating turtle over its chest.
2. Run the Where system tool on each turtle and enter its world position and heading.
3. Confirm every turtle appears connected and parked in Devices.
4. Use Mine Control on the base/handheld, or run this on the physical base console:

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
hidden when hardware is absent. Type `setup` on the physical console to correct role.

### Turtle is parked

Open Devices and read `parkKind`, detail, fuel required, and tank/reserve breakdown.
Common reasons are recall, return reserve, depot full, blocked/protected block, or a
completed finite job. Fix the cause before deploy.

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
