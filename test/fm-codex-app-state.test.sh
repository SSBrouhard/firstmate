#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-app-state.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/state"
ID=state-test
META="$TMP/state/$ID.meta"
cat > "$META" <<EOF
backend=codex-app
window=fm-$ID
project=/tmp/example
harness=codex
kind=scout
mode=no-mistakes
yolo=off
EOF

FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread "$ID" thread-1 --turn-id turn-1 --pending-worktree-id pending-1 >/dev/null
grep -qx 'thread_id=thread-1' "$META"
grep -qx 'turn_id=turn-1' "$META"
grep -qx 'codex_app_pending_worktree_id=pending-1' "$META"
grep -qx 'codex_app_thread_state=visible' "$META"
grep -qx 'codex_app_transport=visible-thread' "$META"

PENDING_ID=pending-loss
PENDING_META="$TMP/state/$PENDING_ID.meta"
cat > "$PENDING_META" <<EOF
backend=codex-app
window=fm-$PENDING_ID
project=/tmp/example
harness=codex
kind=scout
mode=no-mistakes
yolo=off
EOF
FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-pending "$PENDING_ID" pending-2 >/dev/null
FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread "$PENDING_ID" thread-pending >/dev/null
grep -qx 'codex_app_pending_worktree_id=pending-2' "$PENDING_META"

printf 'first\nsecond\nthird\n' | FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-capture "$ID" - >/dev/null
[ "$(FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" capture thread-1 2)" = "$(printf 'second\nthird')" ]

FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" mark-archived "$ID" >/dev/null
grep -qx 'codex_app_archived=1' "$META"
grep -qx 'codex_app_thread_state=archived' "$META"

cat > "$TMP/state/other.meta" <<EOF
backend=codex-app
window=fm-other
thread_id=thread-1
EOF
cat > "$TMP/state/third.meta" <<EOF
backend=codex-app
window=fm-third
project=/tmp/example
harness=codex
kind=scout
mode=no-mistakes
yolo=off
EOF
if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread third thread-1 2>"$TMP/duplicate.err"; then
  echo "expected duplicate thread record to fail" >&2
  exit 1
fi
grep -q 'already recorded' "$TMP/duplicate.err"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread missing thread-missing 2>"$TMP/missing-meta.err"; then
  echo "expected record-thread without prepared meta to fail" >&2
  exit 1
fi
grep -q 'requires existing meta' "$TMP/missing-meta.err"

mkdir -p "$TMP/data"
cat > "$TMP/data/projects.md" <<EOF
- example [direct-PR +yolo] - Example project (added 2026-06-21)
EOF
FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread adopted thread-2 /tmp/example --kind scout --thread-name fm-adopted --worktree /tmp/wt >/dev/null
ADOPTED_META="$TMP/state/adopted.meta"
grep -qx 'backend=codex-app' "$ADOPTED_META"
grep -qx 'window=fm-adopted' "$ADOPTED_META"
grep -qx 'worktree=/tmp/wt' "$ADOPTED_META"
grep -qx 'project=/tmp/example' "$ADOPTED_META"
grep -qx 'harness=codex' "$ADOPTED_META"
grep -qx 'kind=scout' "$ADOPTED_META"
grep -qx 'mode=direct-PR' "$ADOPTED_META"
grep -qx 'yolo=on' "$ADOPTED_META"
grep -qx 'thread_id=thread-2' "$ADOPTED_META"
grep -qx 'codex_app_thread_state=visible' "$ADOPTED_META"
grep -qx 'codex_app_pending_action=none' "$ADOPTED_META"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread adopted thread-3 /tmp/example --kind scout 2>"$TMP/duplicate-task.err"; then
  echo "expected duplicate task adoption to fail" >&2
  exit 1
fi
grep -q 'already has meta' "$TMP/duplicate-task.err"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread adopted-other thread-2 /tmp/example --kind scout 2>"$TMP/duplicate-thread.err"; then
  echo "expected duplicate thread adoption to fail" >&2
  exit 1
fi
grep -q 'already recorded' "$TMP/duplicate-thread.err"
