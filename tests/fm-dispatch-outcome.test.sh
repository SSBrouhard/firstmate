#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-outcome.sh (record / suggest / show / refuse).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUTCOME="$ROOT/bin/fm-dispatch-outcome.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-outcome)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
DATA_DIR="$HOME_DIR/data"
LOG_PATH="$DATA_DIR/dispatch-outcomes.jsonl"
mkdir -p "$STATE_DIR" "$DATA_DIR"

run_oc() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
    FM_DISPATCH_OUTCOMES="$LOG_PATH" \
    "$OUTCOME" "$@"
}

write_meta() {
  local id=$1
  cat >"$STATE_DIR/$id.meta" <<EOF
window=fm-$id
worktree=/tmp/wt-$id
project=/tmp/example/projects/sample-project
harness=codex
kind=ship
mode=no-mistakes
model=gpt-5.5
effort=medium
escalated_from=claude/haiku/low
EOF
}

test_script_parses() {
  local out rc
  out=$(bash -n "$OUTCOME" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-dispatch-outcome.sh must parse (got: $out)"
  [ -z "$out" ] || fail "bash -n emitted unexpected output: $out"
  pass "fm-dispatch-outcome.sh: bash -n succeeds"
}

test_help_renders_header() {
  local help
  help=$(run_oc --help 2>&1) || true
  assert_contains "$help" "No network" "help omitted safety line"
  assert_contains "$help" "dispatch-outcomes.jsonl" "help omitted default log path"
  pass "fm-dispatch-outcome.sh: help renders header"
}

test_read_only_commands_do_not_create_state() {
  local home data
  home="$TMP_ROOT/read-only-home"
  data="$home/data"
  mkdir -p "$data"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_DISPATCH_OUTCOMES="$data/missing.jsonl" "$OUTCOME" --help >/dev/null 2>&1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_DISPATCH_OUTCOMES="$data/missing.jsonl" "$OUTCOME" show >/dev/null
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_DISPATCH_OUTCOMES="$data/missing.jsonl" "$OUTCOME" suggest >/dev/null
  [ ! -e "$home/state" ] || fail "read-only commands must not create state"
  pass "fm-dispatch-outcome.sh: read-only commands leave state absent"
}

test_refuse_unknown_command() {
  local err rc
  err=$(run_oc nonsense 2>&1); rc=$?
  expect_code 2 "$rc" "unknown command should exit 2"
  assert_contains "$err" "unknown command" "unknown command should explain"
  pass "fm-dispatch-outcome.sh: refuses nonsense command"
}

test_refuse_invalid_outcome() {
  local err rc
  err=$(run_oc record tid --outcome victory 2>&1); rc=$?
  expect_code 2 "$rc" "invalid outcome should exit 2"
  assert_contains "$err" "invalid outcome" "invalid outcome should explain"
  pass "fm-dispatch-outcome.sh: refuses invalid outcome"
}

test_refuse_missing_id() {
  local err rc
  err=$(run_oc record --outcome "done" 2>&1); rc=$?
  expect_code 2 "$rc" "missing id should exit 2"
  assert_contains "$err" "requires <id>" "missing id should explain"
  pass "fm-dispatch-outcome.sh: refuses record without id"
}

test_refuse_path_like_id() {
  local err rc
  err=$(run_oc record '../evil' --outcome "done" 2>&1); rc=$?
  expect_code 2 "$rc" "path-like id should exit 2"
  assert_contains "$err" "invalid task id" "path-like id should explain"
  [ ! -f "$LOG_PATH" ] || [ ! -s "$LOG_PATH" ] || fail "path-like id must not write a log line"
  pass "fm-dispatch-outcome.sh: refuses path-like task ids"
}

test_record_from_meta() {
  rm -f "$LOG_PATH"
  write_meta "t-record"
  local out
  out=$(run_oc record t-record --outcome "done" --note 'landed PR')
  assert_contains "$out" "recorded t-record outcome=done" "record should confirm"
  [ -f "$LOG_PATH" ] || fail "log file was not created"
  local line
  line=$(cat "$LOG_PATH")
  assert_contains "$line" '"id":"t-record"' "log should include id"
  assert_contains "$line" '"outcome":"done"' "log should include outcome"
  assert_contains "$line" '"harness":"codex"' "log should pull harness from meta"
  assert_contains "$line" '"model":"gpt-5.5"' "log should pull model from meta"
  assert_contains "$line" '"effort":"medium"' "log should pull effort from meta"
  assert_contains "$line" '"kind":"ship"' "log should pull kind from meta"
  assert_contains "$line" '"mode":"no-mistakes"' "log should pull mode from meta"
  assert_contains "$line" '"repo":"sample-project"' "log should derive repo basename"
  assert_contains "$line" '"escalated_from":"claude/haiku/low"' "log should pull escalated_from"
  assert_contains "$line" '"note":"landed PR"' "log should include note"
  pass "fm-dispatch-outcome.sh: record pulls meta and appends JSON line"
}

test_record_without_meta() {
  rm -f "$LOG_PATH"
  local line
  run_oc record orphan-id --outcome failed --note 'no meta' >/dev/null
  line=$(cat "$LOG_PATH")
  assert_contains "$line" '"id":"orphan-id"' "record without meta should still log id"
  assert_contains "$line" '"outcome":"failed"' "record without meta should log outcome"
  assert_contains "$line" '"harness":""' "missing meta harness empty"
  pass "fm-dispatch-outcome.sh: record works when meta is absent"
}

test_record_escapes_note() {
  rm -f "$LOG_PATH"
  run_oc record esc-id --outcome blocked --note 'say "no" and path\x' >/dev/null
  local line
  line=$(cat "$LOG_PATH")
  assert_contains "$line" 'say' "note should be present"
  if command -v jq >/dev/null 2>&1; then
    echo "$line" | jq -e '.outcome == "blocked" and .note == "say \"no\" and path\\x"' >/dev/null \
      || fail "logged line must be valid JSON with escaped note: $line"
  else
    assert_contains "$line" '"outcome":"blocked"' "blocked outcome without jq"
  fi
  pass "fm-dispatch-outcome.sh: record escapes note for JSON safety"
}

test_concurrent_records_do_not_interleave() {
  rm -f "$LOG_PATH"
  local i pids='' pid lines
  i=1
  while [ "$i" -le 24 ]; do
    run_oc record "parallel-$i" --outcome "done" --note "parallel $i" >/dev/null &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" || fail "concurrent record failed for pid $pid"
  done
  lines=$(wc -l <"$LOG_PATH" | tr -d ' ')
  [ "$lines" -eq 24 ] || fail "expected 24 complete concurrent records, got $lines"
  if command -v jq >/dev/null 2>&1; then
    jq -e -s 'length == 24 and all(.[]; .id | startswith("parallel-"))' "$LOG_PATH" >/dev/null \
      || fail "concurrent records must remain complete JSON lines"
  fi
  pass "fm-dispatch-outcome.sh: concurrent records serialize append"
}

test_suggest_decodes_escaped_fields() {
  rm -f "$LOG_PATH"
  cat >"$STATE_DIR/escaped.meta" <<'EOF'
project=/tmp/example/projects/repo "quoted"\name
harness=codex
kind=ship
model=model "quoted"\name
effort=medium
EOF
  run_oc record escaped --outcome "done" >/dev/null
  local suggest
  suggest=$(run_oc suggest --repo 'repo "quoted"\name' --limit 10)
  assert_contains "$suggest" 'codex/model "quoted"\name/medium' "suggest should decode escaped model"
  assert_contains "$suggest" 'ship / repo "quoted"\name' "suggest should decode escaped repo filter"
  pass "fm-dispatch-outcome.sh: suggest decodes escaped JSON fields"
}

test_suggest_sanitizes_tsv_fields() {
  rm -f "$LOG_PATH"
  printf 'project=/tmp/example/projects/tab\trepo\nharness=codex\nkind=ship\nmodel=model\ttab\neffort=medium\n' \
    >"$STATE_DIR/tabbed.meta"
  run_oc record tabbed --outcome "done" >/dev/null
  local suggest
  suggest=$(run_oc suggest --limit 10)
  assert_contains "$suggest" 'ship / tab repo: done 1/1' "suggest should keep tabbed repo in one summary field"
  assert_contains "$suggest" 'codex/model tab/medium: done=1 failed=0 other=0' \
    "suggest should keep tabbed model in one profile field"
  pass "fm-dispatch-outcome.sh: suggest sanitizes TSV aggregation fields"
}

test_show_and_suggest() {
  rm -f "$LOG_PATH"
  write_meta "s1"
  cat >"$STATE_DIR/s2.meta" <<EOF
project=/tmp/example/projects/other-repo
harness=claude
kind=scout
mode=
model=haiku
effort=low
EOF
  run_oc record s1 --outcome "done" --note one >/dev/null
  run_oc record s1 --outcome failed --note two >/dev/null
  # Override meta for second id
  run_oc record s2 --outcome "done" --note scout-ok >/dev/null

  local show suggest
  show=$(run_oc show --limit 2)
  assert_contains "$show" "dispatch outcomes:" "show should header"
  assert_contains "$show" '"id":"s2"' "show should include newest line"

  suggest=$(run_oc suggest --kind ship --limit 10)
  assert_contains "$suggest" "Dispatch outcome bias" "suggest header"
  assert_contains "$suggest" "done=" "suggest outcome totals"
  assert_contains "$suggest" "codex/gpt-5.5/medium" "suggest profile key"
  assert_contains "$suggest" "Do not auto-edit config/crew-dispatch.json" "suggest non-goal"
  assert_contains "$suggest" "kind=ship" "suggest kind filter echoed"

  suggest=$(run_oc suggest --repo other-repo --limit 10)
  assert_contains "$suggest" "other-repo" "suggest repo filter"
  assert_contains "$suggest" "claude/haiku/low" "suggest scout profile from other-repo"

  pass "fm-dispatch-outcome.sh: show and suggest summarize recent outcomes"
}

test_suggest_empty_log() {
  local out
  out=$(FM_HOME="$HOME_DIR" FM_DISPATCH_OUTCOMES="$TMP_ROOT/missing.jsonl" \
    "$OUTCOME" suggest 2>&1)
  assert_contains "$out" "No outcome log" "empty/missing log should say so"
  assert_contains "$out" "Do not auto-edit" "empty suggest still states non-goal"
  pass "fm-dispatch-outcome.sh: suggest handles missing log"
}

test_refuse_bad_suggest_kind() {
  local err rc
  err=$(run_oc suggest --kind banana 2>&1); rc=$?
  expect_code 2 "$rc" "bad kind should exit 2"
  assert_contains "$err" "ship or scout" "bad kind should explain"
  pass "fm-dispatch-outcome.sh: refuses bad --kind"
}

# --- run ---
test_script_parses
test_help_renders_header
test_read_only_commands_do_not_create_state
test_refuse_unknown_command
test_refuse_invalid_outcome
test_refuse_missing_id
test_refuse_path_like_id
test_record_from_meta
test_record_without_meta
test_record_escapes_note
test_concurrent_records_do_not_interleave
test_suggest_decodes_escaped_fields
test_suggest_sanitizes_tsv_fields
test_show_and_suggest
test_suggest_empty_log
test_refuse_bad_suggest_kind

echo "all fm-dispatch-outcome tests passed"
