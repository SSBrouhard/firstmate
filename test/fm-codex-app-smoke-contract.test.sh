#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-app-smoke.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/pass.txt" <<EOF
visible_thread=ok
list_threads=ok
read_thread=ok
send_message_to_thread=ok
archive=ok
restart_reconcile=ok
EOF
"$ROOT/bin/fm-codex-app-smoke-check.sh" "$TMP/pass.txt" | grep -qx 'codex-app visible smoke: passed'

cat > "$TMP/no-list.txt" <<EOF
visible_thread=ok
read_thread=ok
send_message_to_thread=ok
archive=ok
restart_reconcile=ok
EOF
if "$ROOT/bin/fm-codex-app-smoke-check.sh" "$TMP/no-list.txt" 2>"$TMP/no-list.err"; then
  echo "expected missing list_threads evidence to fail" >&2
  exit 1
fi
grep -q 'missing list_threads=ok' "$TMP/no-list.err"

cat > "$TMP/headless.txt" <<EOF
app_server_only=1
visible_thread=ok
list_threads=ok
read_thread=ok
send_message_to_thread=ok
archive=ok
restart_reconcile=ok
EOF
if "$ROOT/bin/fm-codex-app-smoke-check.sh" "$TMP/headless.txt" 2>"$TMP/headless.err"; then
  echo "expected headless-only evidence to fail" >&2
  exit 1
fi
grep -q 'headless-only evidence' "$TMP/headless.err"
