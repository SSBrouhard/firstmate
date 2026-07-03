#!/usr/bin/env bash
# Codex App visible-thread backend adapter.
# The Codex Desktop app owns thread IO; this adapter exposes firstmate's local
# ledger as a backend target and refuses operations that must happen in Desktop.

fm_backend_codex_app_cmd() {
  "$FM_BACKEND_LIB_DIR/fm-codex-app" "$@"
}

fm_backend_codex_app_capture() {  # <thread-id> <lines>
  fm_backend_codex_app_cmd capture "$1" "$2"
}

fm_backend_codex_app_send_key() {  # <thread-id> <key>
  case "$2" in
    C-c|Escape)
      fm_backend_codex_app_cmd interrupt "$1"
      ;;
    *)
      echo "error: Codex App thread $1 is app-owned. Send keys from Codex Desktop." >&2
      return 2
      ;;
  esac
}

fm_backend_codex_app_send_text_submit() {  # <thread-id> <text> <retries> <enter-sleep> <settle>
  fm_backend_codex_app_cmd send "$1" "$2" >&2 || true
  printf 'send-failed'
}

fm_backend_codex_app_kill() {  # <thread-id>
  local status
  status=$(fm_backend_codex_app_cmd status "$1" 2>/dev/null | sed -n 's/^status=//p' | tail -1) || {
    echo "error: Codex App thread $1 is not archived in the firstmate ledger. Archive it in Codex Desktop, then run mark-archived." >&2
    return 2
  }
  if [ "$status" = archived ]; then
    return 0
  fi
  echo "error: Codex App thread $1 is app-owned and still marked $status. Archive it in Codex Desktop, then run mark-archived." >&2
  return 2
}

fm_backend_codex_app_busy_state() {  # <thread-id>
  local status
  status=$(fm_backend_codex_app_cmd status "$1" 2>/dev/null | sed -n 's/^status=//p' | tail -1) || { printf 'unknown'; return 0; }
  case "$status" in
    archived) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_codex_app_target_exists() {  # <thread-id>
  fm_backend_codex_app_cmd status "$1" >/dev/null 2>&1
}
