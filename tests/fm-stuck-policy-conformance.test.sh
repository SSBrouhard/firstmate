#!/usr/bin/env bash
# Versioned synthetic policy-conformance challenge suite for stuck escalation.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLASSIFIER="$ROOT/bin/fm-stuck-classify.sh"
OUTCOME="$ROOT/bin/fm-dispatch-outcome.sh"
CORPUS="$ROOT/tests/fixtures/stuck-policy-conformance-v1.json"
REAL_HOME=${HOME:?}

command -v jq >/dev/null 2>&1 || { echo "not ok - jq is required" >&2; exit 1; }
[ -f "$CORPUS" ] || { echo "not ok - missing frozen scenario corpus" >&2; exit 1; }
jq -e '
  .suite == "stuck-policy-conformance-v1" and
  .policy_threshold == 2 and
  .label_status == "frozen" and
  (.scenarios | type) == "array" and
  (.scenarios | length) == 18 and
  ([.scenarios[].id] | length) == ([.scenarios[].id] | unique | length) and
  ([.scenarios[].id] | sort) == (["already-escalated","ambiguous-evidence","below-threshold","dead-endpoint","declared-pause","defaults-missing-evidence","different-failure","eligible-above-threshold","eligible-at-threshold","endpoint-not-alive","external-wait","infra-contradicts-capability-signals","operator-parked","recovery-not-exhausted","self-report-only","terminal-done","unknown-crew-state","validation-advancing"] | sort) and
  ([.scenarios[].stratum] | group_by(.) | map({(.[0]): length}) | add) == {"abstention":1,"anti-thrash":1,"contradictory-evidence":1,"missing-evidence":2,"refusal-class":10,"threshold":3} and
  ([.scenarios[].truth_eligible] | group_by(.) | map({(.[0]): length}) | add) == {"indeterminate":3,"no":13,"yes":2} and
  ([.scenarios[].expected_verdict] | group_by(.) | map({(.[0]): length}) | add) == {"escalate":2,"refuse":13,"uncertain":3} and
  all(.scenarios[];
    . as $scenario |
    ($scenario.id | type) == "string" and ($scenario.id | length) > 0 and
    ($scenario.stratum | type) == "string" and ($scenario.stratum | length) > 0 and
    (["yes","no","indeterminate"] | index($scenario.truth_eligible)) != null and
    (["escalate","refuse","uncertain"] | index($scenario.expected_verdict)) != null and
    ($scenario.expected_reason | type) == "string" and ($scenario.expected_reason | length) > 0)
' "$CORPUS" >/dev/null || { echo "not ok - invalid or empty frozen scenario corpus" >&2; exit 1; }

LAB_HOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-stuck-policy-conformance.XXXXXX")
cleanup() { rm -rf "$LAB_HOME"; }
trap cleanup EXIT HUP INT TERM
LAB_HOME=$(cd "$LAB_HOME" && pwd -P)
REAL_HOME=$(cd "$REAL_HOME" 2>/dev/null && pwd -P) || {
  echo "not ok - cannot canonicalize the real home" >&2
  exit 1
}
[ "$LAB_HOME" != "$REAL_HOME" ] || {
  echo "not ok - disposable lab resolves to the real home" >&2
  exit 1
}

LAB_STATE="$LAB_HOME/state"
LAB_DATA="$LAB_HOME/data"
LAB_CONFIG="$LAB_HOME/config"
LAB_TMP="$LAB_HOME/tmp"
AUDITED_BIN="$LAB_HOME/bin"
PROHIBITED_LOG="$LAB_HOME/prohibited-invocations.log"
LAB_OUTCOMES="$LAB_DATA/dispatch-outcomes.jsonl"
LAB_DECISIONS="$LAB_DATA/stuck-classify-decisions.jsonl"
OBSERVED="$LAB_HOME/observed.jsonl"
REPORT="$LAB_HOME/report.json"
mkdir -p "$LAB_STATE" "$LAB_DATA" "$LAB_CONFIG" "$LAB_TMP" "$AUDITED_BIN"
: >"$OBSERVED"
: >"$PROHIBITED_LOG"

for tool in bash jq perl date dirname mkdir mktemp mv rm rmdir ln grep tail cut tr wc sort awk sleep readlink ps stat od uname shasum cat basename; do
  tool_path=$(command -v "$tool") || { echo "not ok - required audited tool missing: $tool" >&2; exit 1; }
  ln -s "$tool_path" "$AUDITED_BIN/$tool"
done
for tool in gh curl wget nc ssh git fm-spawn.sh fm-crew-dispatch.sh; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" >>%q\nexit 97\n' "$tool" "$PROHIBITED_LOG" >"$AUDITED_BIN/$tool"
  chmod +x "$AUDITED_BIN/$tool"
