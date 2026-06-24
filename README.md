<h1 align="center">firstmate</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.jpg" width="100%" />
</p>

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in visible sessions, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For larger fleets, you can opt in to persistent secondmates: domain supervisors that are still ordinary direct reports, but run from their own isolated firstmate homes.
There is no app to install; the whole orchestrator is an `AGENTS.md` file that any terminal coding agent can follow.

- **One liaison** - you never talk to a worker agent.
  The first mate dispatches, supervises, escalates only real decisions, and reports plain outcomes about work that is ready, blocked, or needs your call.
- **A visible crew** - every crewmate lives in a visible backend session: a tmux window by default, an Orca terminal when `FM_BACKEND=orca`, or a Codex Desktop thread when `FM_BACKEND=codex-app`.
  Watch any of them work, or type into that session to intervene; the first mate reconciles.
  A crewmate may use bounded helper subagents for review, investigation, or test design, but the visible crewmate stays accountable for the task lifecycle.
- **Persistent domain supervisors** - route natural-language scopes through `data/secondmates.md` when a domain deserves its own long-lived supervisor.
  Each secondmate has a separate `FM_HOME`, local state, local projects, and its own session lock, while the main first mate still supervises it like any other direct report.
- **Guarded by construction** - the first mate is read-only over your projects except for clean local default-branch refreshes, safe pruning of local branches whose remote is gone, and approved `local-only` fast-forward merges; crewmates work in disposable backend-owned worktrees.
  Ship tasks follow each project's delivery mode, and scout tasks produce local reports without pushing anything.

This is not an agent harness. This is not a skill. This is not a CLI.

This is.. a directory that turns any agent into your firstmate, with you still in control.

## Quick Start

```sh
$ git clone https://github.com/kunchenguid/firstmate && cd firstmate
$ claude   # launch your agent harness here; AGENTS.md takes over

> look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and spawns two crewmates in visible sessions
# fm-fix-login-k3 and fm-dark-mode-p7.
# Minutes later:

  PR ready for review: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

## Install

**Prerequisites** (the first mate detects everything else and offers to install it):

```sh
# 1. a verified agent harness - claude, codex, opencode, or pi
# 2. git + GitHub auth
# 3. one visible backend: tmux/treehouse by default, Orca CLI, or Codex Desktop
gh auth login
```

**Get firstmate:**

```sh
git clone https://github.com/kunchenguid/firstmate
cd firstmate && claude
```

That is the whole install.
On first launch the first mate detects what its selected backend and shared toolchain are missing or too old (tmux/treehouse, Orca, node, gh, no-mistakes, gh-axi, chrome-devtools-axi, lavish-axi), lists it with the exact install commands, and installs only after you say go.
If compatible `tasks-axi` is already on `PATH`, bootstrap records it as an optional capability fact and firstmate uses its verbs for routine backlog mutations; when it is absent or incompatible, firstmate keeps hand-editing `data/backlog.md` exactly as before.

**Run it inside tmux for the best experience.**
firstmate works from any terminal - outside tmux, crewmates land in a detached `firstmate` session you can attach to - but launching your harness from inside tmux puts every crewmate window in your own session, one per task, where you can watch the crew work in real time or type into any window to intervene.

**Or choose another visible backend.**
Set `FM_BACKEND=orca` or write `orca` to `config/backend` to spawn Orca-managed worktrees and terminals while keeping the same firstmate lifecycle.
Set `FM_BACKEND=codex-app` or write `codex-app` to `config/backend` to use visible Codex Desktop threads.
Codex App mode deliberately does not drive `codex app-server`: app-server/headless sessions are useful for automation, but they are not the visible threads you can click, rename, and chat with in Codex Desktop.
For Codex App tasks, `bin/fm-spawn.sh` prepares the metadata, then firstmate uses Desktop thread tools such as `create_thread`, `fork_thread`, `send_message_to_thread`, `read_thread`, and `set_thread_archived`.
Secondmates still run through tmux because each persistent supervisor owns an isolated `FM_HOME` and shell lifecycle.

## How It Works

```
            you
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ + firstmate routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend send/read / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   visible sessions you can watch
 │crewmate│   │crewmate│      │crewmate│   one accountable agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  backend worktree or isolated secondmate home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► relay findings ► teardown
