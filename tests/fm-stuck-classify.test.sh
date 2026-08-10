#!/usr/bin/env bash
# Behavior tests for bin/fm-stuck-classify.sh (pure classify / refuse paths,
# resolve-stronger standing profiles, fail-closed one-step escalate).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLASSIFY="$ROOT/bin/fm-stuck-classify.sh"
OUTCOME="$ROOT/bin/fm-dispatch-outcome.sh"
TMP_ROOT=$(fm_test_tmproot fm-stuck-classify)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
DATA_DIR="$HOME_DIR/data"
CONFIG_DIR="$HOME_DIR/config"
LOG_PATH="$DATA_DIR/dispatch-outcomes.jsonl"
DECISION_LOG_PATH="$DATA_DIR/stuck-classify-decisions.jsonl"
DISPATCH_PATH="$CONFIG_DIR/crew-dispatch.json"
mkdir -p "$STATE_DIR" "$DATA_DIR" "$CONFIG_DIR"

cat >"$DISPATCH_PATH" <<'JSON'
{"rules":[{"when":"complex ship","use":{"harness":"claude","model":"claude-sonnet-5","effort":"high","strength":20}}],"default":{"harness":"codex","model":"gpt-5.5","effort":"medium","strength":10}}
JSON

run_sc() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
    FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_DISPATCH_OUTCOMES="$LOG_PATH" \
    FM_STUCK_CLASSIFY_LOG="${TEST_DECISION_LOG:-$DECISION_LOG_PATH}" \
    FM_DISPATCH_OUTCOME_BIN="${TEST_OUTCOME_BIN:-$OUTCOME}" \
    "$CLASSIFY" "$@"
}

run_sc_default_home() {
  local home=$1 state=$2 config=$3
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$config" FM_DISPATCH_OUTCOME_BIN="$OUTCOME" \
    env -u FM_STUCK_CLASSIFY_LOG -u FM_DATA_OVERRIDE "$CLASSIFY" "${@:4}"
}

write_meta() {
  local id=$1
  shift
  {
    printf 'window=fm-%s\n' "$id"
    printf 'worktree=/tmp/wt-%s\n' "$id"
    printf 'project=/tmp/example/projects/sample-project\n'
    printf 'harness=codex\n'
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
    printf 'model=gpt-5.5\n'
    printf 'effort=medium\n'
    printf 'spawn_generation=gen-%s\n' "$id"
    # optional extra lines
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } >"$STATE_DIR/$id.meta"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$CLASSIFY" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-stuck-classify.sh must parse (got: $out)"
  [ -z "$out" ] || fail "bash -n emitted unexpected output: $out"
  pass "fm-stuck-classify.sh: bash -n succeeds"
}

test_help_renders_header() {
  local help
  help=$(run_sc --help 2>&1) || true
  assert_contains "$help" "No network" "help omitted safety line"
  assert_contains "$help" "FM_STUCK_CLASSIFY_N" "help omitted N threshold env"
  assert_contains "$help" "capability-stuck" "help omitted product intent"
  pass "fm-stuck-classify.sh: help renders header"
}

test_refuse_unknown_command() {
  local err rc
  err=$(run_sc nonsense 2>&1); rc=$?
  expect_code 2 "$rc" "unknown command should exit 2"
  assert_contains "$err" "unknown command" "unknown command should explain"
  pass "fm-stuck-classify.sh: refuses nonsense command"
}

test_classify_refuses_dead_endpoint() {
  local out
  out=$(run_sc classify --endpoint-alive no --failure-class capability \
    --same-failure yes --fix-attempts 5 --recovery-exhausted yes)
  assert_contains "$out" "verdict=refuse" "dead endpoint must refuse"
  assert_contains "$out" "reason=endpoint_not_alive" "dead endpoint reason code"
  pass "fm-stuck-classify.sh: refuses dead endpoint"
}

test_classify_refuses_infra() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class infra --same-failure yes --fix-attempts 5 --recovery-exhausted yes)
  assert_contains "$out" "verdict=refuse" "infra must refuse"
  assert_contains "$out" "reason=infra" "infra reason code"
  pass "fm-stuck-classify.sh: refuses infra class"
}

test_classify_refuses_parked() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state parked \
    --failure-class capability --same-failure yes --fix-attempts 5 --recovery-exhausted yes)
  assert_contains "$out" "verdict=refuse" "parked must refuse"
  assert_contains "$out" "reason=parked_operator" "parked reason code"
  pass "fm-stuck-classify.sh: refuses parked operator gate"
}

test_classify_refuses_declared_pause() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state paused \
    --failure-class declared-pause --fix-attempts 5 --recovery-exhausted yes --same-failure yes)
  assert_contains "$out" "verdict=refuse" "pause must refuse"
  assert_contains "$out" "reason=declared_pause" "pause reason code"
  pass "fm-stuck-classify.sh: refuses declared pause"
}

test_classify_refuses_validation_advancing() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class validation-advancing --same-failure yes \
    --fix-attempts 5 --recovery-exhausted yes)
  assert_contains "$out" "verdict=refuse" "validation advancing must refuse"
  assert_contains "$out" "reason=validation_advancing" "validation reason code"
  pass "fm-stuck-classify.sh: refuses validation still advancing"
}

test_classify_refuses_self_report_only() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class capability --same-failure yes --fix-attempts 5 \
    --recovery-exhausted yes --self-report-only yes)
  assert_contains "$out" "verdict=refuse" "self-report-only must refuse"
  assert_contains "$out" "reason=self_report_only" "self-report reason code"
  pass "fm-stuck-classify.sh: refuses self-report-only (anti-lazy)"
}

test_classify_refuses_already_escalated() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class capability --same-failure yes --fix-attempts 5 \
    --recovery-exhausted yes --already-escalated yes)
  assert_contains "$out" "verdict=refuse" "already escalated must refuse"
  assert_contains "$out" "reason=already_escalated" "already_escalated reason"
  pass "fm-stuck-classify.sh: refuses second escalate (thrash cap)"
}

test_classify_refuses_below_threshold() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class capability --same-failure yes --fix-attempts 1 \
    --recovery-exhausted yes --n 2)
  assert_contains "$out" "verdict=refuse" "below N must refuse"
  assert_contains "$out" "reason=below_threshold" "below_threshold reason"
  assert_contains "$out" "n_threshold=2" "metrics must expose N"
  pass "fm-stuck-classify.sh: refuses below N threshold"
}

test_classify_uncertain_ambiguous() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class ambiguous --fix-attempts 5 --recovery-exhausted yes --same-failure yes)
  assert_contains "$out" "verdict=uncertain" "ambiguous -> uncertain"
  assert_contains "$out" "reason=ambiguous" "ambiguous reason"
  pass "fm-stuck-classify.sh: uncertain on ambiguous class"
}

test_classify_uncertain_unknown_crew_state() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state unknown \
    --failure-class capability --same-failure yes --fix-attempts 5 --recovery-exhausted yes)
  assert_contains "$out" "verdict=uncertain" "unknown crew state must not escalate"
  assert_contains "$out" "reason=unknown_crew_state" "unknown crew state reason"
  pass "fm-stuck-classify.sh: uncertain on unknown durable crew state"
}

