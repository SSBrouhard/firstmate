#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-app-state.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/state"
PROJECT="$TMP/project"
WT="$TMP/wt"
git init -q "$PROJECT"
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "baseline"
git -C "$PROJECT" worktree add -q -b fm/state-test "$WT"
ID=state-test
META="$TMP/state/$ID.meta"
cat > "$META" <<EOF
backend=codex-app
window=fm-$ID
project=$PROJECT
worktree=$WT
harness=codex
kind=scout
mode=no-mistakes
yolo=off
EOF

FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread "$ID" thread-1 --turn-id turn-1 --pending-worktree-id pending-1 >/dev/null
grep -qx 'thread_id=thread-1' "$META"
grep -qx 'window=thread-1' "$META"
grep -qx 'turn_id=turn-1' "$META"
grep -qx 'codex_app_worktree_owner=external' "$META"
grep -qx 'codex_app_pending_worktree_id=pending-1' "$META"
grep -qx 'codex_app_thread_state=visible' "$META"
grep -qx 'codex_app_transport=visible-thread' "$META"

PENDING_ID=pending-loss
PENDING_META="$TMP/state/$PENDING_ID.meta"
cat > "$PENDING_META" <<EOF
backend=codex-app
window=fm-$PENDING_ID
project=$PROJECT
worktree=$WT
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

UNCACHED_ID=uncached-thread
UNCACHED_META="$TMP/state/$UNCACHED_ID.meta"
cat > "$UNCACHED_META" <<EOF
backend=codex-app
window=thread-uncached
thread_id=thread-uncached
EOF
[ "$(FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" capture thread-uncached 2)" = "" ]
FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" status thread-uncached | grep -qx 'status=visible'

FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" mark-archived "$ID" >/dev/null
grep -qx 'codex_app_archived=1' "$META"
grep -qx 'codex_app_thread_state=archived' "$META"

BRIEF="$TMP/brief.md"
printf 'brief\n' > "$BRIEF"
FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" prepare prepared-thread fm-prepared "$BRIEF" >/dev/null
FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" prepare prepared-thread fm-prepared "$BRIEF" >/dev/null
if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" prepare prepared-thread fm-other "$BRIEF" 2>"$TMP/prepare-overwrite.err"; then
  echo "expected prepare to refuse changing existing pending meta" >&2
  exit 1
fi
grep -q 'prepare refuses existing meta' "$TMP/prepare-overwrite.err"

cat > "$TMP/state/live-task.meta" <<EOF
backend=codex-app
window=thread-live
thread_id=thread-live
codex_app_thread_state=visible
EOF
if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" prepare live-task fm-live "$BRIEF" 2>"$TMP/prepare-live.err"; then
  echo "expected prepare to refuse existing visible meta" >&2
  exit 1
fi
grep -q 'prepare refuses existing meta' "$TMP/prepare-live.err"

cat > "$TMP/state/other.meta" <<EOF
backend=codex-app
window=fm-other
thread_id=thread-1
EOF
cat > "$TMP/state/third.meta" <<EOF
backend=codex-app
window=fm-third
project=$PROJECT
worktree=$WT
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

cat > "$TMP/state/not-codex.meta" <<EOF
window=fm-not-codex
project=/tmp/example
harness=codex
kind=scout
mode=no-mistakes
yolo=off
EOF
if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread not-codex thread-not-codex 2>"$TMP/not-codex.err"; then
  echo "expected record-thread on non-codex meta to fail" >&2
  exit 1
fi
grep -q 'requires backend=codex-app meta' "$TMP/not-codex.err"

cat > "$TMP/state/prepared-unsafe.meta" <<EOF
backend=codex-app
window=fm-prepared-unsafe
codex_app_thread_state=pending
EOF
if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread prepared-unsafe thread-unsafe 2>"$TMP/unsafe-record.err"; then
  echo "expected record-thread without protected task state to fail" >&2
  exit 1
fi
grep -q 'requires --kind ship or --kind scout' "$TMP/unsafe-record.err"
if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread prepared-unsafe thread-project --kind scout --project "$PROJECT" --worktree "$PROJECT" 2>"$TMP/unsafe-project-record.err"; then
  echo "expected record-thread with project checkout as worktree to fail" >&2
  exit 1
fi
grep -q 'distinct from the project checkout' "$TMP/unsafe-project-record.err"
if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread prepared-unsafe thread-owner --kind scout --project "$PROJECT" --worktree "$WT" --worktree-owner treehouse 2>"$TMP/unsafe-owner-record.err"; then
  echo "expected record-thread with unsupported worktree owner to fail" >&2
  exit 1