```

- **Event-driven supervision** - a zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet and wakes the first mate only when a crewmate reports, stalls, a PR merges, or an internal heartbeat review is due.
  Detected wakes are also written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed one-shot process exit can be recovered by draining the queue.
  Routine watcher polling, restarts, elapsed waiting time, and unchanged heartbeat reviews stay silent; an idle crew costs you nothing.
  A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if tasks are in flight and that watcher stops running or queued wakes are waiting to be drained.
  A presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) extends this for walk-away supervision: the `/afk` skill activates it, after which it self-handles routine wakes in bash and escalates only user-relevant events as one batched, single-line digest (prefixed with an in-band sentinel marker so firstmate can tell daemon injections apart from real messages).
  Its injection path shares `bin/fm-tmux-lib.sh` with `fm-send.sh`, so dim-ghost-aware and border-aware composer detection plus verified submit retry stay consistent; stalled escalation delivery raises `state/.subsuper-inject-wedged` after `FM_MAX_DEFER_SECS` instead of silently deferring forever.
- **Worktrees, not branches in your checkout** - crewmates never touch your clone; tmux uses treehouse pools, Orca uses Orca-managed worktrees, and Codex App owns its visible thread/worktree state.
- **Two task shapes** - ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tasks investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.
- **Optional secondmates** - `data/secondmates.md` records persistent domain supervisors with natural-language scopes, project clone lists, and home paths.
  `fm-home-seed.sh` provisions the isolated home, clones the listed PR-based projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and `fm-spawn.sh --secondmate` launches it through the tmux and status-file path.
  When seeded with `-`, the home is a durable treehouse lease under the secondmate id, so it survives with no live process and is not recycled by later `treehouse get` or pruning.
  Retirement or seed rollback returns the leased home; normal restart/recovery keeps it leased.
  If returning the lease fails during teardown, firstmate leaves the route and home intact instead of hiding a still-held lease.
  Seeding is transactional: if validation, cloning, initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.
  `local-only` projects stay with the main first mate because they merge into the main local checkout instead of a remote-backed PR path.
  The same project may appear in multiple secondmate homes when their scopes differ, such as issue triage versus feature development.
  Secondmates are idle by default: after startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.
  After seeding a secondmate, `fm-backlog-handoff.sh` moves already-judged in-scope queued items from the main backlog into that secondmate home so the domain queue starts in the right place.
  Idle secondmate panes are healthy; teardown is explicit and refuses while the secondmate home has in-flight work unless discard has been explicitly approved with `--force`.
- **Project modes are explicit** - `data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
  `no-mistakes` projects run the full validation pipeline, `direct-PR` projects open PRs without that pipeline, and `local-only` projects stay local until firstmate performs an approved fast-forward merge.
- **Project memory belongs to projects** - durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
  Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
- **Local clones stay fresh** - bootstrap and PR-based teardown refresh remote-backed project clones with clean default-branch fast-forwards when the clone is on the default branch and has no local work, and prune local branches whose remote is gone and that no worktree still needs.
- **Self-updates stay safe** - `/updatefirstmate` fast-forwards the running firstmate repo and registered secondmate homes from `origin`, then re-reads updated instructions and nudges updated secondmates without touching project clones.
  The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
- **Restart-proof** - all state lives in the configured backend, status files, local markdown under `data/`, `data/secondmates.md`, recorded worktrees, and persistent secondmate homes.
  Kill the first mate session anytime; the next one reconciles and carries on.

## The bin/ toolbelt

