#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-app-headless.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

if grep -q 'app-server' "$ROOT/bin/fm-codex-app"; then
  echo "fm-codex-app must not start codex app-server in visible-thread mode" >&2
  exit 1
fi

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" send thread-1 hello 2>"$TMP/send.err"; then
  echo "expected shell send to visible Codex App thread to fail" >&2
  exit 1
fi
grep -q 'send_message_to_thread' "$TMP/send.err"

if FM_ROOT="$TMP" "$ROOT/bin/fm-codex-app" archive thread-1 2>"$TMP/archive.err"; then
  echo "expected shell archive to visible Codex App thread to fail" >&2
  exit 1
fi
grep -q 'set_thread_archived' "$TMP/archive.err"
