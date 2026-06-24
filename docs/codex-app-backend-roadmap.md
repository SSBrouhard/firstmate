---
title: "Codex App backend issues and roadmap"
type: roadmap
date: 2026-06-23
---

# Codex App backend issues and roadmap

This document tracks live-operation findings for Firstmate's `codex-app`
backend and the roadmap to make it boringly reliable.

The backend is viable: a Codex App crewmate can be spawned as a visible thread,
complete a no-mistakes ship task, open a PR, pass CI, merge, archive, and tear
down. The remaining work is mostly deterministic lifecycle polish.

## Ground Truth

- `FM_BACKEND=codex-app` means visible Codex Desktop threads, not headless
  `codex app-server` sessions.
- Shell helpers own local Firstmate state: briefs, metadata, PR polling, and
  teardown safety checks.
- Codex Desktop owns thread actions: create, fork, send, read, title, pin,
  archive, and handoff.
- Completed Codex App tasks are archived before teardown, so their threads may
  leave the normal sidebar/project list; that is expected lifecycle behavior,
  not deletion of the merged PR, local merge, scout report, or backlog record.
- Orca and tmux remain separate backends. Codex App work must not regress them.

## Issue Register

| ID | Status | Severity | Issue | Evidence | Next action |
| --- | --- | --- | --- | --- | --- |
| CA-001 | Open | P1 | Thread lifecycle is not fully shell-driven. `fm-spawn` prepares state, but Firstmate must still call Codex App host tools for create/fork/send/read/archive. | Live ship smoke required manual app-tool create, record, read, and archive steps. | Add a host-tool checklist command that prints the exact next app action and records completion state. Longer term, use an official app bridge if Codex exposes one. |
| CA-002 | Open | P1 | Briefs can reference local plan files that are missing from the app-owned worktree. | The advisories task initially blocked because the plan path was not visible in the Codex App worktree. | Make `fm-brief` embed referenced plan content, or fail fast when a referenced plan is untracked or unavailable to the target worktree. |
| CA-003 | Mitigated | P2 | Post-merge branch deletion can fail while the app-owned worktree still has the task branch checked out. | `gh-axi pr merge --delete-branch` merged the PR but failed local branch cleanup because the Codex App worktree held the branch. | Add a merged-task cleanup helper: archive thread, verify PR merge commit on default branch, delete remote task ref, prune, then remove the local task ref. |
| CA-004 | Open | P3 | `fm-pr-check.sh` is easy to misuse because it requires a PR URL but the filename suggests task-only usage. | Calling it with only the task id failed with an unbound `$2`. | Improve argument validation and usage text. Consider inferring the PR URL from `state/<id>.meta`, no-mistakes status, or the latest `done: PR ...` status line. |
| CA-005 | Open | P2 | Watcher liveness restart is not deterministic enough during manual merge/teardown work. | Guard warned that tasks were in flight while the watcher beacon was stale. | Add `bin/fm-watch-start.sh` or an idempotent `fm-watch --daemon` mode and call it from spawn/merge/teardown preflights. |
| CA-006 | Open | P3 | Session lock messaging is noisy under Codex Desktop. | `fm-lock.sh` correctly detected a live Codex process, but the warning did not explain whether this was the current desktop session or a competing Firstmate. | Include lock owner command, age, and a Codex Desktop hint so the operator knows when read-only mode is expected. |
| CA-007 | Open | P2 | "CI green" can look unfinished because no-mistakes keeps the CI step running until merge or close. | `no-mistakes axi status` still showed `ci,running` after logs said all checks passed. | Teach Firstmate's PR-ready path to parse green CI evidence and record "ready to merge" without waiting for the eventual merged/closed terminal state. |
| CA-008 | Open | P2 | Codex App project placement is not owned by Firstmate. | Visible threads can land correctly only when Codex Desktop already has an appropriate saved project/worktree environment. | Add a Codex App project preflight: list the expected project, confirm the worktree environment, and document the path operators should create before dispatch. |

## Roadmap

### Phase 1: Deterministic Operator Loop

- Add a Codex App dispatch checklist that names the exact host-tool action
  Firstmate needs next.
- Make brief generation self-contained for referenced plans and acceptance docs.
- Harden `fm-pr-check.sh` argument handling and PR URL inference.
- Add an idempotent watcher start command and call it before long supervised
  operations.
- Improve lock diagnostics for Codex Desktop sessions.

### Phase 2: Cleanup and Recovery

- Add a merged Codex App task cleanup helper for stale local and remote task
  refs after squash merges.
- Add a reconciliation checklist for app-owned threads after restart:
  `list_threads`, `read_thread`, meta update, backlog update, and archive state.
- Capture `read_thread` snapshots at key lifecycle points so `fm-peek` has useful
  cached output even after the visible thread is idle.

### Phase 3: Product-Quality Backend

- Replace manual host-tool choreography with an official app bridge if Codex
  exposes one.
- Add Codex App project preflight support so task threads land in the intended
  sidebar project consistently.
- Expand live smoke evidence to cover scout, ship, merge, teardown, restart,
  manual operator intervention, and cross-project dispatch.

### Phase 4: Public Replication Brief

- Publish a setup guide that explains the backend split: Firstmate shell state
  plus Codex Desktop visible threads.
- Include the acceptance smoke checklist and known limitations up front.
- Include a compatibility note that Orca remains the stronger fully automated
  backend today, while Codex App is the better visible-thread user experience
  when run from inside Codex Desktop.

## Acceptance Gates

The Codex App backend is public-brief ready when all of these are true:

- A fresh user can follow docs to create the Codex App project and switch
  Firstmate to `FM_BACKEND=codex-app`.
- A scout task appears as a visible `fm-<id>` thread, writes a report, can be
  read and steered, then archives cleanly; after archive it may leave the normal
  sidebar without losing the report.
- A ship task opens a PR, passes no-mistakes, merges, archives, tears down, and
  leaves no stale task state or task branches.
- Restart recovery can reconcile an in-flight visible thread from local meta and
  Codex App thread tools.
- Orca and tmux regression tests still pass unchanged.