test_classify_uncertain_missing_endpoint_evidence() {
  local out
  out=$(run_sc classify --crew-state working --failure-class capability \
    --same-failure yes --fix-attempts 5 --recovery-exhausted yes)
  assert_contains "$out" "verdict=uncertain" "missing endpoint evidence must abstain"
  assert_contains "$out" "reason=missing_endpoint_evidence" "missing endpoint reason"
  pass "fm-stuck-classify.sh: uncertain when endpoint evidence is missing"
}

test_classify_refuses_external_wait() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class external-wait --same-failure yes --fix-attempts 5 --recovery-exhausted yes)
  assert_contains "$out" "verdict=refuse" "external wait must refuse"
  assert_contains "$out" "reason=external_wait" "external wait reason"
  pass "fm-stuck-classify.sh: emits reachable external-wait reason"
}

test_classify_escalates_capability_stuck() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class capability --same-failure yes --fix-attempts 2 \
    --recovery-exhausted yes --already-escalated no --n 2)
  assert_contains "$out" "verdict=escalate" "capability stuck should escalate"
  assert_contains "$out" "reason=capability_stuck" "capability_stuck reason"
  assert_contains "$out" "fix_attempts=2" "metrics fix_attempts"
  pass "fm-stuck-classify.sh: escalates capability stuck at N=2"
}

test_classify_uncertain_without_escalation_history() {
  local out
  out=$(run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class capability --same-failure yes --fix-attempts 2 \
    --recovery-exhausted yes --n 2)
  assert_contains "$out" "verdict=uncertain" "missing anti-thrash evidence must abstain"
  assert_contains "$out" "reason=missing_escalation_history" "missing anti-thrash reason"
  pass "fm-stuck-classify.sh: missing anti-thrash evidence is uncertain"
}

test_classify_json_shape() {
  local out
  out=$(run_sc classify --json --endpoint-alive no)
  assert_contains "$out" '"verdict":"refuse"' "json verdict"
  assert_contains "$out" '"reason":"endpoint_not_alive"' "json reason"
  assert_contains "$out" '"n_threshold":' "json n_threshold for metrics"
  pass "fm-stuck-classify.sh: --json emits metrics fields"
}

test_classify_appends_decision_schema() {
  local log="$TMP_ROOT/classify-schema.jsonl" line
  : >"$log"
  TEST_DECISION_LOG="$log" run_sc classify --id decision1 \
    --endpoint-alive yes --crew-state working --failure-class capability \
    --same-failure yes --fix-attempts 3 --recovery-exhausted yes \
    --self-report-only no --already-escalated no --n 2 >/dev/null
  [ -f "$log" ] || fail "classify decision log was not created"
  [ "$(wc -l <"$log" | tr -d ' ')" = 1 ] || fail "classify must append exactly one JSON line"
  line=$(tail -n 1 "$log")
  printf '%s\n' "$line" | jq -e '
    (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.decision_id | type) == "string" and (.decision_id | length) > 0 and
    .id == "decision1" and .generation == "" and .endpoint_alive == "yes" and .crew_state == "working" and
    .failure_class == "capability" and .same_failure == "yes" and .fix_attempts == 3 and
    .n_threshold == 2 and .recovery_exhausted == "yes" and .self_report_only == "no" and
    .already_escalated == "no" and .verdict == "escalate" and
    .reason == "capability_stuck" and (.detail | length > 0)
  ' >/dev/null || fail "classify decision log omitted required evidence or decision fields"
  pass "fm-stuck-classify.sh: appends complete classify decision schema"
}

test_classify_log_never_rewrites_prior_lines() {
  local log="$TMP_ROOT/classify-append.jsonl" first='{"sentinel":"prior"}' inode_before inode_after
  printf '%s\n' "$first" >"$log"
  if [ "$(uname)" = Darwin ]; then
    inode_before=$(stat -f '%i' "$log")
  else
    inode_before=$(stat -c '%i' "$log")
  fi
  TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no >/dev/null
  TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive yes --crew-state working \
    --failure-class infra >/dev/null
  [ "$(wc -l <"$log" | tr -d ' ')" = 3 ] || fail "classify log must preserve and append one line per call"
  [ "$(head -n 1 "$log")" = "$first" ] || fail "classify log rewrote a prior line"
  if [ "$(uname)" = Darwin ]; then
    inode_after=$(stat -f '%i' "$log")
  else
    inode_after=$(stat -c '%i' "$log")
  fi
  [ "$inode_after" = "$inode_before" ] || fail "classify append replaced the decision-log inode"
  pass "fm-stuck-classify.sh: decision log is append-only"
}

test_classify_log_repairs_missing_final_newline() {
  local log="$TMP_ROOT/classify-no-final-newline.jsonl"
  printf '%s' '{"sentinel":"prior"}' >"$log"
  TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no >/dev/null
  jq -s -e 'length == 2 and .[0].sentinel == "prior" and .[1].reason == "endpoint_not_alive"' \
    "$log" >/dev/null || fail "classify log must keep JSONL records separate"
  pass "fm-stuck-classify.sh: missing final newline is repaired before append"
}

test_classify_log_recovers_pending_after_missing_final_newline() {
  local log="$TMP_ROOT/classify-pending-no-final-newline.jsonl" payload dev ino start out rc
  printf '%s' '{"sentinel":"prior"}' >"$log"
  if [ "$(uname)" = Darwin ]; then
    read -r dev ino <<<"$(stat -f '%d %i' "$log")"
  else
    read -r dev ino <<<"$(stat -c '%d %i' "$log")"
  fi
  start=$(wc -c <"$log" | tr -d ' ')
  payload=$'\n{"sentinel":"pending"}\n'
  printf '%s\n%s\n%s\n%s' "$dev" "$ino" "$start" "$payload" >"$log.pending"
  printf '%s' "$payload" >>"$log"
  out=$(TEST_DECISION_LOG="$log" run_sc classify --id pending-recovery --endpoint-alive no 2>&1); rc=$?
  expect_code 0 "$rc" "pending no-newline recovery must preserve classify success"
  assert_not_contains "$out" "decision log append failed" "pending no-newline recovery must not block logging"
  jq -s -e 'length == 3 and .[0].sentinel == "prior" and .[1].sentinel == "pending" and .[2].id == "pending-recovery"' \
    "$log" >/dev/null || fail "pending no-newline recovery lost or reordered decision records"
  [ ! -e "$log.pending" ] || fail "recovered pending marker remained"
  pass "fm-stuck-classify.sh: pending recovery accepts a no-newline prefix"
}

test_classify_log_replays_partial_pending_payload() {
  local log="$TMP_ROOT/classify-partial-pending.jsonl" payload dev ino start
  printf '%s\n' '{"sentinel":"prior"}' >"$log"
  if [ "$(uname)" = Darwin ]; then
    read -r dev ino <<<"$(stat -f '%d %i' "$log")"
  else
    read -r dev ino <<<"$(stat -c '%d %i' "$log")"
  fi
  start=$(wc -c <"$log" | tr -d ' ')
  payload=$'{"sentinel":"replayed"}\n'
  printf '%s\n%s\n%s\n%s' "$dev" "$ino" "$start" "$payload" >"$log.pending"
  printf '%s' "${payload:0:9}" >>"$log"
  TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no >/dev/null
  jq -s -e 'length == 3 and .[0].sentinel == "prior" and .[1].sentinel == "replayed" and .[2].reason == "endpoint_not_alive"' \
    "$log" >/dev/null || fail "partial pending decision payload was not replayed"
  [ ! -e "$log.pending" ] || fail "partial pending replay left its journal"
  pass "fm-stuck-classify.sh: partial pending decisions replay before append"
}