done

operational_signature() {
  local root=$1 path rel
  for rel in \
    data/dispatch-outcomes.jsonl \
    data/stuck-classify-decisions.jsonl \
    config/crew-dispatch.json \
    state/l1-policy-prior.meta \
    state/l1-policy-follow.meta \
    state/.l1-policy-prior.stuck-escalate.pending \
    state/.l1-policy-follow.stuck-escalation-reservation; do
    path="$root/$rel"
    if [ -f "$path" ] && [ ! -L "$path" ]; then
      printf '%s\t' "$rel"
      shasum "$path"
    elif [ -e "$path" ] || [ -L "$path" ]; then
      printf '%s\tunsafe-or-nonregular\n' "$rel"
    else
      printf '%s\tmissing\n' "$rel"
    fi
  done
}
REAL_HOME_BEFORE=$(operational_signature "$REAL_HOME")
OPERATIONAL_ROOT_BEFORE=$(operational_signature "$ROOT")

cat >"$LAB_CONFIG/crew-dispatch.json" <<'JSON'
{"rules":[{"when":"complex ship","use":{"harness":"codex","model":"gpt-policy","effort":"high","strength":20}}],"default":{"harness":"codex","model":"gpt-policy","effort":"medium","strength":10}}
JSON
cat >"$LAB_CONFIG/no-stronger.json" <<'JSON'
{"default":{"harness":"codex","model":"gpt-policy","effort":"medium","strength":10}}
JSON

run_lab() {
  env -i \
    PATH="$AUDITED_BIN" HOME="$LAB_HOME" TMPDIR="$LAB_TMP" \
    FM_HOME="$LAB_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$LAB_STATE" FM_DATA_OVERRIDE="$LAB_DATA" \
    FM_CONFIG_OVERRIDE="$LAB_CONFIG" \
    FM_DISPATCH_OUTCOME_BIN="${FM_TEST_OUTCOME_BIN:-$OUTCOME}" FM_DISPATCH_OUTCOMES="$LAB_OUTCOMES" \
    FM_FAIL_ONCE_MARKER="${FM_FAIL_ONCE_MARKER:-}" FM_REAL_OUTCOME="$OUTCOME" \
    FM_STUCK_CLASSIFY_LOG="$LAB_DECISIONS" FM_STUCK_CLASSIFY_N=2 \
    "$@"
}

jq -c '.scenarios[]' "$CORPUS" | while IFS= read -r scenario; do
  id=$(printf '%s' "$scenario" | jq -r '.id')
  args=(classify --json --id "$id" --n 2)
  for field in endpoint_alive crew_state failure_class same_failure fix_attempts recovery_exhausted self_report_only already_escalated; do
    value=$(printf '%s' "$scenario" | jq -r --arg field "$field" 'if has($field) then .[$field] else empty end')
    [ -z "$value" ] || args+=("--${field//_/-}" "$value")
  done
  if output=$(run_lab "$CLASSIFIER" "${args[@]}"); then
    verdict=$(printf '%s' "$output" | jq -r '.verdict')
    reason=$(printf '%s' "$output" | jq -r '.reason')
  else
    verdict=error
    reason=classifier_failed
  fi
  printf '%s' "$scenario" | jq -c --arg observed "$verdict" --arg observed_reason "$reason" \
    '. + {observed_verdict:$observed, observed_reason:$observed_reason}' >>"$OBSERVED"
done

jq -s '
  def count($truth; $verdict): map(select(.truth_eligible == $truth and .observed_verdict == $verdict)) | length;
  . as $rows |
  {
    suite: "stuck-policy-conformance-v1",
    product_name: "Synthetic policy-conformance challenge suite",
    scenario_count: length,
    confusion_matrix: {
      truth_eligible_yes: {escalate: count("yes";"escalate"), refuse: count("yes";"refuse"), uncertain: count("yes";"uncertain")},
      truth_eligible_no: {escalate: count("no";"escalate"), refuse: count("no";"refuse"), uncertain: count("no";"uncertain")},
      truth_indeterminate: {escalate: count("indeterminate";"escalate"), refuse: count("indeterminate";"refuse"), uncertain: count("indeterminate";"uncertain")}
    },
    abstention_uncertain: (map(select(.observed_verdict == "uncertain")) | length),
    denominators: {
      false_among_escalate_decisions: {
        numerator: (map(select(.truth_eligible == "no" and .observed_verdict == "escalate")) | length),
        denominator: (map(select(.observed_verdict == "escalate")) | length)
      },
      missed_among_truly_eligible: {
        numerator: (map(select(.truth_eligible == "yes" and .observed_verdict != "escalate")) | length),
        denominator: (map(select(.truth_eligible == "yes")) | length)
      }
    },
    per_stratum: (sort_by(.stratum) | group_by(.stratum) | map({
      stratum: .[0].stratum,
      count: length,
      escalate: (map(select(.observed_verdict == "escalate")) | length),
      refuse: (map(select(.observed_verdict == "refuse")) | length),
      uncertain: (map(select(.observed_verdict == "uncertain")) | length)
    })),
    label_mismatches: (map(select(.observed_verdict != .expected_verdict or .observed_reason != .expected_reason)) | map({id, expected_verdict, expected_reason, observed_verdict, observed_reason}))
  }
