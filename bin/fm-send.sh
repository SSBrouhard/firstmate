#!/usr/bin/env bash
# Send one line of literal text to a crewmate backend session.
# Usage: fm-send.sh <selector> <text...>
#   <selector> may be fm-xyz, a tmux session:window, or a backend thread id.
# Special keys instead of text: fm-send.sh <selector> --key Escape   (or Enter, C-c, ...)
#   Codex App threads are app-owned: this refuses and prints the Codex Desktop
#   host-tool action instead of sending from shell.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$FM_ROOT/bin/fm-backend.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

META=$(fm_backend_meta_for_selector "$1" || true)
if [ -z "$META" ]; then
  # Backward-compatible tmux fallback for ad hoc windows with no meta.
  T=$(fm_backend_tmux_resolve "$1")
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-send-meta.XXXXXX")
  printf 'backend=tmux\nwindow=%s\n' "$T" > "$tmp"
  META=$tmp
fi
shift

if [ "${1:-}" = "--key" ]; then
  fm_backend_send_key "$META" "$2"
else
  fm_backend_send_text "$META" "$*"
fi
