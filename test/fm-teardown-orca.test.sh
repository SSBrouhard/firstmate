#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-teardown-orca.XXXXXX")
ID=orca-invalid-force-$$
META="$ROOT/state/$ID.meta"
cleanup() {
  rm -rf "$TMP"
  rm -f "$META" "$ROOT/state/$ID.status" "$ROOT/state/$ID.turn-ended" "$ROOT/state/$ID.check.sh"
}
trap cleanup EXIT

mkdir -p "$ROOT/state" "$TMP/bin" "$TMP/project" "$TMP/not-git"
cat > "$TMP/bin/orca" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/orca.log"
EOF
chmod +x "$TMP/bin/orca"

cat > "$META" <<EOF
backend=orca
window=fm-$ID
worktree=$TMP/not-git
project=$TMP/project
harness=codex
kind=ship
mode=local-only
yolo=off
terminal=terminal-$ID
orca_worktree_id=worktree-$ID
EOF

PATH="$TMP/bin:$PATH" "$ROOT/bin/fm-teardown.sh" "$ID" --force >/dev/null
[ ! -e "$META" ]
grep -qx "terminal close --terminal terminal-$ID --json" "$TMP/orca.log"
grep -qx "worktree rm --worktree id:worktree-$ID --force --json" "$TMP/orca.log"