fi
grep -q 'only supports --worktree-owner external' "$TMP/unsafe-owner-record.err"
FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread prepared-unsafe thread-safe --kind scout --project "$PROJECT" --worktree "$WT" >/dev/null
grep -qx 'kind=scout' "$TMP/state/prepared-unsafe.meta"
grep -qx "project=$PROJECT" "$TMP/state/prepared-unsafe.meta"
grep -qx "worktree=$WT" "$TMP/state/prepared-unsafe.meta"
grep -qx 'codex_app_worktree_owner=external' "$TMP/state/prepared-unsafe.meta"

mkdir -p "$TMP/data"
cat > "$TMP/data/projects.md" <<EOF
- project [direct-PR +yolo] - Example project (added 2026-06-21)
EOF
FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" prepare prepared-mode fm-prepared-mode "$BRIEF" >/dev/null
FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" record-thread prepared-mode thread-prepared-mode --kind scout --project "$PROJECT" --worktree "$WT" >/dev/null
grep -qx 'mode=direct-PR' "$TMP/state/prepared-mode.meta"
grep -qx 'yolo=on' "$TMP/state/prepared-mode.meta"

FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread adopted thread-2 "$PROJECT" --kind scout --thread-name fm-adopted --worktree "$WT" >/dev/null
ADOPTED_META="$TMP/state/adopted.meta"
grep -qx 'backend=codex-app' "$ADOPTED_META"
grep -qx 'window=thread-2' "$ADOPTED_META"
grep -qx 'codex_app_thread_name=fm-adopted' "$ADOPTED_META"
grep -qx "worktree=$WT" "$ADOPTED_META"
grep -qx 'codex_app_worktree_owner=external' "$ADOPTED_META"
grep -qx "project=$PROJECT" "$ADOPTED_META"
grep -qx 'harness=codex' "$ADOPTED_META"
grep -qx 'kind=scout' "$ADOPTED_META"
grep -qx 'mode=direct-PR' "$ADOPTED_META"
grep -qx 'yolo=on' "$ADOPTED_META"
grep -qx 'thread_id=thread-2' "$ADOPTED_META"
grep -qx 'codex_app_thread_state=visible' "$ADOPTED_META"
grep -qx 'codex_app_pending_action=none' "$ADOPTED_META"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread no-worktree thread-no-worktree "$PROJECT" --kind scout 2>"$TMP/no-worktree.err"; then
  echo "expected adoption without worktree to fail" >&2
  exit 1
fi
grep -q 'requires --worktree' "$TMP/no-worktree.err"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread missing-worktree thread-missing-worktree "$PROJECT" --kind scout --worktree "$TMP/missing-wt" 2>"$TMP/missing-worktree.err"; then
  echo "expected adoption with missing worktree to fail" >&2
  exit 1
fi
grep -q 'existing directory' "$TMP/missing-worktree.err"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread project-worktree thread-project-worktree "$PROJECT" --kind scout --worktree "$PROJECT" 2>"$TMP/project-worktree.err"; then
  echo "expected adoption with project checkout as worktree to fail" >&2
  exit 1
fi
grep -q 'distinct from the project checkout' "$TMP/project-worktree.err"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread treehouse-owner thread-treehouse-owner "$PROJECT" --kind scout --worktree "$WT" --worktree-owner treehouse 2>"$TMP/treehouse-owner.err"; then
  echo "expected adoption with unsupported worktree owner to fail" >&2
  exit 1
fi
grep -q 'only supports --worktree-owner external' "$TMP/treehouse-owner.err"

PLAIN_CLONE="$TMP/plain-clone"
git clone -q "$PROJECT" "$PLAIN_CLONE"
if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread plain-clone thread-plain-clone "$PROJECT" --kind scout --worktree "$PLAIN_CLONE" 2>"$TMP/plain-clone.err"; then
  echo "expected adoption with plain clone worktree to fail" >&2
  exit 1
fi
grep -q 'registered linked worktree' "$TMP/plain-clone.err"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread adopted thread-3 "$PROJECT" --kind scout 2>"$TMP/duplicate-task.err"; then
  echo "expected duplicate task adoption to fail" >&2
  exit 1
fi
grep -q 'already has meta' "$TMP/duplicate-task.err"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" adopt-thread adopted-other thread-2 "$PROJECT" --kind scout 2>"$TMP/duplicate-thread.err"; then
  echo "expected duplicate thread adoption to fail" >&2
  exit 1
fi
grep -q 'already recorded' "$TMP/duplicate-thread.err"

OPS="$TMP/ops"
mkdir -p "$OPS/state" "$OPS/data" "$OPS/config"
ln -s "$ROOT/bin" "$OPS/bin"
SYMLINK_ID=symlink-root
cat > "$OPS/state/$SYMLINK_ID.meta" <<EOF
backend=codex-app
window=fm-$SYMLINK_ID
thread_id=thread-symlink
EOF
( cd "$OPS" && ./bin/fm-codex-app mark-archived "$SYMLINK_ID" >/dev/null )
grep -qx 'codex_app_archived=1' "$OPS/state/$SYMLINK_ID.meta"
