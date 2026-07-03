# Codex App backend

`codex-app` is a visible-thread ledger for Codex Desktop.
It is not a headless app-server transport and does not pretend to own the thread API.

Codex App threads are created, forked, read, messaged, interrupted, and archived in Codex Desktop.
Firstmate records enough local state for its normal backend abstraction to reconcile those visible threads alongside tmux and herdr tasks.

## State model

Use `bin/fm-codex-app prepare <task-id> <thread-name> <brief-file>` before creating or forking a visible thread from a brief.
It writes pending task metadata with `backend=codex-app`, `window=<thread-name>`, `harness=codex`, `codex_app_thread_name=`, `codex_app_thread_state=pending`, `codex_app_pending_action=create_thread_or_fork_thread`, `codex_app_transport=visible-thread`, and `codex_app_brief=`.

After Codex Desktop has a real thread, record it with:

```sh
bin/fm-codex-app record-thread <task-id> <thread-id> --kind <ship|scout> --project <path> --worktree <path> [--worktree-owner external] [--turn-id <id>] [--harness <name>] [--mode <mode>] [--yolo <on|off>] [--pending-worktree-id <id>]
```

That changes `window=` to the thread id, records `thread_id=`, sets `codex_app_thread_state=visible`, and clears the pending action.
When Desktop starts a handoff before the final visible thread id is known, record the pending worktree request with:

```sh
bin/fm-codex-app record-pending <task-id> <pending-worktree-id>
```

This records `codex_app_pending_worktree_id=`, sets `codex_app_thread_state=pending-worktree`, and leaves `codex_app_pending_action=await_thread_id` until `record-thread` supplies the final thread id.
`record-thread` requires protected task state: `kind=ship|scout`, an existing git project directory, and an existing registered linked worktree root must already be recorded in the prepared meta or supplied as flags.
That prevents a prepared visible thread from becoming a default ship task that teardown cannot validate for landed work or scout report delivery.
The ledger records `codex_app_worktree_owner=external`; this slice does not accept treehouse ownership for Codex App visible-thread worktrees because Desktop, not firstmate, owns the thread/worktree lifecycle.
`prepare` refuses an existing task id unless the existing metadata is the same pending Codex App task, so it cannot overwrite a live route.

To bring an already-visible Desktop thread under firstmate supervision, use:

```sh
bin/fm-codex-app adopt-thread <task-id> <thread-id> <project-path> --kind <ship|scout> --worktree <path> [--worktree-owner external] [--thread-name <name>] [--harness <name>] [--mode <mode>] [--yolo <on|off>] [--turn-id <id>] [--pending-worktree-id <id>] [--brief <path>]
```

Adoption refuses duplicate task ids and duplicate thread ids.
`--worktree` must name an existing registered linked worktree root for the project, distinct from the project checkout, for both ship and scout tasks.
Adoption records `codex_app_worktree_owner=external`; unsupported owner values are refused.
When `--harness` is omitted, adoption records `harness=codex`.
If `--mode` or `--yolo` is omitted, it resolves the project mode from `data/projects.md` and falls back to `no-mistakes`/`off`.

## Backend operations

`bin/backends/codex-app.sh` routes backend operations through `bin/fm-codex-app`.

Capture is local and cached.
After reading a thread in Codex Desktop, cache the transcript with:

```sh
bin/fm-codex-app record-capture <task-id> <capture-file|->
```

`fm-peek.sh` and `fm_backend_capture codex-app <thread-id> <lines>` then read the tail of `state/<task-id>.codex-app.capture`.
Recording a capture also updates `codex_app_last_capture=` in the task meta.
If no cached transcript exists for a recorded thread, capture succeeds with empty output.
That keeps passive liveness and peek-style readers from treating a visible Desktop thread as gone merely because firstmate has not cached a transcript yet.
An unrecorded thread id still fails with a Desktop instruction.

Text send, interrupt, and archive operations are app-owned.
The adapter exits with a clear instruction to use Codex Desktop, then mirror the result into firstmate state.
After archiving in Desktop, run:

```sh
bin/fm-codex-app mark-archived <task-id>
```

Archived threads report `status=archived`; the backend maps that to `idle`.
Visible or pending threads report busy state, so stale-pane supervision stays out of app-owned Desktop threads until an explicit archived marker exists.
`fm-teardown.sh` refuses codex-app tasks until the thread is archived in Desktop and marked archived in the ledger.
It also validates the recorded project and worktree before removal; `--force` does not bypass the Codex App archive marker or the project-checkout/registered-worktree safety checks.
Codex App metadata without `codex_app_worktree_owner=external` fails closed at teardown.
For external Codex App worktrees, teardown may clear firstmate's local ledger state after the normal archive/report/landed gates, but it deliberately skips branch deletion and `treehouse return --force`.

`codex-app` is not selectable for new spawns through `--backend`, `FM_BACKEND`, or `config/backend` until a complete visible-thread spawn lifecycle exists.
Use `prepare`, `record-thread`, or `adopt-thread` to create codex-app metadata for Desktop-owned visible threads.

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

Each required key also accepts `yes`, `true`, or `1`.
The checker rejects `app_server_only=ok` or `headless_only=ok`.
That is deliberate: a headless app-server proof does not verify the visible Codex App thread workflow firstmate relies on.
