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

It also disables `param-type-mismatch` and `undefined-field`. Those aren't laziness:
the definition set declares its string enums (`fs.openMode`, `os.locale`, …) with a
legacy annotation syntax that LuaLS 3.19 reads as *including the quote characters*, so
every correct `fs.open(path, "w")` gets flagged. With them off, `lua-language-server
--check .` reports zero problems across the repo; leave them on and you get ~129 false
ones. Undefined globals and syntax errors are still caught, and selene backs it up.

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

**One-time, public repo:** push this folder, then on a fresh in-game computer:

```
wget run https://raw.githubusercontent.com/USER/REPO/main/bootstrap.lua
```

**One-time, private repo:** the repo can stay private — the computer just has to
authenticate. `raw.githubusercontent.com` ignores auth headers, so `update.lua`
automatically switches to the GitHub contents API (`Accept: application/vnd.github.raw`,
which returns the plain file rather than base64) whenever a token is configured.

`wget run` can't send headers, so bootstrapping needs a different first step:

```powershell
.\tools\print-bootstrap.ps1 -User me -Repo ComputerCraft -Token github_pat_xxx
```

That copies a one-liner to your clipboard. In game: `lua`, Ctrl+V, Enter. Everything
after that is the normal `update` flow.

> **Token hygiene.** The token is stored in plain text in `.update` on the computer.
> Anyone who can reach that computer in game, the server admin, and anyone with the
> world files can read it. Use a **fine-grained** PAT scoped to that **one repository**,
> `Contents: Read-only`, with an expiry date. Never a classic token, never one you use
> elsewhere. If that's not acceptable, keep the repo public — it's only Minecraft Lua —
> and keep genuine secrets out of it entirely.

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
