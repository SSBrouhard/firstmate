---
name: firstmate-orca
description: Procedural guardrail for operating Firstmate with the Orca backend. Use when switching Firstmate to Orca, spawning or supervising Orca-backed crewmates, smoke-testing Orca backend behavior, debugging Orca task state, or reconciling Firstmate cockpit/source-clone layout while Orca is selected.
---

# Firstmate Orca

## Overview

Use this as a checklist, not a manual. `AGENTS.md` remains the source of truth; this skill keeps the fragile Orca-specific steps from drifting.

## Guardrails

- Work from the cockpit at `/Users/vesta/Desktop/Firstmate`.
- Remember the tracked source clone is `/Users/vesta/Desktop/GitHub/firstmate`; cockpit files such as `bin/`, `AGENTS.md`, and shared skills are symlinked into that clone.
- Treat `config/`, `data/`, `projects/`, `state/`, and `.no-mistakes/` as local/private cockpit state.
- Keep backend and harness separate: Orca is the backend that owns worktrees/terminals; Codex, Claude, opencode, or pi are harnesses running inside them.
- Prefer Firstmate helpers (`bin/fm-*`) over raw Orca commands. Use raw `orca` only when a helper has no surface for the needed inspection.
- Do not switch backend casually while active `state/*.meta` files exist. Existing tasks keep their recorded backend; switching affects future spawns only.
- When a watcher wake occurs, act on it before doing unrelated work.
- Keep user-facing summaries about outcomes. Mention Firstmate internals only when they affect the decision or the user asked.
- For tracked Firstmate changes, keep work local unless explicitly asked to push. If a push is requested, target `origin` (`SSBrouhard/firstmate`), never upstream `kunchenguid/firstmate` without explicit approval.

## Preflight

Run from the cockpit:

```sh
cd /Users/vesta/Desktop/Firstmate
bin/fm-bootstrap.sh
bin/fm-backend-current
find state -maxdepth 1 -name '*.meta' -print
```

If active metadata exists, inspect and reconcile those tasks before switching backend.

## Switch To Orca

Use the profile helper:

```sh
bin/fm-backend-use orca
bin/fm-backend-current
```

If the helper refuses because tasks are active, do not use `--force` until those tasks are intentionally reconciled. If it reports that `FM_BACKEND` or `config/backend` overrides the profile, fix the override rather than assuming the switch took.

## Spawn And Supervise

Spawn through Firstmate so the task has a brief, meta file, status file, worktree record, and watcher surface:

```sh
bin/fm-spawn.sh <task-id> projects/<repo>
bin/fm-spawn.sh <task-id> projects/<repo> --scout
```

After spawn:

- Peek once for trust dialogs or launch failures.
- Confirm `state/<task-id>.meta` includes `backend=orca`, `terminal=`, `orca_worktree_id=`, and `worktree=`.
- Start or re-arm `bin/fm-watch.sh` whenever tasks are in flight.
- Read status/meta files before repeatedly peeking terminals.
- Steer with short lines through `bin/fm-send.sh fm-<task-id> '...'`; put long instructions in the brief or another file.

## Recovery

For an interrupted or messy Orca task:

- Read `state/*.meta` and `state/*.status` first.
- Use recorded `terminal=`, `orca_worktree_id=`, and `worktree=` as the task identity.
- Use `bin/fm-peek.sh`, `bin/fm-send.sh`, and `bin/fm-teardown.sh`; do not manually delete Orca worktrees or project branches.
- If the saved project checkout changed, stop and inspect the diff before continuing. Do not normalize by force.
- Tear down only after scout reports exist or ship work is landed according to the project delivery mode.

## Smoke Test Shape

Use a disposable/local-only project or a scout. Verify only the lifecycle:

1. Select Orca with `bin/fm-backend-use orca`.
2. Spawn a trivial task.
3. Confirm metadata, status write, peek/send, watcher wake, and teardown.
4. Restore the prior backend if the smoke test was temporary.

Keep the smoke test focused on Firstmate-Orca plumbing. Do not mix it with unrelated feature work.
