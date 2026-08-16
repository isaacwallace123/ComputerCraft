# ICOS agent guide

Read [`docs/ai-handoff.md`](docs/ai-handoff.md) before changing this repository. It
contains the working conventions, verification commands, high-risk invariants, and a
map to the deeper documentation.

The short version:

- Preserve unrelated and uncommitted work. Never reset the worktree to make a task easier.
- Treat the repository as the source of truth; in-game computers are deployment targets.
- Keep dependencies flowing `apps → miner/jobs/fleet → turtle → core`.
- Preserve the chest-below convention, saved navigation after confirmed movement, and
  exact return-route fuel reserve.
- Use `tools\make-manifest.ps1` after changing files under `src/`.
- Run `tools\check.ps1` and `git diff --check` before handing work back.
- Do not commit, push, open a PR, or bump the version unless the user asks.

Start documentation at [`docs/README.md`](docs/README.md).
