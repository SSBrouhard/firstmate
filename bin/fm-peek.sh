#!/usr/bin/env bash
# Print the tail of a crewmate pane (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <window> [lines=40]
#   <window> may be a bare window name (fm-xyz) or session:window.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$FM_ROOT/bin/fm-backend.sh"
"$FM_ROOT/bin/fm-guard.sh" || true

META=$(fm_backend_meta_for_selector "$1" || true)
if [ -z "$META" ]; then
  # Backward-compatible tmux fallback for ad hoc windows with no meta.
  T=$(fm_backend_tmux_resolve "$1")
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-peek-meta.XXXXXX")
  printf 'backend=tmux\nwindow=%s\n' "$T" > "$tmp"
  META=$tmp
fi
N=${2:-40}
fm_backend_capture "$META" "$N"
