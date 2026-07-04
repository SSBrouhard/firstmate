#!/usr/bin/env bash
# Orca submit verification: transport success is not submission success.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-submit)

make_orca_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
echo "$next" > "$COUNT_FILE"
if [ -f "$RESP/$next.exit" ]; then
  exit "$(cat "$RESP/$next.exit")"
fi
[ -f "$RESP/$next.out" ] && cat "$RESP/$next.out"
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

orca_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  FB=$(make_orca_fakebin "$CASE_DIR")
}

test_orca_submit_verifies_empty_composer_after_enter() {
  local out log_text
  orca_case submit-empty
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ > │","╰──╯"]}}}\n' > "$RESP/3.out"

  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )

  [ "$out" = empty ] || fail "successful Orca submit should verify an empty composer, got '$out'"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1fhello captain\x1f--json' \
    "submit should type text before pressing Enter"
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json' \
    "submit should press Enter after typing"
  assert_contains "$log_text" $'orca\x1fterminal\x1fread\x1f--terminal\x1fterm-123\x1f--limit' \
    "submit should read the terminal to verify consumption"
  pass "fm_backend_orca_send_text_submit: verifies empty composer after Enter"
}

test_orca_submit_verifies_unboxed_empty_prompt_after_enter() {
  local out
  orca_case submit-unboxed-empty
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["done","❯"]}}}\n' > "$RESP/3.out"

  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )

  [ "$out" = empty ] || fail "successful Orca submit should verify an unboxed empty prompt, got '$out'"
  pass "fm_backend_orca_send_text_submit: verifies unboxed empty prompt after Enter"
}

test_orca_submit_ignores_historical_unboxed_prompt() {
  local out log_text enter_count
  orca_case historical-unboxed-prompt
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["❯ hello captain","working"]}}}\n' > "$RESP/3.out"

  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )

  [ "$out" = empty ] || fail "historical Orca prompt should not look pending, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 1 ] || fail "historical prompt should not trigger retry Enter, got $enter_count"
  pass "fm_backend_orca_send_text_submit: ignores historical unboxed prompts"
}

test_orca_submit_ignores_bottom_prompt_like_output() {
  local out log_text enter_count
  orca_case bottom-prompt-like-output
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["working","# Heading"]}}}\n' > "$RESP/3.out"

  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )

  [ "$out" = empty ] || fail "bottom prompt-like output should not look pending, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 1 ] || fail "bottom prompt-like output should not trigger retry Enter, got $enter_count"
  pass "fm_backend_orca_send_text_submit: ignores bottom prompt-like output"
}

test_orca_composer_state_honors_shared_idle_override() {
  local out
  orca_case shared-idle-override
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ custom idle> │","╰──╯"]}}}\n' > "$RESP/1.out"

  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_COMPOSER_IDLE_RE='^custom idle>$' \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )

  [ "$out" = empty ] || fail "Orca should honor FM_COMPOSER_IDLE_RE, got '$out'"
  pass "fm_backend_orca_composer_state: honors shared idle override"
}

test_orca_composer_state_does_not_trust_wrapped_unboxed_text() {
  local out
  orca_case wrapped-unboxed-text
  printf '{"ok":true,"result":{"terminal":{"tail":["❯ this is a long message that wrapped before it was submitted","and the continuation is still in the composer"]}}}\n' > "$RESP/1.out"

  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )

  [ "$out" = empty ] || fail "wrapped unboxed text should not be treated as a reliable pending signal, got '$out'"
  pass "fm_backend_orca_composer_state: does not trust wrapped unboxed text"
}

test_orca_composer_state_popup_placeholder_fill_is_pending() {
  local out
  orca_case popup-placeholder
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ > /compact compaction instructions │","╰──╯"]}}}\n' > "$RESP/1.out"

  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )

  [ "$out" = pending ] || fail "slash autocomplete placeholder fill must be pending, got '$out'"
  pass "fm_backend_orca_composer_state: slash popup placeholder fill is pending"
}

test_orca_send_text_reports_swallowed_codex_skill_enter() {
  local meta out status log_text enter_count
  orca_case skill-popup-swallowed
  meta="$CASE_DIR/task.meta"
  fm_write_meta "$meta" "backend=orca" "terminal=term-123" "harness=codex"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ > $no-mistakes run validation │","╰──╯"]}}}\n' > "$RESP/3.out"

  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_SEND_RETRIES=1 FM_SEND_SLEEP=0.01 \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_text "$1" "$2"' "$ROOT" "$meta" '$no-mistakes' 2>&1 )
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "codex skill send should fail when Enter is swallowed by autocomplete"
  assert_contains "$out" "Enter swallowed" "failure should explain that the text was left in the composer"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 1 ] || fail "one-retry swallowed skill case should press Enter once, got $enter_count"
  pass "fm_backend_send_text: codex skill autocomplete swallow is reported as failure"
}

test_orca_submit_verifies_empty_composer_after_enter
test_orca_submit_verifies_unboxed_empty_prompt_after_enter
test_orca_submit_ignores_historical_unboxed_prompt
test_orca_submit_ignores_bottom_prompt_like_output
test_orca_composer_state_honors_shared_idle_override
test_orca_composer_state_does_not_trust_wrapped_unboxed_text
test_orca_composer_state_popup_placeholder_fill_is_pending
test_orca_send_text_reports_swallowed_codex_skill_enter
