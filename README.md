# ComputerCraft — Valhelsia 6

Lua for CC: Tweaked 1.113.1 (Minecraft 1.20.1, Forge). Advanced Peripherals 0.7.41r
is also on the pack, so peripheral-based projects are open once you have the items.

**Source of truth is this folder.** The in-game computer is a deployment target,
never the place you edit. Every program here survives world resets, server wipes,
and losing the computer to a creeper.

## Layout

```
src/                 every program, deployed as a unit to any computer
  startup.lua        boot menu / launcher
  door.lua           PIN-locked redstone door
  pulse.lua          configurable redstone clock
  update.lua         pulls the latest code from GitHub, in game
  lib/ui.lua         screen helpers
  lib/config.lua     table persistence
  manifest.json      generated — the file list update.lua downloads
bootstrap.lua        one-liner installer for a brand new computer
tools/               PowerShell helpers, run from the repo root
types/               CC: Tweaked type definitions (gitignored, see setup.ps1)
```

## Editor setup

One extension does the real work: **`sumneko.lua`** (the "Lua" extension). Combined
with `types/cc-tweaked/library`, it gives you autocomplete, hover docs, go-to-definition
and type checking for every CC API — `redstone.setOutput`, `peripheral.wrap`, the lot.

```powershell
code --install-extension sumneko.lua
.\tools\setup.ps1          # clones the type definitions into types\
```

`.luarc.json` wires the definitions in and is checked in, so it just works.

Also useful, and already installed: `johnnymorganz.stylua` (formatter, configured by
`.stylua.toml`), `usernamehw.errorlens` (shows diagnostics inline), and
`kampfkarren.selene-vscode` (linter). Selene needs to be told what CC's globals are or
it flags every one of them — `selene.toml` and `cc-tweaked.yaml` in the repo root do
that, and are checked in.

**Skip `jackmacwindows.vscode-computercraft`.** It registers a second completion
provider on `.lua`, so you get duplicated and conflicting suggestions next to
sumneko's, and its API data targets CC: Tweaked 1.100.0 — older than what this pack
ships. Disable it in the Extensions panel.

**Do not** let `johnnymorganz.luau-lsp` claim `.lua` files. Luau is Roblox's dialect,
not CC's Lua 5.2. `.vscode/settings.json` pins `*.lua` to the `lua` language to prevent this.

> Note: CC runs Cobalt — Lua 5.2 plus a few 5.3 features. The type definitions declare
> 5.3, which is close enough for tooling, but don't lean on 5.3-only stdlib functions.

## Getting code onto a computer

### On the server (your main world)

You can't reach the computer's files, so it pulls them itself over HTTP.

**One-time:** push this folder to a public GitHub repo, then on a fresh in-game computer:

```
wget run https://raw.githubusercontent.com/USER/REPO/main/bootstrap.lua
```

**Every time after that:**

```powershell
.\tools\make-manifest.ps1     # only if you added or deleted a file
git add -A; git commit -m "..."; git push
```

then in game: `update` — and reboot the computer.

If you get `Domain not permitted` or `HTTP is disabled`, the admin has turned off the
HTTP API; ask them to enable it in `computercraft-server.toml`.

### In a local test world (fast loop)

For iterating on a program, a singleplayer world beats the server — no push, no update.
`tools\link-world.ps1` junctions a computer's folder straight to `src\`:

```powershell
.\tools\link-world.ps1 -List                    # see your local worlds
.\tools\link-world.ps1 -World "New World" -Id 0
```

Now saving in VS Code changes the file the computer runs. Reboot the computer in game
(hold Ctrl+R) to pick it up. Run `tools\unlink-world.ps1` before zipping that world.

## Programs

| Program | What it does |
| --- | --- |
| `startup` | Runs on boot. Arrow-key menu; crashes drop you back here, not into a dead computer. |
| `door` | PIN pad that powers a redstone door for a few seconds. Prompts for side and PIN on first run; lockout after repeated failures. |
| `pulse` | Redstone clock with an exact, editable period. Bone-meal dispensers, droppers, a Create clutch, lamps. |
| `update` | Downloads everything in `manifest.json` from GitHub. |

Settings live in dotfiles on the computer (`.door`, `.pulse`, `.update`) and are not
overwritten by updates. Edit them in game with `edit .door`.

## Handy in-game commands

| | |
| --- | --- |
| `Ctrl+T` (hold) | terminate the running program |
| `Ctrl+R` (hold) | reboot |
| `edit <file>` | built-in editor |
| `ls`, `rm`, `cd` | as you'd expect |
| `lua` | interactive REPL — best way to poke at an API |
| `help <topic>` | built-in docs |

Full API reference: <https://tweaked.cc/>
