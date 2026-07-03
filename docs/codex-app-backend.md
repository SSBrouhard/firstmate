# Codex App backend

`codex-app` is a visible-thread ledger for Codex Desktop.
It is not a headless app-server transport and does not pretend to own the thread API.

Codex App threads are created, forked, read, messaged, interrupted, and archived in Codex Desktop.
Firstmate records enough local state for its normal backend abstraction to reconcile those visible threads alongside tmux and herdr tasks.

## State model

Use `bin/fm-codex-app prepare <task-id> <thread-name> <brief-file>` before creating or forking a visible thread from a brief.
It writes pending task metadata with `backend=codex-app`, `window=<thread-name>`, `codex_app_thread_name=`, `codex_app_thread_state=pending`, `codex_app_pending_action=create_thread_or_fork_thread`, and `codex_app_transport=visible-thread`.

After Codex Desktop has a real thread, record it with:

```sh
bin/fm-codex-app record-thread <task-id> <thread-id> [--turn-id <id>] [--worktree <path>] [--pending-worktree-id <id>]
```

That changes `window=` to the thread id, records `thread_id=`, sets `codex_app_thread_state=visible`, and clears the pending action.
`record-pending` stores a pending worktree id when Desktop has created a worktree request but the final thread id is not known yet.

To bring an already-visible Desktop thread under firstmate supervision, use:

```sh
bin/fm-codex-app adopt-thread <task-id> <thread-id> <project-path> --kind <ship|scout> [--thread-name <name>] [--mode <mode>] [--yolo <on|off>] [--worktree <path>] [--turn-id <id>] [--pending-worktree-id <id>] [--brief <path>]
```

Adoption refuses duplicate task ids and duplicate thread ids.
If `--mode` or `--yolo` is omitted, it resolves the project mode from `data/projects.md` and falls back to `no-mistakes`/`off`.

## Backend operations

`bin/backends/codex-app.sh` routes backend operations through `bin/fm-codex-app`.

Capture is local and cached.
After reading a thread in Codex Desktop, cache the transcript with:

```sh
bin/fm-codex-app record-capture <task-id> <capture-file|->
```

`fm-peek.sh` and `fm_backend_capture codex-app <thread-id> <lines>` then read the tail of `state/<task-id>.codex-app.capture`.
If no cached transcript exists, capture fails with a Desktop instruction instead of fabricating data.

Text send, interrupt, and archive operations are app-owned.
The adapter exits with a clear instruction to use Codex Desktop, then mirror the result into firstmate state.
After archiving in Desktop, run:

```sh
bin/fm-codex-app mark-archived <task-id>
```

Archived threads report `status=archived`; the backend maps that to `idle`.
Visible or pending threads report unknown busy state, so supervision does not claim a live Desktop thread is idle without an explicit archived marker.

## Smoke evidence

`bin/fm-codex-app-smoke-check.sh <transcript-file>` validates simple key-value smoke evidence for this integration.
A passing transcript must include:

```text
visible_thread=ok
list_threads=ok
read_thread=ok
send_message_to_thread=ok
archive=ok
restart_reconcile=ok
```

The checker rejects `app_server_only=ok` or `headless_only=ok`.
That is deliberate: a headless app-server proof does not verify the visible Codex App thread workflow firstmate relies on.