The first mate drives these; you rarely need to, but they work by hand too.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-bootstrap.sh`        | Detect required toolchain problems and optional capability facts; refresh clones best-effort; install tools only after consent |
| `fm-backend.sh`          | Shared backend adapter library for tmux, Orca, and Codex App visible-thread dispatch/read/send paths               |
| `fm-backend-current`     | Print the active backend selection and profile details                                                             |
| `fm-backend-use`         | Switch the local backend or named backend profile under gitignored `config/`                                        |
| `fm-fleet-sync.sh`       | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `fm-update.sh`           | Self-update the running firstmate repo and registered secondmate homes with fast-forward-only pulls from origin     |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home                 |
| `fm-brief.sh`            | Scaffold a ship brief, a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate`      |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when tasks are in flight but queued wakes are pending or the watcher liveness beacon is stale or missing      |
| `fm-home-seed.sh`        | Lease/provision a secondmate home transactionally, clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs, or a persistent secondmate with `--secondmate`; honors the active backend |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, with optional `--stat` output                              |
| `fm-watch.sh`            | Singleton-safe one-shot watcher; blocks until supervision work is due, queues it durably, then exits with one reason line |
| `fm-supervise-daemon.sh` | Presence-gated sub-supervisor for walk-away (`/afk`) supervision: wraps `fm-watch.sh`, self-handles routine wakes in bash, and escalates only captain-relevant events as one verified, batched, single-line digest prefixed with a sentinel marker |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work                                              |
| `fm-send.sh`             | Send one verified literal line (or `--key Escape`) to a tmux/Orca crewmate; Codex App mode refuses with the host-tool action |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, dim-ghost-aware and border-aware composer detection, and verified submit retry |
| `fm-peek.sh`             | Print a bounded tail of a crewmate session when the backend can expose one                                         |
| `fm-codex-app`           | Local ledger and safety guard for visible Codex Desktop threads; records thread ids, captures, pending ids, and archive state |
| `fm-codex-app-smoke-check.sh` | Check a captured Codex App smoke transcript for visible-thread proof and reject headless-only evidence       |
| `fm-pr-check.sh`         | Record a PR-ready task and arm the watcher's merge poll                                                             |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Return the worktree or retire/release a secondmate home; protects ship work, requires scout reports, checks child work, and prints the backlog reminder |
| `fm-harness.sh`          | Detect the running harness; resolve the effective crewmate harness                                                  |
| `fm-lock.sh`             | Per-home firstmate session lock                                                                                     |

## Configuration

