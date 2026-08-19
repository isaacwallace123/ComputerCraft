# ICOS agent guide

Read [`docs/ai-handoff.md`](docs/ai-handoff.md) before changing this repository. It
contains the working conventions, verification commands, high-risk invariants, and a
map to the deeper documentation.

The short version:

- Preserve unrelated and uncommitted work. Never reset the worktree to make a task easier.
- Treat the repository as the source of truth; in-game computers are deployment targets.
- Keep dependencies flowing one way: `src/os/` and `src/apps/` know about `src/domain/`,
  `src/domain/` knows only about `src/ports/` and `src/lib/`, and `src/adapters/` implement
  ports without being named by anything above them. `src/domain/`, `src/ports/`, `src/ui/`
  and `src/lib/` may not reference a CC global - `tools\check.ps1` fails the build if they
  do, and its allow list is empty. Take it through a port instead.
- `src/legacy/` is ICOS 1, which is what a live fleet runs today. Everything else is
  ICOS 2. Changing the wrong one of a pair builds, passes, and does nothing (D039).
- Preserve the chest-below convention, saved navigation after confirmed movement, and
  exact return-route fuel reserve.
- Use `tools\make-manifest.ps1` after changing files under `src/`.
- Run `tools\check.ps1` and `git diff --check` before handing work back.
- Do not commit, push, open a PR, or bump the version unless the user asks.

Start documentation at [`docs/README.md`](docs/README.md).