' "$OBSERVED" >"$REPORT"

stateful_failures=0
write_meta() {
  local id=$1 effort=$2 reservation=${3:-}
  cat >"$LAB_STATE/$id.meta" <<EOF
project=$ROOT
harness=codex
model=gpt-policy
effort=$effort
kind=ship
mode=no-mistakes
spawn_generation=gen-$id
launch_complete_generation=gen-$id
EOF
  [ -z "$reservation" ] || printf 'escalation_reservation=%s\n' "$reservation" >>"$LAB_STATE/$id.meta"
}
write_meta l1-policy-prior medium
run_lab "$CLASSIFIER" classify --id l1-policy-prior --endpoint-alive yes --crew-state working \
  --failure-class capability --same-failure yes --fix-attempts 2 --recovery-exhausted yes --n 2 >/dev/null

if run_lab "$CLASSIFIER" resolve-stronger --from-profile codex/gpt-policy/medium \
  --dispatch "$LAB_CONFIG/no-stronger.json" >/dev/null 2>&1; then
  echo "not ok - no-stronger boundary unexpectedly resolved" >&2
  stateful_failures=$((stateful_failures + 1))
fi

reserve_output=$(run_lab "$CLASSIFIER" escalate l1-policy-prior --target-profile codex/gpt-policy/high \
  --new-id l1-policy-follow --reserve --dispatch "$LAB_CONFIG/crew-dispatch.json")
reservation_id=$(printf '%s\n' "$reserve_output" | awk -F= '$1 == "reservation_id" { print $2 }')
[ -n "$reservation_id" ] || { echo "not ok - reservation identity missing" >&2; exit 1; }
write_meta l1-policy-follow high "$reservation_id"

FAIL_ONCE_OUTCOME="$LAB_HOME/fail-once-outcome.sh"
FAIL_ONCE_MARKER="$LAB_HOME/fail-once-outcome.marker"
cat >"$FAIL_ONCE_OUTCOME" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$FM_FAIL_ONCE_MARKER" ]; then
  : >"$FM_FAIL_ONCE_MARKER"
  exit 1
fi
exec "$FM_REAL_OUTCOME" "$@"
SH
chmod +x "$FAIL_ONCE_OUTCOME"

before_lines=0
[ ! -f "$LAB_OUTCOMES" ] || before_lines=$(wc -l <"$LAB_OUTCOMES" | tr -d ' ')
if FM_TEST_OUTCOME_BIN="$FAIL_ONCE_OUTCOME" FM_FAIL_ONCE_MARKER="$FAIL_ONCE_MARKER" \
  run_lab "$CLASSIFIER" escalate l1-policy-prior --target-profile codex/gpt-policy/high \
  --new-id l1-policy-follow --commit --dispatch "$LAB_CONFIG/crew-dispatch.json" >/dev/null 2>&1; then
  echo "not ok - apply failure boundary unexpectedly succeeded" >&2
  stateful_failures=$((stateful_failures + 1))
fi
after_lines=0
[ ! -f "$LAB_OUTCOMES" ] || after_lines=$(wc -l <"$LAB_OUTCOMES" | tr -d ' ')
[ "$before_lines" = "$after_lines" ] || stateful_failures=$((stateful_failures + 1))
grep -q '^escalated_from=codex/gpt-policy/medium$' "$LAB_STATE/l1-policy-prior.meta" || stateful_failures=$((stateful_failures + 1))
grep -q '^escalated_from=codex/gpt-policy/medium$' "$LAB_STATE/l1-policy-follow.meta" || stateful_failures=$((stateful_failures + 1))
[ "$(grep -c '^escalated_from=' "$LAB_STATE/l1-policy-prior.meta")" -eq 1 ] || stateful_failures=$((stateful_failures + 1))
[ -f "$LAB_STATE/.l1-policy-prior.stuck-escalate.pending" ] || stateful_failures=$((stateful_failures + 1))
[ -f "$LAB_STATE/.l1-policy-follow.stuck-escalation-reservation" ] || stateful_failures=$((stateful_failures + 1))