The shared orchestrator behavior lives in `AGENTS.md` - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.
The tracked `.tasks.toml` pins the optional `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations and keeps secondmate transfers behind `fm-backlog-handoff.sh` validation; without it, backlog bookkeeping remains manual.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer.
Personal preferences for one user's fleet live locally in `data/captain.md`; it is gitignored and read after `data/projects.md` and optional `data/secondmates.md` during bootstrap.
Persistent secondmate routes live locally in `data/secondmates.md`.
Each line records the secondmate id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - <project>...` to lease a fresh firstmate worktree for the secondmate home.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent and refuses in-flight items or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.
`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, the repo root is the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_BACKEND` selects the visible crew backend for ordinary ship/scout tasks.
It overrides local `config/backend`, then `config/backend.env`; valid values are `tmux`, `orca`, and `codex-app`.
Named profiles live under gitignored `config/backends/` and can be switched with `bin/fm-backend-use`.
Harness support is a table in section 4: claude, codex, opencode, and pi are all empirically verified; new harnesses get verified through a supervised trial task before joining the table.

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home; unset means this repo root
FM_BACKEND=tmux          # visible crew backend: tmux, orca, or codex-app
FM_POLL=15              # seconds between watcher cycles
FM_HEARTBEAT=600        # base seconds between fleet reviews; backs off exponentially while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merged-PR polls)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_GUARD_GRACE=300      # seconds a stale watcher beacon may age before guard warnings
FM_WATCHER_STALE_GRACE=300   # duplicate watcher lock grace; defaults to FM_GUARD_GRACE
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=20   # seconds allowed for bootstrap's best-effort clone refresh
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.|codex-app status: active'   # busy signatures, shared by watcher and helpers
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after dim-ghost and border stripping
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_ORCA_CODEX_AUTO_TRUST=0       # opt-in: pre-trust Orca-created Codex project worktrees
FM_ORCA_CODEX_CONFIG=            # optional Codex config path for Orca runtime trust setup
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_TARGET=firstmate:0   # supervisor tmux target (override; auto-discovers from $TMUX_PANE)
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_STALE_ESCALATE_SECS=240         # idle seconds before a stale pane escalates as a possible wedge
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status classifier
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_INJECT_FAIL_SLEEP=30            # seconds between retries after an injection failure
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed user-relevant status
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale-recheck, and scan passes
FM_LOG_MAX_BYTES=1048576           # daemon log size cap before truncating
FM_LOG_KEEP_LINES=2000             # daemon log lines retained after truncation
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before backing off
FM_CRASH_WINDOW=60                 # seconds for crash-loop detection
FM_CRASH_BACKOFF=60                # seconds to sleep after crash-loop detection
FM_CRASH_NORMAL_SLEEP=5            # seconds to sleep after a non-crash-loop watcher failure
```

## Development

Tracked changes to firstmate itself, including `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `docs/plans/`, `test/`, `tests/`, and agent skill files, ship through the `no-mistakes` pipeline on a feature branch and require explicit merge approval.
When supervising live crewmates, keep long validation or build work in the background so watcher wakes can still be handled.
Human-authored pull requests targeting `main` must be raised through `git push no-mistakes`; see `CONTRIBUTING.md` for the enforced contributor workflow.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory instead.
The current watcher reliability work keeps the one-shot process model and adds a durable queue plus singleton lock.
The presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) provides proactive wake routing for walk-away supervision via the `/afk` skill; a blocking-waiter split remains a deferred follow-up phase.

```sh
git grep -l '^#!/usr/bin/env bash' -- bin tests test | xargs bash -n   # syntax-check every bash script, including extensionless helpers
node --check bin/fm-codex-app                                # syntax-check the Codex App ledger
git grep -l '^#!/usr/bin/env bash' -- bin tests test | xargs shellcheck -x   # lint the toolbelt and behavior tests; CI enforces this
for test_script in tests/*.test.sh test/*.test.sh; do "$test_script"; done   # behavior and backend contract tests, matching CI
tests/fm-wake-queue.test.sh               # durable wake queue, singleton behavior, sub-supervisor classifier, /afk presence-gating, border-aware composer, max-defer, and fm-send submit tests
tests/fm-composer-ghost.test.sh           # dim-ghost stripping, ghost-only composer detection, and escape-free peek tests
tests/fm-afk-inject-e2e.test.sh           # private-socket end-to-end test of the afk injection path (partial-input deferral, swallowed-Enter retry)
tests/fm-bootstrap.test.sh                # bootstrap dependency and feature-probe tests
tests/fm-update.test.sh                   # fast-forward-only self-update, reread, nudge, dedup, and skip-safety tests
tests/fm-secondmate.test.sh               # persistent secondmate routing, seeding, idle charter, backlog handoff, spawn, recovery, teardown, and FM_HOME tests
tests/fm-teardown.test.sh                 # fm-teardown.sh safety and reminder checks: local-only fork-remote allow, truly-unpushed refuse, merged-to-main allow, no-mistakes regression, tasks-axi reminder, --force override
test/fm-backend-regression.test.sh        # backend selection, Codex App spawn contract, and Orca launch ordering
test/fm-codex-app-state.test.sh           # visible Codex Desktop thread ledger state
test/fm-codex-app-teardown.test.sh        # Codex App worktree/PR/archive teardown safety
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
FM_HEARTBEAT=2 FM_POLL=1 bin/fm-watch.sh  # watcher smoke test (prints "heartbeat")
```