test_classify_log_rejects_malformed_existing_stream() {
  local log="$TMP_ROOT/classify-malformed-stream.jsonl" out
  printf '%s\n' '{"sentinel":"prior"}' 'not-json' >"$log"
  out=$(TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "decision log append failed" "malformed JSONL must fail softly"
  [ "$(tail -n 1 "$log")" = 'not-json' ] || fail "malformed JSONL was rewritten"
  printf '%s' 'not-json' >"$log"
  out=$(TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "decision log append failed" "unterminated malformed JSONL must fail softly"
  [ "$(cat "$log")" = 'not-json' ] || fail "unterminated malformed JSONL was truncated"
  printf '%s\n' '{"sentinel":"prior"}' '' >"$log"
  out=$(TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "decision log append failed" "blank JSONL records must fail softly"
  [ "$(wc -l <"$log" | tr -d ' ')" = 2 ] || fail "blank JSONL record was removed"
  pass "fm-stuck-classify.sh: malformed existing JSONL is rejected"
}

test_classify_log_serializes_concurrent_appends() {
  local log="$TMP_ROOT/classify-concurrent.jsonl" pids='' pid
  local i
  for i in 1 2 3 4 5 6 7 8; do
    TEST_DECISION_LOG="$log" run_sc classify --id "concurrent-$i" --endpoint-alive no >/dev/null 2>&1 &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || fail "concurrent classify call failed"
  done
  jq -s -e 'length == 8 and (map(.id) | unique | length == 8) and all(.[]; .reason == "endpoint_not_alive")' "$log" >/dev/null \
    || fail "concurrent classify appends must remain complete JSONL records"
  pass "fm-stuck-classify.sh: concurrent decision appends remain serialized"
}

test_classify_gold_cases_append_unique_records() {
  local log="$TMP_ROOT/classify-gold-unique.jsonl"
  TEST_DECISION_LOG="$log" run_sc classify --id gold-refuse --endpoint-alive no >/dev/null
  TEST_DECISION_LOG="$log" run_sc classify --id gold-uncertain --endpoint-alive yes \
    --crew-state unknown >/dev/null
  TEST_DECISION_LOG="$log" run_sc classify --id gold-escalate --endpoint-alive yes \
    --crew-state working --failure-class capability --same-failure yes --fix-attempts 2 \
    --recovery-exhausted yes --already-escalated no >/dev/null
  TEST_DECISION_LOG="$log" run_sc classify --id gold-json --json --endpoint-alive no >/dev/null
  jq -s -e 'length == 4 and (map(.id) | unique | length == 4) and
    ((map(.id) | sort) == ["gold-escalate", "gold-json", "gold-refuse", "gold-uncertain"])' \
    "$log" >/dev/null || fail "gold classify calls must append one unique record each"
  pass "fm-stuck-classify.sh: gold classify calls append unique records"
}

test_classify_log_rejects_unsafe_targets() {
  local outside="$TMP_ROOT/classify-outside" nested_parent="$TMP_ROOT/classify-nested/data" linked_parent="$TMP_ROOT/classify-linked-parent" fifo="$TMP_ROOT/classify-fifo" out
  mkdir -p "$outside"
  ln -s "$outside" "$linked_parent"
  out=$(TEST_DECISION_LOG="$linked_parent/decisions.jsonl" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "decision log append failed" "symlinked decision-log parent must fail softly"
  [ ! -e "$outside/decisions.jsonl" ] || fail "symlinked decision-log parent redirected a write"
  mkdir -p "$nested_parent"
  ln -s "$outside" "$nested_parent/link"
  out=$(TEST_DECISION_LOG="$nested_parent/link/new/decisions.jsonl" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "decision log append failed" "symlinked decision-log ancestor must fail softly"
  [ ! -e "$outside/new/decisions.jsonl" ] || fail "symlinked decision-log ancestor redirected a write"
  mkfifo "$fifo"
  out=$(TEST_DECISION_LOG="$fifo" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "decision log append failed" "FIFO decision log must fail softly"
  pass "fm-stuck-classify.sh: unsafe decision-log targets are rejected"
}

test_classify_log_rejects_external_lock_symlink() {
  local log="$TMP_ROOT/classify-external-lock.jsonl" outside="$TMP_ROOT/external-lock" out
  mkdir -p "$outside"
  printf '999999\n' >"$outside/pid"
  ln -s "$outside" "$log.lock"
  out=$(TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "decision log append failed" "external lock symlink must fail softly"
  [ "$(cat "$outside/pid")" = 999999 ] || fail "external lock metadata was modified"
  [ ! -e "$log" ] || fail "external lock symlink allowed a decision-log write"
  pass "fm-stuck-classify.sh: external lock symlinks are rejected"
}

test_classify_log_recovers_stale_lock_directories() {
  local log="$TMP_ROOT/classify-stale-lock.jsonl" lock="$TMP_ROOT/classify-stale-lock.jsonl.lock"
  local owner_log="$TMP_ROOT/classify-missing-owner.jsonl" owner_lock="$TMP_ROOT/classify-missing-owner.jsonl.lock"
  local owner="$TMP_ROOT/classify-missing-owner.jsonl.lock.owner.fixture" out
  printf '%s\n' '{"sentinel":"prior"}' >"$log"
  mkdir "$lock"
  touch -t 200001010000 "$lock" 2>/dev/null || fail "could not age stale decision lock directory"
  out=$(FM_LOCK_STALE_AFTER=0 TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no 2>&1)
  assert_not_contains "$out" "decision log append failed" "stale decision lock directory must be reclaimed"
  jq -s -e 'length == 2 and .[0].sentinel == "prior" and .[1].reason == "endpoint_not_alive"' \
    "$log" >/dev/null || fail "stale decision lock directory blocked append"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "stale decision lock directory remained"

  printf '%s\n' '{"sentinel":"prior"}' >"$owner_log"
  mkdir "$owner"
  touch -t 200001010000 "$owner" 2>/dev/null || fail "could not age missing-owner directory"
  ln -s "$owner" "$owner_lock"
  rm -rf "$owner"
  out=$(FM_LOCK_STALE_AFTER=0 TEST_DECISION_LOG="$owner_log" run_sc classify --endpoint-alive no 2>&1)
  assert_not_contains "$out" "decision log append failed" "stale missing-owner lock must be reclaimed"
  jq -s -e 'length == 2 and .[0].sentinel == "prior" and .[1].reason == "endpoint_not_alive"' \
    "$owner_log" >/dev/null || fail "stale missing-owner lock blocked append"
  [ ! -e "$owner_lock" ] && [ ! -L "$owner_lock" ] || fail "stale missing-owner lock remained"
  pass "fm-stuck-classify.sh: stale lock directories reach shared recovery"
}

test_classify_relative_log_path_is_canonicalized() {
  local parent="$TMP_ROOT/classify-relative-parent" log="$TMP_ROOT/classify-relative-parent/../classify-relative.jsonl"
  local output="$TMP_ROOT/classify-relative.out" rc_file="$TMP_ROOT/classify-relative.rc" out rc pid i
  mkdir -p "$parent"
  (
    TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no >"$output" 2>&1
    printf '%s\n' "$?" >"$rc_file"
  ) &
  pid=$!
  i=0
  while [ ! -f "$rc_file" ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -f "$rc_file" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "relative decision-log path did not finish promptly"
  fi
  wait "$pid" 2>/dev/null || true
  rc=$(cat "$rc_file")
  out=$(cat "$output")
  expect_code 0 "$rc" "relative decision-log path must classify successfully"
  assert_not_contains "$out" "decision log append failed" "relative decision-log path must append"
  jq -e '.reason == "endpoint_not_alive"' "$TMP_ROOT/classify-relative.jsonl" >/dev/null \
    || fail "relative decision-log path did not append a valid record"
  pass "fm-stuck-classify.sh: relative decision-log paths are bounded and canonical"
}

test_classify_log_rejects_hardlinked_target() {
  local log="$TMP_ROOT/classify-hardlink.jsonl" alias="$TMP_ROOT/classify-hardlink-alias.jsonl" out
  printf '%s\n' '{"sentinel":"prior"}' >"$log"
  ln "$log" "$alias"
  out=$(TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "decision log append failed" "hard-linked decision log must fail softly"
  [ "$(cat "$log")" = '{"sentinel":"prior"}' ] || fail "hard-linked decision log changed"
  [ "$(cat "$alias")" = '{"sentinel":"prior"}' ] || fail "hard-linked alias changed"
  pass "fm-stuck-classify.sh: hard-linked decision logs are rejected"
}

test_classify_log_rejects_corrupt_lock_fifo() {
  local log="$TMP_ROOT/classify-corrupt-lock.jsonl" lock="$TMP_ROOT/classify-corrupt-lock.jsonl.lock" out
  mkdir -p "$lock"
  mkfifo "$lock/pid"
  out=$(TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "decision log append failed" "corrupt lock FIFO must fail softly"
  pass "fm-stuck-classify.sh: corrupt lock FIFO cannot block classify"
}

test_classify_logging_failure_is_soft() {
  local unwritable="$TMP_ROOT/log-is-directory" out rc
  mkdir -p "$unwritable"
  out=$(TEST_DECISION_LOG="$unwritable" run_sc classify --endpoint-alive no 2>&1); rc=$?
  expect_code 0 "$rc" "decision log failure must not change classify success"
  assert_contains "$out" "verdict=refuse" "decision must still be returned when logging fails"
  assert_contains "$out" "decision log append failed" "logging failure must be clear on stderr"
  pass "fm-stuck-classify.sh: decision log failure is soft"
}

test_classify_unwritable_log_parent_fails_softly() {
  local parent="$TMP_ROOT/classify-unwritable-parent" log="$TMP_ROOT/classify-unwritable-parent/decisions.jsonl"
  local output="$TMP_ROOT/classify-unwritable.out" rc_file="$TMP_ROOT/classify-unwritable.rc" out rc pid i
  mkdir -p "$parent"
  chmod 555 "$parent" || fail "could not make decision-log parent unwritable"
  (
    TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no >"$output" 2>&1
    printf '%s\n' "$?" >"$rc_file"
  ) &
  pid=$!
  i=0
  while [ ! -f "$rc_file" ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -f "$rc_file" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "unwritable decision-log parent did not fail promptly"
  fi
  wait "$pid" 2>/dev/null || true
  rc=$(cat "$rc_file")
  out=$(cat "$output")
  expect_code 0 "$rc" "unwritable decision-log parent must preserve classify success"
  assert_contains "$out" "verdict=refuse" "decision must still be returned when parent is unwritable"
  assert_contains "$out" "decision log append failed" "unwritable decision-log parent must fail softly"
  [ ! -e "$log" ] || fail "unwritable decision-log parent unexpectedly received a record"
  pass "fm-stuck-classify.sh: unwritable decision-log parents fail softly"
}

test_classify_logging_can_be_disabled() {
  local pure_home="$TMP_ROOT/classify-disabled-home" out
  out=$(FM_HOME="$pure_home" FM_STUCK_CLASSIFY_LOG=off \
    "$CLASSIFY" classify --endpoint-alive yes --crew-state unknown)
  assert_contains "$out" "reason=unknown_crew_state" "disabled logging must preserve pure decision"
  [ ! -e "$pure_home" ] || fail "disabled classify logging unexpectedly created home data"
  pass "fm-stuck-classify.sh: logging can be disabled for decision-only callers"
}

test_classify_normalizes_json_numbers() {
  local log="$TMP_ROOT/classify-normalized-numbers.jsonl" out
  out=$(TEST_DECISION_LOG="$log" run_sc classify --json --endpoint-alive yes --crew-state working \
    --failure-class capability --same-failure yes --fix-attempts 08 --n 02 \
    --recovery-exhausted yes)
  assert_contains "$out" '"fix_attempts":8' "classify output must normalize leading-zero fix attempts"
  assert_contains "$out" '"n_threshold":2' "classify output must normalize leading-zero threshold"
  jq -e '.fix_attempts == 8 and .n_threshold == 2' "$log" >/dev/null \
    || fail "decision log must contain valid normalized JSON numbers"
  pass "fm-stuck-classify.sh: JSON numeric metrics are normalized"
}

test_classify_rejects_invalid_timestamp_output() {
  local fakebin="$TMP_ROOT/classify-fake-date" log="$TMP_ROOT/classify-invalid-date.jsonl" out
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fakebin/date"
  chmod +x "$fakebin/date"
  out=$(PATH="$fakebin:$PATH" TEST_DECISION_LOG="$log" run_sc classify --endpoint-alive no 2>&1)
  assert_contains "$out" "UTC timestamp unavailable" "invalid timestamp must fail logging softly"
  assert_contains "$out" "verdict=refuse" "invalid timestamp must not change classification"
  [ ! -e "$log" ] || fail "invalid timestamp must not append a malformed record"
  pass "fm-stuck-classify.sh: invalid UTC timestamps fail softly"
}

test_classify_default_log_uses_active_data_and_isolates_homes() {
  local home_a="$TMP_ROOT/default-a" home_b="$TMP_ROOT/default-b"
  local data_a="$home_a/data" data_b="$home_b/data"
  local state_a="$home_a/state" state_b="$home_b/state"
  local config_a="$home_a/config" config_b="$home_b/config"
  mkdir -p "$state_a" "$state_b" "$config_a" "$config_b"
  run_sc_default_home "$home_a" "$state_a" "$config_a" classify --id home-a --endpoint-alive no >/dev/null
  run_sc_default_home "$home_b" "$state_b" "$config_b" classify --id home-b --endpoint-alive no >/dev/null
  [ -f "$data_a/stuck-classify-decisions.jsonl" ] || fail "default log ignored FM_DATA_OVERRIDE for home A"
  [ -f "$data_b/stuck-classify-decisions.jsonl" ] || fail "default log ignored FM_DATA_OVERRIDE for home B"
  jq -e '.id == "home-a"' "$data_a/stuck-classify-decisions.jsonl" >/dev/null || fail "home A decision log mixed records"
  jq -e '.id == "home-b"' "$data_b/stuck-classify-decisions.jsonl" >/dev/null || fail "home B decision log mixed records"
  pass "fm-stuck-classify.sh: default logs follow active data and stay isolated"
}

test_classify_default_log_accepts_symlinked_active_home() {
  local target="$TMP_ROOT/symlinked-active-home-target" link="$TMP_ROOT/symlinked-active-home"
  mkdir -p "$target/state" "$target/config"
  ln -s "$target" "$link"
  run_sc_default_home "$link" "$target/state" "$target/config" classify --id symlink-home --endpoint-alive no >/dev/null
  [ -f "$target/data/stuck-classify-decisions.jsonl" ] || fail "symlinked active home lost its default decision log"
  jq -e '.id == "symlink-home" and .reason == "endpoint_not_alive"' \
    "$target/data/stuck-classify-decisions.jsonl" >/dev/null || fail "symlinked active home log was malformed"
  pass "fm-stuck-classify.sh: absolute symlinked active homes resolve safely"
}

test_classify_has_no_state_side_effect() {
  local isolated_state="$TMP_ROOT/pure-state" out
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$isolated_state" FM_STUCK_CLASSIFY_LOG=off \
    "$CLASSIFY" classify --endpoint-alive yes --crew-state unknown 2>&1)
  assert_contains "$out" "reason=unknown_crew_state" "pure classify should still classify evidence"
  [ ! -e "$isolated_state" ] || fail "classify must not create the state directory"
  pass "fm-stuck-classify.sh: disabled logging retains no-state-I/O semantics"
}

test_classify_reads_already_escalated_from_meta() {
  write_meta prior1 "escalated_from=claude/haiku/low"
  local out
  out=$(run_sc classify --id prior1 --endpoint-alive yes --crew-state working \
    --failure-class capability --same-failure yes --fix-attempts 5 --recovery-exhausted yes)
  assert_contains "$out" "verdict=refuse" "meta escalated_from must refuse"
  assert_contains "$out" "reason=already_escalated" "meta-driven already_escalated"
  assert_contains "$out" "already_escalated=yes" "metrics flag"
  pass "fm-stuck-classify.sh: --id reads escalated_from from meta"
}

test_resolve_stronger_from_standing_fixture() {
  local out rc
  out=$(run_sc resolve-stronger --from-profile codex/gpt-5.5/medium \
    --dispatch "$DISPATCH_PATH"); rc=$?
  expect_code 0 "$rc" "resolve-stronger should find next-strength target"
  assert_contains "$out" "verdict=ok" "resolve ok"
  assert_contains "$out" "target_profile=" "target profile present"
  assert_contains "$out" "from_profile=codex/gpt-5.5/medium" "from profile echoed"
  assert_contains "$out" "from_strength=10" "source strength present"
  assert_contains "$out" "target_strength=20" "target strength present"
  pass "fm-stuck-classify.sh: resolve-stronger picks the next explicit strength"
}

test_resolve_stronger_uses_explicit_strength_only() {
  local dispatch="$TMP_ROOT/equal-strength-dispatch.json" out err rc
  out=$(run_sc resolve-stronger --from-profile codex/gpt-5.5/medium --dispatch "$DISPATCH_PATH")
  assert_contains "$out" "target_profile=claude/claude-sonnet-5/high" \
    "explicit next strength must select its standing profile"
  printf '%s\n' '{"rules":[{"when":"peer","use":{"harness":"claude","model":"claude-sonnet-5","effort":"high","strength":20}}],"default":{"harness":"codex","model":"gpt-5.5","effort":"high","strength":20}}' >"$dispatch"
  err=$(run_sc resolve-stronger --from-profile claude/claude-sonnet-5/high \
    --dispatch "$dispatch" 2>&1); rc=$?
  expect_code 1 "$rc" "equal-strength peer must not count as stronger"
  assert_contains "$err" "no_stronger_standing" "equal-strength refusal should be explicit"
  pass "fm-stuck-classify.sh: resolve-stronger requires strictly greater public strength"
}

test_resolve_stronger_preserves_optional_and_slash_profiles() {
  local dispatch="$TMP_ROOT/optional-dispatch.json" out
  printf '%s\n' '{"rules":[{"when":"complex ship","use":{"harness":"pi","model":"anthropic/claude-sonnet-5","strength":20}}],"default":{"harness":"codex","model":"gpt-5.5","effort":"medium","strength":10}}' >"$dispatch"
  out=$(run_sc resolve-stronger --from-profile codex/gpt-5.5/medium --dispatch "$dispatch")
  assert_contains "$out" "target_profile=pi/anthropic/claude-sonnet-5" \
    "optional fields and slash-containing models must round-trip"
  pass "fm-stuck-classify.sh: preserves optional and slash-containing profiles"
}

test_resolve_stronger_accepts_default_only_dispatch() {
  local dispatch="$TMP_ROOT/default-only-dispatch.json" err rc
  printf '%s\n' '{"default":{"harness":"codex","model":"gpt-5.5","effort":"medium","strength":10}}' >"$dispatch"
  err=$(run_sc resolve-stronger --from-profile codex/gpt-5.5/medium --dispatch "$dispatch" 2>&1); rc=$?
  expect_code 1 "$rc" "default-only dispatch should reach normal no-stronger handling"
  assert_contains "$err" "no_stronger_standing" "default-only config must not fail schema validation"
  pass "fm-stuck-classify.sh: canonical validator accepts default-only dispatch"
}

test_resolve_stronger_refuses_out_of_range_strength() {
  local dispatch="$TMP_ROOT/out-of-range-strength.json" err rc
  printf '%s\n' '{"rules":[{"when":"strong","use":{"harness":"claude","strength":2147483648}}],"default":{"harness":"codex","strength":1}}' >"$dispatch"
  err=$(run_sc resolve-stronger --from-profile codex --dispatch "$dispatch" 2>&1); rc=$?
  expect_code 2 "$rc" "out-of-range strength must fail validation"
  assert_contains "$err" "invalid dispatch profiles" "strength range refusal should be explicit"
  pass "fm-stuck-classify.sh: public strength stays in portable integer range"
}

test_resolve_stronger_refuses_missing_dispatch() {
  local err rc
  err=$(run_sc resolve-stronger --from-profile codex/gpt-5.5/medium \
    --dispatch "$TMP_ROOT/missing.json" 2>&1); rc=$?
  expect_code 2 "$rc" "missing dispatch should exit 2"
  assert_contains "$err" "not found" "missing dispatch explains"
  pass "fm-stuck-classify.sh: resolve-stronger refuses missing dispatch"
}

write_strong_meta() {
  local id=$1 reservation=$2 harness=${3:-claude} model=${4:-claude-sonnet-5} effort=${5:-high}
  cat >"$STATE_DIR/$id.meta" <<EOF
window=fm-$id
worktree=/tmp/wt-$id
project=/tmp/example/projects/sample-project
harness=$harness
kind=ship
mode=no-mistakes
model=$model
effort=$effort
spawn_generation=gen-$id
launch_complete_generation=gen-$id
escalation_reservation=$reservation
EOF
}

log_escalate_decision() {
  local id=$1
  run_sc classify --id "$id" --endpoint-alive yes --crew-state working \
    --failure-class capability --same-failure yes --fix-attempts 2 \
    --recovery-exhausted yes --n 2 >/dev/null
}

test_escalate_reserves_then_commits_linkage() {
  write_meta cheap1
  local out rc reservation
  out=$(run_sc escalate cheap1 --target-profile claude/claude-sonnet-5/high \
    --note "same test red after 2 rounds" --dry-run); rc=$?
  expect_code 0 "$rc" "dry-run escalate should succeed"
  assert_contains "$out" "verdict=dry-run" "dry-run verdict"
  assert_contains "$out" "prior_profile=codex/gpt-5.5/medium" "prior from meta"
  assert_contains "$out" "target_profile=claude/claude-sonnet-5/high" "target"
  assert_contains "$out" "metrics.thrash_cap=one_step" "metrics thrash cap"
  [ ! -f "$LOG_PATH" ] || [ ! -s "$LOG_PATH" ] \
    || fail "dry-run must not write outcome log"

  log_escalate_decision cheap1
  out=$(run_sc escalate cheap1 --target-profile claude/claude-sonnet-5/high \
    --new-id strong1 --reserve --note "same test red after 2 rounds"); rc=$?
  expect_code 0 "$rc" "reserve should succeed before follow-on spawn"
  assert_contains "$out" "verdict=reserved" "reserve verdict"
  [ -f "$STATE_DIR/.cheap1.stuck-escalate.pending" ] || fail "reserve must persist pending linkage"
  assert_not_contains "$(cat "$STATE_DIR/cheap1.meta")" "escalated_from=" \
    "reserve must not mark prior before follow-on spawn"
  [ ! -f "$LOG_PATH" ] || [ ! -s "$LOG_PATH" ] || fail "reserve must not record an ending"

  reservation=$(printf '%s\n' "$out" | awk -F= '$1 == "reservation_id" { print $2 }')
  write_strong_meta strong1 "$reservation"
  out=$(run_sc escalate cheap1 --target-profile claude/claude-sonnet-5/high \
    --new-id strong1 --commit); rc=$?
  expect_code 0 "$rc" "commit should succeed after matching follow-on spawn"
  assert_contains "$out" "verdict=escalated" "escalated verdict"
  [ -f "$LOG_PATH" ] || fail "outcome log should exist after escalate"
  assert_contains "$(cat "$LOG_PATH")" '"outcome":"escalated"' "log outcome escalated"
  assert_contains "$(cat "$LOG_PATH")" 'stuck_classify escalate' "metrics note in log"
  assert_contains "$(cat "$STATE_DIR/cheap1.meta")" "escalated_from=codex/gpt-5.5/medium" \
    "prior meta must carry durable escalation marker"
  assert_contains "$(cat "$STATE_DIR/strong1.meta")" "escalated_from=codex/gpt-5.5/medium" \
    "follow-on meta must carry durable linkage"
  out=$(run_sc escalate cheap1 --target-profile claude/claude-sonnet-5/high \
    --new-id strong1 --reserve 2>&1); rc=$?
  expect_code 2 "$rc" "marked prior must refuse a second escalation"
  assert_contains "$out" "already_escalated" "prior marker must enforce thrash cap"
  pass "fm-stuck-classify.sh: reserve-before-spawn and commit-after-spawn link escalation"
}

test_escalate_rejects_mismatched_follow_on_profile() {
  write_meta cheap2
  log_escalate_decision cheap2
  local err rc reserve reservation
  reserve=$(run_sc escalate cheap2 --target-profile claude/claude-sonnet-5/high \
    --new-id strong2 --reserve)
  reservation=$(printf '%s\n' "$reserve" | awk -F= '$1 == "reservation_id" { print $2 }')
  write_strong_meta strong2 "$reservation" codex gpt-5.5 high
  err=$(run_sc escalate cheap2 --target-profile claude/claude-sonnet-5/high \
    --new-id strong2 --commit 2>&1); rc=$?
  expect_code 2 "$rc" "mismatched follow-on profile must refuse"
  assert_contains "$err" "does not match --target-profile" "profile mismatch should explain refusal"
  assert_not_contains "$(cat "$STATE_DIR/cheap2.meta")" "escalated_from=" \
    "profile mismatch must not mutate prior linkage"
  pass "fm-stuck-classify.sh: commit verifies follow-on harness model and effort"
}

test_escalate_refuses_arbitrary_target() {
  write_meta cheap4
  log_escalate_decision cheap4
  local err rc
  err=$(run_sc escalate cheap4 --target-profile grok/grok-4.5/high \
    --new-id strong4 --reserve 2>&1); rc=$?
  expect_code 2 "$rc" "non-resolved target must refuse"
  assert_contains "$err" "resolved stronger standing profile" "arbitrary target explains refusal"
  assert_not_contains "$(cat "$STATE_DIR/cheap4.meta")" "escalated_from=" \
    "refused target must not write an audit marker"
  pass "fm-stuck-classify.sh: refuses arbitrary non-standing target"
}

test_escalate_requires_reservation_before_commit() {
  write_meta cheap5
  local before after err rc
  before=$(wc -l <"$LOG_PATH" 2>/dev/null || printf '0')
  err=$(run_sc escalate cheap5 --target-profile claude/claude-sonnet-5/high \
    --new-id missing5 --commit 2>&1); rc=$?
  after=$(wc -l <"$LOG_PATH" 2>/dev/null || printf '0')
  expect_code 2 "$rc" "missing new meta must refuse"
  assert_contains "$err" "no reserved escalation" "missing reservation explains refusal"
  [ "$before" = "$after" ] || fail "missing new meta must not record an escalated outcome"
  assert_not_contains "$(cat "$STATE_DIR/cheap5.meta")" "escalated_from=" \
    "preflight refusal must not write the prior marker"
  pass "fm-stuck-classify.sh: commit requires a prior reservation"
}

test_escalate_requires_durable_escalate_decision() {
  write_meta unbound1
  local err rc
  err=$(run_sc escalate unbound1 --target-profile claude/claude-sonnet-5/high \
    --new-id unbound1-new --reserve 2>&1); rc=$?
  expect_code 2 "$rc" "reservation without a classify decision must refuse"
  assert_contains "$err" "latest durable classify decision" "decision binding refusal should explain"
  [ ! -e "$STATE_DIR/.unbound1.stuck-escalate.pending" ] || fail "unbound reserve wrote a pending record"
  pass "fm-stuck-classify.sh: reserve requires a durable escalate decision"
}

test_escalate_claims_new_id_globally() {
  write_meta claim1
  write_meta claim2
  log_escalate_decision claim1
  log_escalate_decision claim2
  run_sc escalate claim1 --target-profile claude/claude-sonnet-5/high \
    --new-id globally-claimed --reserve >/dev/null
  local err rc
  err=$(run_sc escalate claim2 --target-profile claude/claude-sonnet-5/high \
    --new-id globally-claimed --reserve 2>&1); rc=$?
  expect_code 2 "$rc" "a second prior task must not claim the same follow-on id"
  assert_contains "$err" "different escalation transaction" "global new-id claim refusal should explain"
  pass "fm-stuck-classify.sh: follow-on ids bind to one escalation transaction"
}

test_escalate_recovers_pending_transaction() {
  write_meta atomic1
  log_escalate_decision atomic1
  local failing="$TMP_ROOT/failing-outcome.sh" err rc out reserve reservation
  printf '#!/usr/bin/env bash\nexit 1\n' >"$failing"
  chmod +x "$failing"
  reserve=$(run_sc escalate atomic1 --target-profile claude/claude-sonnet-5/high \
    --new-id atomic1-new --reserve)
  reservation=$(printf '%s\n' "$reserve" | awk -F= '$1 == "reservation_id" { print $2 }')
  write_strong_meta atomic1-new "$reservation"
  err=$(TEST_OUTCOME_BIN="$failing" run_sc escalate atomic1 \
    --target-profile claude/claude-sonnet-5/high --new-id atomic1-new --commit 2>&1); rc=$?
  expect_code 2 "$rc" "failed outcome should leave a recoverable transaction"
  assert_contains "$err" "pending transaction remains" "failed outcome must identify pending recovery"
  [ -f "$STATE_DIR/.atomic1.stuck-escalate.pending" ] || fail "pending escalation record missing"
  assert_contains "$(cat "$STATE_DIR/atomic1.meta")" "escalated_from=codex/gpt-5.5/medium" \
    "pending transaction should persist the marker"
  out=$(run_sc escalate atomic1 --target-profile claude/claude-sonnet-5/high \
    --new-id atomic1-new --commit); rc=$?
  expect_code 0 "$rc" "retry should complete pending escalation"
  assert_contains "$out" "verdict=escalated" "retry should report the completed escalation"
  [ ! -e "$STATE_DIR/.atomic1.stuck-escalate.pending" ] || fail "completed transaction left pending record"
  pass "fm-stuck-classify.sh: recovers marker/outcome transaction"
}

test_escalate_revalidates_pending_target() {
  local dispatch="$TMP_ROOT/pending-dispatch.json" err rc
  printf '%s\n' '{"rules":[{"when":"complex ship","use":{"harness":"claude","model":"claude-sonnet-5","effort":"high","strength":20}}],"default":{"harness":"codex","model":"gpt-5.5","effort":"medium","strength":10}}' >"$dispatch"
  write_meta atomic3
  log_escalate_decision atomic3
  run_sc escalate atomic3 --target-profile claude/claude-sonnet-5/high \
    --new-id atomic3-new --reserve --dispatch "$dispatch" >/dev/null

  printf '%s\n' '{"default":{"harness":"codex","model":"gpt-5.5","effort":"medium","strength":10}}' >"$dispatch"
  err=$(run_sc escalate atomic3 --target-profile claude/claude-sonnet-5/high \
    --new-id atomic3-new --commit --dispatch "$dispatch" 2>&1); rc=$?
  expect_code 2 "$rc" "pending target must be revalidated after dispatch changes"
  assert_contains "$err" "pending target is no longer" "dispatch changes must invalidate stale pending targets"
  [ -f "$STATE_DIR/.atomic3.stuck-escalate.pending" ] || fail "stale pending transaction must remain recoverable"
  pass "fm-stuck-classify.sh: revalidates pending standing target"
}

test_escalate_serializes_concurrent_apply() {
  write_meta race1
  log_escalate_decision race1
  local slow rc1 rc2 p1 p2 reserve reservation
  reserve=$(run_sc escalate race1 --target-profile claude/claude-sonnet-5/high \
    --new-id race1-new --reserve)
  reservation=$(printf '%s\n' "$reserve" | awk -F= '$1 == "reservation_id" { print $2 }')
  write_strong_meta race1-new "$reservation"
  slow="$TMP_ROOT/slow-outcome.sh"
  printf '#!/usr/bin/env bash\nsleep 0.2\nexec %q "$@"\n' "$OUTCOME" >"$slow"
  chmod +x "$slow"
  (
    TEST_OUTCOME_BIN="$slow" run_sc escalate race1 --target-profile claude/claude-sonnet-5/high --new-id race1-new --commit >"$TMP_ROOT/race1.out" 2>&1
    printf '%s\n' "$?" >"$TMP_ROOT/race1.rc"
  ) & p1=$!
  (
    TEST_OUTCOME_BIN="$slow" run_sc escalate race1 --target-profile claude/claude-sonnet-5/high --new-id race1-new --commit >"$TMP_ROOT/race2.out" 2>&1
    printf '%s\n' "$?" >"$TMP_ROOT/race2.rc"
  ) & p2=$!
  wait "$p1" "$p2"
  rc1=$(cat "$TMP_ROOT/race1.rc")
  rc2=$(cat "$TMP_ROOT/race2.rc")
  [ "$rc1" = 0 ] || [ "$rc2" = 0 ] || fail "one concurrent escalate must succeed"
  [ "$rc1" = 2 ] || [ "$rc2" = 2 ] || fail "one concurrent escalate must refuse under the attempt lock"
  [ "$(grep -c 'escalated_from=' "$STATE_DIR/race1.meta")" -eq 1 ] \
    || fail "concurrent apply must write one audit marker"
  pass "fm-stuck-classify.sh: serializes concurrent escalation apply"
}

test_escalate_acquires_dual_lifecycle_locks_before_meta_read() {
  # Holding either prior or follow-on spawn lifecycle lock must refuse reserve
  # before metadata mutation, proving both IDs are locked.
  write_meta dual1
  log_escalate_decision dual1
  local err rc holder attempt
  (
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$STATE_DIR/.spawn-dual1.lock" || exit 1
    : >"$TMP_ROOT/dual1-prior-ready"
    while [ ! -e "$TMP_ROOT/dual1-prior-release" ]; do sleep 0.05; done
    fm_lock_release "$STATE_DIR/.spawn-dual1.lock"
  ) & holder=$!
  attempt=0
  while [ ! -e "$TMP_ROOT/dual1-prior-ready" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  [ -e "$TMP_ROOT/dual1-prior-ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "prior lifecycle lock holder did not become ready"
  }
  err=$(run_sc escalate dual1 --target-profile claude/claude-sonnet-5/high \
    --new-id dual1-new --reserve 2>&1); rc=$?
  : >"$TMP_ROOT/dual1-prior-release"
  wait "$holder"
  expect_code 2 "$rc" "prior lifecycle lock must refuse reserve"
  assert_contains "$err" "lifecycle is busy" "prior lock refusal should explain"
  [ ! -e "$STATE_DIR/.dual1.stuck-escalate.pending" ] \
    || fail "prior-locked reserve wrote a pending record"

  write_meta dual2
  log_escalate_decision dual2
  (
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$STATE_DIR/.spawn-dual2-new.lock" || exit 1
    : >"$TMP_ROOT/dual2-new-ready"
    while [ ! -e "$TMP_ROOT/dual2-new-release" ]; do sleep 0.05; done
    fm_lock_release "$STATE_DIR/.spawn-dual2-new.lock"
  ) & holder=$!
  attempt=0
  while [ ! -e "$TMP_ROOT/dual2-new-ready" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  [ -e "$TMP_ROOT/dual2-new-ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "follow-on lifecycle lock holder did not become ready"
  }
  err=$(run_sc escalate dual2 --target-profile claude/claude-sonnet-5/high \
    --new-id dual2-new --reserve 2>&1); rc=$?
  : >"$TMP_ROOT/dual2-new-release"
  wait "$holder"
  expect_code 2 "$rc" "follow-on lifecycle lock must refuse reserve"
  assert_contains "$err" "lifecycle is busy" "follow-on lock refusal should explain"
  [ ! -e "$STATE_DIR/.dual2.stuck-escalate.pending" ] \
    || fail "follow-on-locked reserve wrote a pending record"
  pass "fm-stuck-classify.sh: dual lifecycle locks serialize reserve with both task IDs"
}

test_escalate_reserve_linearizes_under_decision_log_lock() {
  # Holding the classify decision-log lock must block reserve from binding a
  # decision and publishing reservation records.
  write_meta dlock1
  log_escalate_decision dlock1
  local err rc holder attempt lock_path
  lock_path="$DECISION_LOG_PATH.lock"
  (
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock_path" || exit 1
    : >"$TMP_ROOT/dlock1-ready"
    while [ ! -e "$TMP_ROOT/dlock1-release" ]; do sleep 0.05; done
    fm_lock_release "$lock_path"
  ) & holder=$!
  attempt=0
  while [ ! -e "$TMP_ROOT/dlock1-ready" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  [ -e "$TMP_ROOT/dlock1-ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "decision-log lock holder did not become ready"
  }
  # Short acquire wait so the test fails closed quickly under contention.
  err=$(FM_LOCK_ACQUIRE_WAIT_TIMEOUT=1 run_sc escalate dlock1 \
    --target-profile claude/claude-sonnet-5/high \
    --new-id dlock1-new --reserve 2>&1); rc=$?
  : >"$TMP_ROOT/dlock1-release"
  wait "$holder"
  expect_code 2 "$rc" "decision-log lock contention must refuse reserve"
  assert_contains "$err" "decision log lock" "decision-log contention should explain"
  [ ! -e "$STATE_DIR/.dlock1.stuck-escalate.pending" ] \
    || fail "decision-log-contended reserve wrote a pending record"
  [ ! -e "$STATE_DIR/.dlock1-new.stuck-escalation-reservation" ] \
    || fail "decision-log-contended reserve wrote a claim"
  pass "fm-stuck-classify.sh: reserve linearizes decision selection under decision-log lock"
}

test_escalate_commit_idempotent_after_journal_cleared() {
  # Markers + outcome durable and journal already cleared must succeed on retry
  # rather than refuse as already_escalated / missing reservation.
  write_meta settle1
  log_escalate_decision settle1
  local out rc reserve reservation note
  note="same test red after 2 rounds"
  reserve=$(run_sc escalate settle1 --target-profile claude/claude-sonnet-5/high \
    --new-id settle1-new --reserve --note "$note")
  reservation=$(printf '%s\n' "$reserve" | awk -F= '$1 == "reservation_id" { print $2 }')
  write_strong_meta settle1-new "$reservation"
  out=$(run_sc escalate settle1 --target-profile claude/claude-sonnet-5/high \
    --new-id settle1-new --commit --note "$note"); rc=$?
  expect_code 0 "$rc" "initial commit should succeed"
  assert_contains "$out" "verdict=escalated" "initial commit verdict"
  [ ! -e "$STATE_DIR/.settle1.stuck-escalate.pending" ] || fail "pending remained after commit"
  [ ! -e "$STATE_DIR/.settle1-new.stuck-escalation-reservation" ] || fail "claim remained after commit"

  out=$(run_sc escalate settle1 --target-profile claude/claude-sonnet-5/high \
    --new-id settle1-new --commit --note "$note"); rc=$?
  expect_code 0 "$rc" "settled commit retry must be idempotent success"
  assert_contains "$out" "verdict=escalated" "settled retry should report escalated"
  [ "$(grep -c 'escalated_from=' "$STATE_DIR/settle1.meta")" -eq 1 ] \
    || fail "idempotent retry must not double-write prior marker"
  pass "fm-stuck-classify.sh: settled commit is idempotent when journal already cleared"
}

test_escalate_refuses_missing_target() {
  write_meta cheap3
  local err rc
  err=$(run_sc escalate cheap3 2>&1); rc=$?
  expect_code 2 "$rc" "missing target should exit 2"
  assert_contains "$err" "--target-profile" "missing target explains"
  pass "fm-stuck-classify.sh: escalate requires target profile"
}

test_n_env_override() {
  local out
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_STUCK_CLASSIFY_N=3 \
    "$CLASSIFY" classify --endpoint-alive yes --crew-state working \
    --failure-class capability --same-failure yes --fix-attempts 2 \
    --recovery-exhausted yes)
  assert_contains "$out" "verdict=refuse" "N=3 should refuse attempts=2"
  assert_contains "$out" "n_threshold=3" "env N visible in metrics"
  assert_contains "$out" "reason=below_threshold" "below env N"
  pass "fm-stuck-classify.sh: FM_STUCK_CLASSIFY_N is tunable"
}

# --- run ---
test_script_parses
test_help_renders_header
test_refuse_unknown_command
test_classify_refuses_dead_endpoint
test_classify_refuses_infra
test_classify_refuses_parked
test_classify_refuses_declared_pause
test_classify_refuses_validation_advancing
test_classify_refuses_self_report_only
test_classify_refuses_already_escalated
test_classify_refuses_below_threshold
test_classify_uncertain_ambiguous
test_classify_uncertain_unknown_crew_state
test_classify_uncertain_missing_endpoint_evidence
test_classify_refuses_external_wait
test_classify_escalates_capability_stuck
test_classify_uncertain_without_escalation_history
test_classify_json_shape
test_classify_appends_decision_schema
test_classify_log_never_rewrites_prior_lines
test_classify_log_repairs_missing_final_newline
test_classify_log_recovers_pending_after_missing_final_newline
test_classify_log_replays_partial_pending_payload
test_classify_log_rejects_malformed_existing_stream
test_classify_log_serializes_concurrent_appends
test_classify_gold_cases_append_unique_records
test_classify_log_rejects_unsafe_targets
test_classify_log_rejects_external_lock_symlink
test_classify_log_recovers_stale_lock_directories
test_classify_relative_log_path_is_canonicalized
test_classify_log_rejects_hardlinked_target
test_classify_log_rejects_corrupt_lock_fifo
test_classify_logging_failure_is_soft
test_classify_unwritable_log_parent_fails_softly
test_classify_logging_can_be_disabled
test_classify_normalizes_json_numbers
test_classify_rejects_invalid_timestamp_output
test_classify_default_log_uses_active_data_and_isolates_homes
test_classify_default_log_accepts_symlinked_active_home
test_classify_has_no_state_side_effect
test_classify_reads_already_escalated_from_meta
test_resolve_stronger_from_standing_fixture
test_resolve_stronger_uses_explicit_strength_only
test_resolve_stronger_preserves_optional_and_slash_profiles
test_resolve_stronger_accepts_default_only_dispatch
test_resolve_stronger_refuses_out_of_range_strength
test_resolve_stronger_refuses_missing_dispatch
test_escalate_reserves_then_commits_linkage
test_escalate_rejects_mismatched_follow_on_profile
test_escalate_refuses_arbitrary_target
test_escalate_requires_reservation_before_commit
test_escalate_requires_durable_escalate_decision
test_escalate_claims_new_id_globally
test_escalate_recovers_pending_transaction
test_escalate_revalidates_pending_target
test_escalate_serializes_concurrent_apply
test_escalate_acquires_dual_lifecycle_locks_before_meta_read
test_escalate_reserve_linearizes_under_decision_log_lock
test_escalate_commit_idempotent_after_journal_cleared
test_escalate_refuses_missing_target
test_n_env_override

echo "all fm-stuck-classify tests passed"
