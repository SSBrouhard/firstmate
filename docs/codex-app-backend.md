# Codex App visible-thread backend protocol

This document defines the intended protocol for a future `codex-app` runtime
backend. It is a design contract, not an implementation guide for a backend
that exists today. At the time this document is added, upstream firstmate
implements `tmux` and experimental `herdr` runtime backends only.

The goal of `codex-app` is to make a crewmate a real Codex Desktop thread that
the captain can see, read, steer, and archive from the app sidebar while
firstmate keeps its normal shell-owned supervision state.

## Boundary: shell state versus Codex Desktop tools

Firstmate shell scripts own local orchestration state:

- task ids, briefs, and status-file paths
- `state/<id>.meta` records
- project delivery mode and yolo posture
- git worktree identity and branch checks
- no-mistakes branch/run hygiene
- PR polling, landed-work checks, and teardown safety

Codex Desktop owns visible thread actions:

- create or fork a thread
- send a message to a thread
- read a thread
- set a thread title or pinned state
- hand off or continue an existing thread
- archive a completed thread

Shell helpers must not pretend that a headless transport is a visible Codex App
thread. If an operation requires a visible thread, the shell side should prepare
or validate local state and then report the host-tool action that must happen in
Codex Desktop. A future bridge may automate those host-tool calls, but that
bridge must still preserve the boundary: shell records state; Codex Desktop owns
thread visibility and thread mutations.

## Identity alignment

A Codex App task has three identities that must stay aligned:

- Firstmate task identity: `id`, `fm-<id>` title, `state/<id>.meta`, and
  `state/<id>.status`.
- Codex App identity: visible `thread_id`, the app-created worktree path or
  pending worktree handle, and the saved project/worktree context used by
  Codex Desktop.
- Git/no-mistakes identity: the actual git worktree where edits and commits
  occur, the task branch, and the no-mistakes run state for that branch.

The crewmate must run git commands, tests, commits, pushes, and no-mistakes from
the Codex App-created worktree, not from the saved project checkout that merely
identifies the repository. Losing that alignment creates a dangerous false
success: the visible thread may look active while no-mistakes is checking a
different branch or firstmate is supervising a different worktree.

At minimum, visible-thread metadata needs to identify:

- `backend=codex-app`
- `window=` or another selector that resolves to the visible thread
- `thread_id=` once Codex Desktop has created the thread
- `codex_app_thread_state=` as `pending`, `visible`, or `archived`
- `worktree=` when the app-created worktree path is known
- a pending worktree handle when Codex Desktop has started worktree creation but
  has not yet surfaced a final worktree path
- the usual `project=`, `harness=`, `kind=`, `mode=`, `yolo=`, `tasktmp=`, and
  PR/no-mistakes fields used by the rest of firstmate

## Lifecycle states

### Pending

`pending` means firstmate has prepared local state but the visible thread is not
fully recorded yet. This can happen when spawn preparation has written a brief
and meta scaffold, or when Codex Desktop has begun creating an app-owned
worktree but has not returned a usable thread id and worktree path.

Allowed shell actions in `pending` are narrow: print the next required Codex
Desktop action, record a returned thread id or pending worktree handle, refuse
normal send/read/teardown operations that require a visible thread, and allow
safe cleanup of failed preparation if no work has started.

### Visible

`visible` means `state/<id>.meta` has a Codex App thread id and enough worktree
identity for firstmate to reconcile the task after restart. The thread should be
discoverable through Codex Desktop thread listing, readable through the app, and
steerable through app thread messaging.

In this state, firstmate may supervise the task through status files and
no-mistakes state, but live thread reads and sends still happen through Codex
Desktop host tools or a verified bridge to those tools. A visible task may be a
ship task, scout task, adopted existing thread, or handoff/fork from an earlier
thread.

### Archived

`archived` means the visible thread has been archived in Codex Desktop after the
task reached a safe completion state. Archive is not deletion. Firstmate must
still preserve the landed PR, local merge evidence, scout report, backlog entry,
and any durable records needed for future audit.

Teardown for Codex App tasks should require archive evidence before removing the
local task state. Ship teardown must also prove work is landed using the same
git and PR rules as other backends. Scout teardown may proceed once the report
exists and the thread archive is recorded.

## Spawn and live thread creation are separate

Spawn preparation and live thread creation are intentionally separate steps.
`fm-spawn` can choose an id, write a brief, create or reserve local metadata, set
the delivery mode, and establish no-mistakes branch expectations without
impersonating Codex Desktop. It cannot, by itself, guarantee a sidebar-visible
Codex App thread unless it is running with a verified host-tool bridge.

The split prevents two failure modes:

- A shell-only helper completing a headless conversation and falsely satisfying
  the "visible backend" contract.
- A manually created visible thread that lacks Firstmate metadata, status-file
  reporting, worktree identity, or no-mistakes branch alignment.

The protocol is therefore prepare, create/fork in Codex Desktop, record the
returned app identity, then supervise. Adoption follows the same rule in reverse:
read the existing visible thread identity from Codex Desktop, then write the
missing Firstmate metadata before treating it as managed work.

## Host-tool operations

A future Codex App backend should treat these host-tool capabilities as the live
surface, whether exposed directly to the agent or through a verified bridge:

- `list_projects` to find the saved project whose path matches the target repo
- `create_thread` for project-scoped task spawn
- `fork_thread` when the captain explicitly wants to inherit completed context
  from an existing thread
- `send_message_to_thread` to deliver the crewmate brief and later steering
- `read_thread` to inspect progress or reconcile after restart
- `set_thread_title` to set the visible `fm-<id>` title
- `set_thread_pinned` when pinning active work is part of the operator flow
- `set_thread_archived` to archive completed work before teardown
- `handoff_thread` only for host-supported handoff flows where ownership or
  continuation semantics differ from a normal send

Project task spawn and current-thread context fork are different flows. Project
spawn should create a task in the intended project/worktree context. Forking the
current firstmate conversation copies conversation context and may put the task
in the wrong repository context unless the host tool explicitly binds it to the
target project.

## No-mistakes hygiene

Codex App visible-thread work must keep no-mistakes tied to the worker's actual
git worktree and branch. The backend protocol should make the crewmate prove its
working directory before editing and before starting the gate:

```sh
pwd -P
git rev-parse --show-toplevel
git branch --show-current
git log --oneline --max-count=3
```

If no-mistakes reports that there is no previous run for the branch, or if a PR
is opened from an unexpected branch, firstmate should check for crossed
worktree/branch bookkeeping before treating the result as a normal validation
failure.

## Future smoke expectations

These are acceptance expectations for a future implementation. They are not
claims about the current upstream tree.

A non-interactive contract test can verify local ledger behavior: pending,
visible, and archived meta transitions; duplicate task/thread refusal; refusal
to treat shell-only send/read as a visible host-tool action; and teardown gates
that require archive plus landed-work evidence.

A live Codex Desktop smoke should prove:

- project-scoped `create_thread` produces a sidebar-visible `fm-<id>` thread
- the thread appears in `list_threads`
- `read_thread` can inspect the task after creation and after restart
- `send_message_to_thread` can steer the task
- the crewmate writes the expected status-file events from the app-created
  worktree
- no-mistakes runs on the same branch and worktree recorded in metadata
- `set_thread_archived` archives completed work without losing PR/report
  evidence
- tmux and herdr regression tests still pass unchanged

Until those smokes exist and pass, documentation and code should describe
`codex-app` as a proposed visible-thread backend protocol rather than a
selectable upstream backend.
