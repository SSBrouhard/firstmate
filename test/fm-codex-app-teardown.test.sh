#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID=codex-app-teardown-$$
SCOUT_ID=codex-app-scout-teardown-$$
OTHER_ID=codex-app-other-worktree-$$
DIRTY_ID=codex-app-dirty-worktree-$$
MERGED_ID=codex-app-merged-missing-worktree-$$
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-app-teardown.XXXXXX")
META="$ROOT/state/$ID.meta"
SCOUT_META="$ROOT/state/$SCOUT_ID.meta"
SCOUT_CAPTURE="$ROOT/state/$SCOUT_ID.codex-app.capture"
OTHER_META="$ROOT/state/$OTHER_ID.meta"
DIRTY_META="$ROOT/state/$DIRTY_ID.meta"
MERGED_META="$ROOT/state/$MERGED_ID.meta"
cleanup() {
  rm -rf "$TMP"
  rm -rf "$ROOT/data/$SCOUT_ID"
  rm -f "$META" "$SCOUT_META" "$SCOUT_CAPTURE" "$OTHER_META" "$DIRTY_META" "$MERGED_META" "$ROOT/state/$OTHER_ID.err" "$ROOT/state/$DIRTY_ID.err" "$ROOT/state/$MERGED_ID.err"
}
trap cleanup EXIT

mkdir -p "$ROOT/state"
cat > "$META" <<EOF
backend=codex-app
window=fm-$ID
worktree=/tmp/firstmate-missing-codex-app-worktree-$ID
project=$ROOT
harness=codex
kind=ship
mode=no-mistakes
yolo=off
thread_id=thread-$ID
codex_app_archived=1
EOF

if "$ROOT/bin/fm-teardown.sh" "$ID" 2>"$ROOT/state/$ID.err"; then
  echo "expected teardown with invalid Codex App ship worktree to fail" >&2
  rm -f "$ROOT/state/$ID.err"
  exit 1
fi
grep -q 'invalid worktree path' "$ROOT/state/$ID.err"
rm -f "$ROOT/state/$ID.err"

git init "$TMP/project" >/dev/null
git -C "$TMP/project" config user.email firstmate-test@example.com
git -C "$TMP/project" config user.name Firstmate
printf 'project\n' > "$TMP/project/README.md"
git -C "$TMP/project" add README.md
git -C "$TMP/project" commit -m init >/dev/null
git -C "$TMP/project" branch -M main
git init --bare "$TMP/origin.git" >/dev/null
git -C "$TMP/project" remote add origin "$TMP/origin.git"
git -C "$TMP/project" push -u origin main >/dev/null 2>&1

git -C "$TMP/project" checkout -b "fm/$MERGED_ID" >/dev/null 2>&1
printf 'merged\n' > "$TMP/project/merged.txt"
git -C "$TMP/project" add merged.txt
git -C "$TMP/project" commit -m merged >/dev/null
git -C "$TMP/project" checkout main >/dev/null 2>&1
git -C "$TMP/project" merge --no-ff "fm/$MERGED_ID" -m "merge test pr" >/dev/null
MERGED_COMMIT=$(git -C "$TMP/project" rev-parse HEAD)
git -C "$TMP/project" push origin main >/dev/null 2>&1
git -C "$TMP/project" remote set-head origin -a >/dev/null 2>&1 || true

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" -q .state "*) printf 'MERGED\n' ;;
  *" -q .baseRefName "*) printf 'main\n' ;;
  *" -q .mergeCommit.oid "*) printf '$MERGED_COMMIT\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
cat > "$MERGED_META" <<EOF
backend=codex-app
window=fm-$MERGED_ID
worktree=/tmp/firstmate-missing-codex-app-worktree-$MERGED_ID
project=$TMP/project
harness=codex
kind=ship
mode=no-mistakes
yolo=off
thread_id=thread-$MERGED_ID
codex_app_archived=1
pr=https://example.invalid/pr/1
EOF
PATH="$TMP/bin:$PATH" "$ROOT/bin/fm-teardown.sh" "$MERGED_ID" >/dev/null
[ ! -e "$MERGED_META" ]

git init "$TMP/other" >/dev/null
git -C "$TMP/other" config user.email firstmate-test@example.com
git -C "$TMP/other" config user.name Firstmate
printf 'other\n' > "$TMP/other/README.md"
git -C "$TMP/other" add README.md
git -C "$TMP/other" commit -m init >/dev/null
git -C "$TMP/other" checkout -b "fm/$OTHER_ID" >/dev/null 2>&1
cat > "$OTHER_META" <<EOF
backend=codex-app
window=fm-$OTHER_ID
worktree=$TMP/other
project=$TMP/project
harness=codex
kind=ship
mode=no-mistakes
yolo=off
thread_id=thread-$OTHER_ID
codex_app_archived=1
EOF
if "$ROOT/bin/fm-teardown.sh" "$OTHER_ID" 2>"$ROOT/state/$OTHER_ID.err"; then
  echo "expected teardown with unrelated Codex App worktree to fail" >&2
  exit 1
fi
grep -q 'worktree does not belong to project' "$ROOT/state/$OTHER_ID.err"

git -C "$TMP/project" checkout -b "fm/$DIRTY_ID" >/dev/null 2>&1
printf 'dirty\n' > "$TMP/project/dirty.txt"
cat > "$DIRTY_META" <<EOF
backend=codex-app
window=fm-$DIRTY_ID
worktree=$TMP/project
project=$TMP/project
harness=codex
kind=ship
mode=no-mistakes
yolo=off
thread_id=thread-$DIRTY_ID
EOF
if "$ROOT/bin/fm-teardown.sh" "$DIRTY_ID" 2>"$ROOT/state/$DIRTY_ID.err"; then
  echo "expected teardown with unlanded Codex App worktree to fail" >&2
  exit 1
fi
grep -q 'has work not on any remote' "$ROOT/state/$DIRTY_ID.err"
if grep -q 'not marked archived' "$ROOT/state/$DIRTY_ID.err"; then
  echo "expected work safety refusal before archive refusal" >&2
  exit 1
fi

mkdir -p "$ROOT/data/$SCOUT_ID"
printf 'report\n' > "$ROOT/data/$SCOUT_ID/report.md"
printf 'cached transcript\n' > "$SCOUT_CAPTURE"
cat > "$SCOUT_META" <<EOF
backend=codex-app
window=fm-$SCOUT_ID
worktree=
project=$ROOT
harness=codex
kind=scout
mode=no-mistakes
yolo=off
thread_id=thread-$SCOUT_ID
codex_app_archived=1
EOF

"$ROOT/bin/fm-teardown.sh" "$SCOUT_ID" >/dev/null
[ ! -e "$SCOUT_META" ]
[ ! -e "$SCOUT_CAPTURE" ]
