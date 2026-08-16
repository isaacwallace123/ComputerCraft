# ICOS documentation

This directory is the durable engineering memory for ICOS. The root README explains
the product; these documents explain how it works, why it works that way, and how to
change it safely.

## Suggested reading order

For a new maintainer or coding agent:

1. [AI handoff](ai-handoff.md)
2. [Architecture](architecture.md)
3. [Persistent state](persistence.md)
4. [Network protocol](network-protocol.md)
5. [Mining system](mining.md)
6. [Operations](operations.md)
7. [Decision log](decisions.md)

## Document ownership

| Document | Update it when… |
| --- | --- |
| `architecture.md` | modules, dependency direction, startup, desktop, or lifecycle changes |
| `mining.md` | a job, movement algorithm, ore profile, unloading, or fuel policy changes |
| `network-protocol.md` | a message kind, command, snapshot field, or timeout changes |
| `persistence.md` | a dotfile, saved field, migration, or update behavior changes |
| `operations.md` | installation, deployment, hardware, recovery, or release steps change |
| `decisions.md` | a non-obvious architectural choice is introduced or reversed |
| `ai-handoff.md` | repository conventions, sharp edges, or verification commands change |

Documentation is part of the feature. A code change that invalidates one of these
documents should update it in the same pull request.

## Sources of truth

When documentation and code disagree, use this order:

1. Executed code under `src/`
2. Tests and checks under `tools/`
3. This documentation
4. Historical chat or screenshots

Fix stale documentation once the behavior has been confirmed. Do not silently change
code merely to match an old document.
