#!/usr/bin/env bash
# Validate a Codex App visible-thread smoke evidence transcript.
# Usage: fm-codex-app-smoke-check.sh <transcript-file>
# The transcript is intentionally simple key-value evidence, so humans can paste
# it into reports and CI can reject headless app-server "success" as insufficient.
set -eu

FILE=${1:-}
[ -n "$FILE" ] && [ -f "$FILE" ] || { echo "usage: fm-codex-app-smoke-check.sh <transcript-file>" >&2; exit 2; }

require() {
  local key=$1
  if ! grep -Eq "^$key=(ok|yes|true|1)$" "$FILE"; then
    echo "FAIL: missing $key=ok" >&2
    exit 1
  fi
}

if grep -Eq '^(app_server_only|headless_only)=(ok|yes|true|1)$' "$FILE"; then
  echo "FAIL: app-server/headless-only evidence is not a visible Codex App smoke" >&2
  exit 1
fi

require visible_thread
require list_threads
require read_thread
require send_message_to_thread
require archive
require restart_reconcile

echo "codex-app visible smoke: passed"
