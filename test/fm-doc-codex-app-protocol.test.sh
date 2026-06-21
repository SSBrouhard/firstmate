#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

grep -q 'visible Codex Desktop threads' "$ROOT/AGENTS.md"
grep -q 'create_thread' "$ROOT/AGENTS.md"
grep -q 'fork_thread' "$ROOT/AGENTS.md"
grep -q 'send_message_to_thread' "$ROOT/AGENTS.md"
grep -q 'set_thread_archived' "$ROOT/AGENTS.md"
grep -q 'adopt-thread' "$ROOT/AGENTS.md"
grep -q 'app-server.*headless' "$ROOT/README.md"
grep -q 'A completed app-server turn is not enough' "$ROOT/CONTRIBUTING.md"

if grep -q 'Codex CLI when FM_BACKEND=codex-app' "$ROOT/README.md"; then
  echo "README must not describe Codex App visible mode as Codex CLI app-server mode" >&2
  exit 1
fi
