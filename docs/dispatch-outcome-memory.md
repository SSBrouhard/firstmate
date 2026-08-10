# Dispatch outcome memory and escalate-on-stuck

This policy covers learning from verified worker endings and re-running a capability-stuck task with a stronger standing profile.
It uses native Firstmate shell interfaces without a model gateway or mid-session profile swap.

## Outcome log

`bin/fm-dispatch-outcome.sh` owns the command mechanics through its header and `--help` output.

The default operational-home path is `data/dispatch-outcomes.jsonl`.
Set `FM_DISPATCH_OUTCOMES` or pass `--log` to select another path.

| Command | Role |
| --- | --- |
| `record <id> --outcome <done\|failed\|escalated\|blocked> [--note "..."]` | Append one JSON line using dispatch fields from `state/<id>.meta` when available |
| `suggest [--kind ship\|scout] [--repo <name>] [--limit N]` | Summarize recent matching outcomes as intake evidence |
| `show [--limit N]` | Print the newest raw outcome lines |

The log never edits `config/crew-dispatch.json` and does not select or change a running worker's profile.
It is not an online bandit and performs no network access.

## Lifecycle integration

A successful non-secondmate cleanup records `done` before task metadata is removed.
An explicitly forced discard records `failed`.
The cleanup continues if this best-effort measurement write fails.

For endings outside cleanup, record a verified `done` or `failed` outcome directly.
Record `blocked` for infrastructure and external blockers that are not capability misses.
The stuck escalation helper records `escalated` on the prior attempt when its apply transaction succeeds. `--once` idempotency is scoped to the durable task `spawn_generation`, outcome, and note, so a reused task id starts a distinct measurement generation.

`suggest` is evidence for intake judgment only.
It must never rewrite dispatch configuration.

## Escalate-on-stuck policy

Firstmate may re-run a task with one stronger standing profile when all of the following evidence is present:

- The worker endpoint is alive.
- The same product or acceptance failure remains after at least two real fix attempts by default.
- Stuck-worker recovery is exhausted on that same failure.
- Validation is not advancing.
- The task is not waiting on an operator, an external process, or a declared pause.
- The task has not already received an automatic escalation.

The threshold is configurable through `--n` or `FM_STUCK_CLASSIFY_N`.
A stronger target must already exist in the active `config/crew-dispatch.json`, carry a public integer `strength` from 0 through 2147483647 that is strictly greater than the current standing profile, and be the only profile at the next greater strength.
The helper never invents a model, runtime, or effort tier.
Equal-strength harness, model, or effort changes are lateral and never qualify for automatic escalation.

One escalation is the hard automatic limit for a task attempt.
A further profile escalation requires an operator decision rather than another automatic restart.
Infrastructure failures and external waits remain `blocked`, while a demonstrated capability miss may become `escalated`.
Worker self-report without failed-acceptance evidence is never sufficient.

## Automated classifier

`bin/fm-stuck-classify.sh` owns the executable interfaces and stable reason codes through its header and `--help` output.

| Command | Role |
| --- | --- |
| `classify` | Produce a pure evidence decision and stable reason code |
| `resolve-stronger --from-profile <h[/m[/e]]>` | Select one stronger standing profile without changing configuration |
| `escalate <prior-id> --target-profile ... --new-id ... --reserve` | Bind the latest durable `escalate` decision and reserve the follow-on id before spawning |
| `escalate <prior-id> --target-profile ... --new-id ... --commit` | Commit linkage after follow-on metadata matches the target |

The possible verdicts are `escalate`, `refuse`, and `uncertain`.
Incomplete or ambiguous durable evidence returns `uncertain` and never silently escalates.
Dead endpoints remain the responsibility of stuck-worker recovery.

The reserve path persists the validated source, target, and follow-on id without changing either task record or the ending log.
The reservation returns `reservation_id`; pass it to `fm-spawn.sh --escalation-reservation` for the follow-on.
The commit path verifies that reservation identity plus the follow-on harness, model, and effort against the reserved target, writes `escalated_from=` durably to both task records, then records the prior outcome as `escalated`.
It uses a recoverable pending transaction and global follow-on-id claim so a failed apply can be retried without duplicating or misattributing linkage.
It refuses arbitrary targets, unreserved commits, mismatched or missing follow-on metadata, concurrent duplicate apply attempts, and any second apply after linkage exists.

## Classify decision log

Every successful `classify` call appends one JSON line to `data/stuck-classify-decisions.jsonl` by default. Records include a decision identity and the task's `spawn_generation` when an authoritative task record exists, allowing reserve to bind the latest decision to that exact attempt.
`FM_DATA_OVERRIDE` changes the data root, `FM_STUCK_CLASSIFY_LOG` selects an explicit path, and the value `off` disables decision logging for a decision-only caller.

Each line records a UTC timestamp, optional task id, normalized evidence, threshold metrics, verdict, reason, and detail.
The decision stream is append-only and remains distinct from the verified-ending stream in `data/dispatch-outcomes.jsonl`.
An append failure is reported on standard error but does not change the classification result or successful classification exit status.

When a task id is available, later analysis can join classify decisions to verified endings.
Production false-escalate, missed-escalate, and post-escalation completion rates remain undefined until live adjudicated denominators exist.

## Synthetic policy-conformance challenge suite

`tests/fm-stuck-policy-conformance.test.sh` runs the frozen corpus in `tests/fixtures/stuck-policy-conformance-v1.json`.
The corpus stores adjudicated eligibility separately from expected classifier verdict and reason, so gold labels do not come from classifier output.

The runner uses only a disposable `mktemp` operational home.
It explicitly sets every supported path override, rejects the real operational home, performs no network calls, leaves dispatch configuration unchanged, and verifies the known real-home measurement, state, and dispatch files did not change.

The result includes the full eligibility-by-verdict confusion matrix, per-stratum counts, `uncertain` abstentions, false decisions among all escalation decisions, and misses among truly eligible cases.
It also checks one bounded escalation-linkage sequence with a prior outcome, `escalated_from`, and exactly one terminal follow-on.
It does not claim simulated recovery efficacy.

Challenge-suite results measure deterministic conformance to the versioned synthetic corpus, not fleet workload prevalence or production incidence.
Production rates remain undefined until live adjudicated denominators exist.

The suite should remain only while it adds material evidence beyond unit tests, such as an independent frozen corpus, cross-case confusion reporting, disposable-home isolation, or stateful apply and anti-thrash coverage.
If those properties disappear and it becomes only a wrapper around unit assertions, remove the wrapper and retain the measurement extract and focused tests.

Run the measurement checks with:

```sh
bash tests/fm-dispatch-outcome.test.sh
bash tests/fm-stuck-classify.test.sh
bash tests/fm-stuck-policy-conformance.test.sh
```

## Related contracts

- [`configuration.md`](configuration.md) owns the dispatch-profile schema.
- [`scripts.md`](scripts.md) indexes the executable toolbelt.
- [`../.agents/skills/stuck-crewmate-recovery/SKILL.md`](../.agents/skills/stuck-crewmate-recovery/SKILL.md) owns ordinary stuck-worker recovery.
- [`../.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md) owns worker-runtime dispatch mechanics.
