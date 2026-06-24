---
name: firstmate-codexapp
description: Coordinate Firstmate crewmates through the Codex App backend without losing watcher state, worktree isolation, or no-mistakes branch hygiene. Use when dispatching, adopting, reading, steering, archiving, or debugging visible Codex App threads for Firstmate work, especially when using create_thread/list_threads/read_thread/send_message_to_thread with FM_BACKEND=codex-app.
---

# Firstmate Codex App

## Overview

Use this skill when Firstmate work should run as a visible Codex Desktop thread.
The point is to keep three things aligned: Firstmate's `state/*.meta` ledger, the Codex App thread/worktree, and the project branch/no-mistakes lifecycle.

## Non-Negotiables

- Do not replace a Firstmate crewmate with an in-thread `multi_agent` subagent. Hidden subagents may help a visible crewmate with bounded audits, but they are not the lifecycle owner.
- Do not create a Codex App thread directly as the whole dispatch. Run `fm-spawn` first so Firstmate has a task id, brief, meta file, status path, and watcher surface.
- Do not tell the crewmate to `cd` into the saved project checkout for writable work. The crewmate must work in the Codex App-created worktree/current cwd.
- Do not run no-mistakes from the saved project checkout if the work lives in a Codex App worktree. Branch/run state must stay in the worker's actual git worktree.
- If Codex thread tools do not appear, search specifically for `codex_app list_projects create_thread read_thread send_message_to_thread set_thread_archived`. Do not fall back to hidden subagents unless the user explicitly changes the architecture.

## Dispatch Workflow

1. **Prepare Firstmate state.**
   Run the normal spawn path with the Codex App backend selected:

   ```sh
   FM_BACKEND=codex-app bin/fm-spawn.sh <task-id> projects/<repo> codex
   ```

   If backend config already selects `codex-app`, omit the env prefix. The output should point to the brief path and say the next action is `create_thread` or `fork_thread`.

2. **Use app tools, not shell imitation.**
   Call `list_projects`, choose the project whose path matches `projects/<repo>`, then call `create_thread` with a project worktree target. Use `startingState` only when the task requires a specific base branch. Omit model/thinking unless the captain explicitly requested a specific model or effort.

3. **Wrap the brief with worktree safety.**
   Use the `codex_app_brief` file from `state/<task-id>.meta` as the task body, but prepend this instruction:

   ```text
   Codex App backend workspace rule:
   You are in a Codex-created worktree/current cwd. Do all writes, commits, no-mistakes runs, pushes, and PR work from that cwd.
   Do not cd into the saved project checkout at <project-path> for writable work.
   Treat the saved project path as repo identity/context only.
   Before editing, report pwd, git rev-parse --show-toplevel, git branch --show-current, and git log --oneline --max-count=3.
   ```

   This prevents the exact failure mode where the visible thread exists but the crewmate edits `projects/<repo>` directly, bypassing the app worktree and confusing no-mistakes.

4. **Record app state immediately.**
   If `create_thread` returns a thread id:

   ```sh
   bin/fm-codex-app record-thread <task-id> <thread-id> --worktree <thread-cwd> [--pending-worktree-id <pending-id>]
   ```

   If it returns only a pending worktree id:

   ```sh
   bin/fm-codex-app record-pending <task-id> <pending-worktree-id>
   ```

   Then use `list_threads` to find the visible thread once it appears and run `record-thread`. Include the thread cwd from `list_threads`/`read_thread` when available.

5. **Arm supervision.**
   Start or re-arm the watcher after the thread is recorded:

   ```sh
   bin/fm-watch.sh &
   ```

   A visible Codex thread without `state/<task-id>.meta` is invisible to Firstmate recovery and watcher pings.

## Reading And Steering

- Use `read_thread` for truth about Codex App thread progress. Cache with `bin/fm-codex-app record-capture <task-id> <file|->` only if useful; the app thread remains source of truth.
- Use `send_message_to_thread` for steering. If the task is managed by Firstmate, prefer steering through the recorded task id and keep the status/meta files aligned.
- If the user types directly into the visible thread, treat it as authoritative. Reconcile by reading the thread and updating Firstmate records, not by undoing the intervention.
- If `list_threads` cannot find the thread by task title, query by repo/project label and inspect recent idle threads before declaring it missing.

## Completion, PR, And Teardown

- Verify the branch, commit, tests, and PR from the worker's recorded worktree.
- If no-mistakes says `no previous run for branch`, check whether the worker accidentally edited the saved project checkout or switched branches outside its Codex worktree. That error often means the branch/run bookkeeping was crossed, not that the code failed review.
- When a PR is opened, record it with `bin/fm-pr-check.sh <task-id> <PR-url>` so the watcher can notice merge readiness.
- Do not tear down until work is landed. For Codex App tasks, archive the visible thread first:

  ```text
  set_thread_archived(threadId=<thread-id>, archived=true)
  ```

  Then run:

  ```sh
  bin/fm-codex-app mark-archived <task-id>
  bin/fm-teardown.sh <task-id>
  ```

Archived Codex App threads may disappear from the sidebar. That is normal after teardown; Firstmate's landed-work check is the git/PR state, not sidebar persistence.

## Debug Checklist

- No watcher ping: confirm `state/<task-id>.meta` exists, has `backend=codex-app`, `thread_id=...`, and `codex_app_thread_state=visible`.
- Visible thread did work but no status: confirm the brief told the crewmate to append to `state/<task-id>.status`.
- Main project checkout changed: stop, inspect the diff, and decide whether to salvage by moving the branch into the intended worktree. Do not keep dispatching from that corrupted assumption.
- Thread tools seemed missing: retry tool discovery with exact `codex_app` names before choosing another path.
- Project not in `list_projects`: ask the captain to create/save the Codex App project for the repo path, or use Firstmate's non-Codex backend. Do not use projectless threads for repo work.