run_lab "$CLASSIFIER" escalate l1-policy-prior --target-profile codex/gpt-policy/high \
  --new-id l1-policy-follow --commit --dispatch "$LAB_CONFIG/crew-dispatch.json" >/dev/null
run_lab "$OUTCOME" record l1-policy-follow --outcome 'done' --note 'synthetic terminal follow-on' >/dev/null

linkage_ok=$(jq -s '
  (map(select(.id == "l1-policy-prior" and .outcome == "escalated")) | length) == 1 and
  (map(select(.id == "l1-policy-follow" and .outcome == "done")) | length) == 1 and
  (map(select(.id == "l1-policy-follow" and (.outcome == "done" or .outcome == "failed" or .outcome == "blocked"))) | length) == 1
' "$LAB_OUTCOMES")
[ "$linkage_ok" = true ] || stateful_failures=$((stateful_failures + 1))
grep -q '^escalated_from=codex/gpt-policy/medium$' "$LAB_STATE/l1-policy-prior.meta" || stateful_failures=$((stateful_failures + 1))
grep -q '^escalated_from=codex/gpt-policy/medium$' "$LAB_STATE/l1-policy-follow.meta" || stateful_failures=$((stateful_failures + 1))

outcome_lines=$(wc -l <"$LAB_OUTCOMES" | tr -d ' ')
if run_lab "$CLASSIFIER" escalate l1-policy-prior --target-profile codex/gpt-policy/high \
  --new-id l1-policy-second --reserve --dispatch "$LAB_CONFIG/crew-dispatch.json" >/dev/null 2>&1; then
  echo "not ok - anti-thrash second apply unexpectedly succeeded" >&2
  stateful_failures=$((stateful_failures + 1))
fi
[ "$(wc -l <"$LAB_OUTCOMES" | tr -d ' ')" = "$outcome_lines" ] || stateful_failures=$((stateful_failures + 1))
[ "$(grep -c '^escalated_from=' "$LAB_STATE/l1-policy-prior.meta")" -eq 1 ] || stateful_failures=$((stateful_failures + 1))

REAL_HOME_AFTER=$(operational_signature "$REAL_HOME")
if [ "$REAL_HOME_BEFORE" != "$REAL_HOME_AFTER" ]; then
  echo "not ok - real-home files changed during the disposable lab run" >&2
  stateful_failures=$((stateful_failures + 1))
fi
OPERATIONAL_ROOT_AFTER=$(operational_signature "$ROOT")
if [ "$OPERATIONAL_ROOT_BEFORE" != "$OPERATIONAL_ROOT_AFTER" ]; then
  echo "not ok - non-lab operational root changed during the disposable lab run" >&2
  stateful_failures=$((stateful_failures + 1))
fi
if [ -s "$PROHIBITED_LOG" ]; then
  echo "not ok - prohibited command invoked during the disposable lab run" >&2
  stateful_failures=$((stateful_failures + 1))
fi

mismatches=$(jq '.label_mismatches | length' "$REPORT")
printf 'Synthetic policy-conformance challenge suite: %s scenarios\n' "$(jq -r '.scenario_count' "$REPORT")"
printf 'confusion_matrix=%s\n' "$(jq -c '.confusion_matrix' "$REPORT")"
printf 'abstention_uncertain=%s\n' "$(jq -r '.abstention_uncertain' "$REPORT")"
printf 'false_among_escalate_decisions=%s/%s\n' \
  "$(jq -r '.denominators.false_among_escalate_decisions.numerator' "$REPORT")" \
  "$(jq -r '.denominators.false_among_escalate_decisions.denominator' "$REPORT")"
printf 'missed_among_truly_eligible=%s/%s\n' \
  "$(jq -r '.denominators.missed_among_truly_eligible.numerator' "$REPORT")" \
  "$(jq -r '.denominators.missed_among_truly_eligible.denominator' "$REPORT")"
jq -r '.per_stratum[] | "stratum=\(.stratum) count=\(.count) escalate=\(.escalate) refuse=\(.refuse) uncertain=\(.uncertain)"' "$REPORT"
printf 'escalation_linkage_integrity=%s\n' "$linkage_ok"
printf 'production_incidence=undefined (synthetic conformance only)\n'

if [ "$mismatches" -ne 0 ] || [ "$stateful_failures" -ne 0 ]; then
  jq -c '.label_mismatches[]' "$REPORT" >&2
  echo "not ok - synthetic policy-conformance challenge suite failed" >&2
  exit 1
fi

echo "ok - synthetic policy-conformance challenge suite passed"
