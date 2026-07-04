#!/usr/bin/env bash
# Backend helpers for firstmate's visible crew runtime.
# Default backend is tmux. Set FM_BACKEND=orca or codex-app via
# config/backend(.env) to use another visible crew backend.

fm_backend_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

fm_backend_home() {
  local root=${FM_ROOT:-$(fm_backend_root)}
  printf '%s\n' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
}

fm_backend_config_dir() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$(fm_backend_home)/config}"
}

fm_backend_state_dir() {
  printf '%s\n' "${FM_STATE_OVERRIDE:-$(fm_backend_home)/state}"
}

fm_backend_name() {
  local config cfg line
  config=$(fm_backend_config_dir)
  if [ -n "${FM_BACKEND:-}" ]; then
    echo "$FM_BACKEND"
    return 0
  fi
  if [ -f "$config/backend" ]; then
    cfg=$(tr -d '[:space:]' < "$config/backend" || true)
    [ -n "$cfg" ] && { echo "$cfg"; return 0; }
  fi
  if [ -f "$config/backend.env" ]; then
    line=$(grep -E '^[[:space:]]*FM_BACKEND=' "$config/backend.env" 2>/dev/null | tail -1 || true)
    line=${line#*=}
    line=${line%\"}
    line=${line#\"}
    line=${line%\'}
    line=${line#\'}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] && { echo "$line"; return 0; }
  fi
  echo tmux
}

fm_meta_get() {
  local key=$1 file=$2
  grep "^$key=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-
}

fm_backend_json_get() {
  local expr=$1
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
const data = input.trim() ? JSON.parse(input) : {};
const expr = process.argv[1].split(".");
let cur = data;
for (const part of expr) {
  if (cur == null) break;
  cur = cur[part];
}
if (cur != null) process.stdout.write(String(cur));
' "$expr"
}

fm_backend_first_terminal() {
  node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const terms = data.result && data.result.terminals || [];
if (terms[0] && terms[0].handle) process.stdout.write(terms[0].handle);
'
}

fm_backend_parse_worktree_create() {
  # shellcheck disable=SC2016 # Node reads this script literally; shell expansion is not wanted.
  node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
let found = { id: "", path: "", terminal: "" };
function walk(v) {
  if (!v || typeof v !== "object") return;
  if (!found.id && typeof v.worktreeId === "string") found.id = v.worktreeId;
  if (!found.id && typeof v.id === "string" && v.id.includes("::")) found.id = v.id;
  if (!found.path && typeof v.path === "string" && v.path.startsWith("/")) found.path = v.path;
  if (!found.terminal && typeof v.handle === "string" && v.handle.startsWith("term_")) found.terminal = v.handle;
  for (const value of Object.values(v)) walk(value);
}
walk(data.result || data);
process.stdout.write(`${found.id}\t${found.path}\t${found.terminal}`);
'
}

fm_backend_codex_config_path() {
  if [ -n "${FM_ORCA_CODEX_CONFIG:-}" ]; then
    echo "$FM_ORCA_CODEX_CONFIG"
    return 0
  fi
  echo "$HOME/Library/Application Support/orca/codex-runtime-home/home/config.toml"
}

fm_backend_trust_codex_project() {
  local project_path=$1 config_path
  config_path=$(fm_backend_codex_config_path)
  mkdir -p "$(dirname "$config_path")"
  PROJECT_PATH="$project_path" CONFIG_PATH="$config_path" node <<'NODE'
const fs = require("fs");

const configPath = process.env.CONFIG_PATH;
const projectPath = process.env.PROJECT_PATH;
const key = projectPath.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
const header = `[projects."${key}"]`;

let content = "";
try {
  content = fs.readFileSync(configPath, "utf8");
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}

if (!content.includes(header)) {
  const prefix = content.length && !content.endsWith("\n") ? "\n" : "";
  fs.appendFileSync(configPath, `${prefix}\n${header}\ntrust_level = "trusted"\n`);
}
NODE
}

fm_backend_meta_for_selector() {
  local selector=$1 state meta base win thread_id
  state=$(fm_backend_state_dir)
  base=${selector#fm-}
  if [ -f "$state/$base.meta" ]; then
    echo "$state/$base.meta"
    return 0
  fi
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    win=$(fm_meta_get window "$meta")
    thread_id=$(fm_meta_get thread_id "$meta")
    case "$selector" in
      "$win"|fm-"$(basename "$meta" .meta)") echo "$meta"; return 0 ;;
      "$thread_id") echo "$meta"; return 0 ;;
      *) case "$win" in *:"$selector"|"$selector") echo "$meta"; return 0 ;; esac ;;
    esac
  done
  return 1
}

fm_backend_tmux_resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    *) tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
       || { echo "error: no window named $1" >&2; return 1; } ;;
  esac
}

fm_backend_capture() {
  local meta=$1 lines=${2:-40} backend target terminal thread_id
  backend=$(fm_meta_get backend "$meta")
  [ -n "$backend" ] || backend=tmux
  case "$backend" in
    tmux)
      target=$(fm_meta_get window "$meta")
      tmux capture-pane -p -t "$target" -S -"$lines"
      ;;
    orca)
      terminal=$(fm_meta_get terminal "$meta")
      [ -n "$terminal" ] || { echo "error: no terminal= in $meta" >&2; return 1; }
      orca terminal read --terminal "$terminal" --limit "$lines" --json \
        | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
      ;;
    codex-app)
      thread_id=$(fm_meta_get thread_id "$meta")
      [ -n "$thread_id" ] || { echo "error: no thread_id= in $meta" >&2; return 1; }
      "${FM_ROOT:-$(fm_backend_root)}/bin/fm-codex-app" capture "$thread_id" "$lines"
      ;;
    *) echo "error: unknown backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_orca_terminal_text() {
  local terminal=$1 lines=${2:-40}
  orca terminal read --terminal "$terminal" --limit "$lines" --json \
    | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

fm_backend_orca_json_field() {  # <field> <json>
  local field=$1
  printf '%s' "$2" | node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) process.exit(2);
const r = data.result || {};
const term = r.terminal || {};
function scalar(v) {
  return (typeof v === "string" || typeof v === "number" || typeof v === "boolean") ? String(v) : "";
}
let v = "";
if (field === "limited") v = scalar(r.limited ?? term.limited);
if (field === "oldestCursor") v = scalar(r.oldestCursor || term.oldestCursor);
if (field === "nextCursor") v = scalar(r.nextCursor || term.nextCursor);
if (field === "latestCursor") v = scalar(r.latestCursor || term.latestCursor);
if (!v) process.exit(1);
process.stdout.write(v);
' "$field"
}

fm_backend_orca_read_text_paged() {  # <terminal-id> <limit>
  local terminal=$1 limit=${2:-200} out limited oldest cursor_out text older_text
  out=$(orca terminal read --terminal "$terminal" --limit "$limit" --json) || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok || return 1
  text=$(fm_backend_orca_json_text "$out") || return 1
  limited=$(fm_backend_orca_json_field limited "$out" 2>/dev/null || true)
  oldest=$(fm_backend_orca_json_field oldestCursor "$out" 2>/dev/null || true)
  if [ "$limited" = true ] && [ -n "$oldest" ]; then
    cursor_out=$(orca terminal read --terminal "$terminal" --cursor "$oldest" --limit "$limit" --json) || return 1
    printf '%s' "$cursor_out" | fm_backend_orca_json_ok || return 1
    older_text=$(fm_backend_orca_json_text "$cursor_out") || return 1
    text="${older_text}"$'\n'"${text}"
  fi
  printf '%s' "$text"
}

FM_BACKEND_ORCA_COMPOSER_LINES=${FM_BACKEND_ORCA_COMPOSER_LINES:-200}
FM_BACKEND_ORCA_IDLE_RE=${FM_BACKEND_ORCA_IDLE_RE:-${FM_COMPOSER_IDLE_RE:-'^Type a message\.\.\.$'}}

fm_backend_orca_composer_state() {  # <terminal-id> -> empty|pending|unknown
  local terminal=$1 cap line trimmed stripped="" bordered="" last_trimmed="" found=0
  cap=$(fm_backend_orca_read_text_paged "$terminal" "$FM_BACKEND_ORCA_COMPOSER_LINES") || { printf 'unknown'; return 0; }
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    last_trimmed=$trimmed
    case "$trimmed" in
      │*│|┃*┃|\|*\|) bordered=$trimmed ;;
    esac
  done < <(printf '%s\n' "$cap")
  if [ -n "$bordered" ]; then
    stripped=$bordered
    found=1
  elif [ -n "$last_trimmed" ]; then
    stripped=$last_trimmed
    found=1
  fi
  [ "$found" -eq 1 ] || { printf 'empty'; return 0; }
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '❯'|'>'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  if [ -z "$bordered" ]; then
    printf 'empty'; return 0
  fi
  case "$stripped" in
    '❯ '*|'> '*|'$ '*|'% '*|'# '*) stripped=${stripped#??} ;;
    '❯'*|'>'*|'$'*|'%'*|'#'*) stripped=${stripped#?} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if printf '%s' "$stripped" | grep -qE "$FM_BACKEND_ORCA_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  printf 'pending'
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_send_enter() {  # <terminal-id>
  local terminal=$1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
}

fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 state
  command -v orca >/dev/null 2>&1 || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_orca_send_enter "$terminal" || true
    sleep "$sleep_s"
    state=$(fm_backend_orca_composer_state "$terminal")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_backend_send_text() {
  local meta=$1 text=$2 backend target terminal thread_id root verdict retries sleep_s settle harness
  backend=$(fm_meta_get backend "$meta")
  [ -n "$backend" ] || backend=tmux
  case "$backend" in
    tmux)
      target=$(fm_meta_get window "$meta")
      harness=$(fm_meta_get harness "$meta")
      case "$text" in
        /*) settle=1.2 ;;
        \$*)
          if [ "$harness" = codex ]; then settle=1.2; else settle=0.3; fi
          ;;
        *) settle=0.3 ;;
      esac
      if [ "$(type -t fm_tmux_submit_core 2>/dev/null || true)" != function ]; then
        # shellcheck source=bin/fm-tmux-lib.sh
        . "${FM_ROOT:-$(fm_backend_root)}/bin/fm-tmux-lib.sh"
      fi
      retries=${FM_SEND_RETRIES:-3}
      sleep_s=${FM_SEND_SLEEP:-0.4}
      verdict=$(fm_tmux_submit_core "$target" "$text" "$retries" "$sleep_s" "$settle")
      case "$verdict" in
        pending)
          echo "error: text not submitted to $target (Enter swallowed; text left in composer)" >&2
          return 1
          ;;
        send-failed)
          echo "error: text not sent to $target (tmux send-keys failed)" >&2
          return 1
          ;;
      esac
      ;;
    orca)
      terminal=$(fm_meta_get terminal "$meta")
      [ -n "$terminal" ] || { echo "error: no terminal= in $meta" >&2; return 1; }
      harness=$(fm_meta_get harness "$meta")
      case "$text" in
        /*) settle=1.2 ;;
        \$*)
          if [ "$harness" = codex ]; then settle=1.2; else settle=0.3; fi
          ;;
        *) settle=0.3 ;;
      esac
      retries=${FM_SEND_RETRIES:-3}
      sleep_s=${FM_SEND_SLEEP:-0.4}
      verdict=$(fm_backend_orca_send_text_submit "$terminal" "$text" "$retries" "$sleep_s" "$settle")
      case "$verdict" in
        pending)
          echo "error: text not submitted to $terminal (Enter swallowed; text left in composer)" >&2
          return 1
          ;;
        send-failed)
          echo "error: text not sent to $terminal (orca terminal send failed)" >&2
          return 1
          ;;
        unknown)
          echo "error: text submission to $terminal could not be verified from Orca terminal capture" >&2
          return 1
          ;;
      esac
      ;;
    codex-app)
      root=${FM_ROOT:-$(fm_backend_root)}
      thread_id=$(fm_meta_get thread_id "$meta")
      [ -n "$thread_id" ] || { echo "error: no thread_id= in $meta" >&2; return 1; }
      "$root/bin/fm-codex-app" send "$thread_id" "$text"
      ;;
    *) echo "error: unknown backend '$backend'" >&2; return 1 ;;
  esac
}

fm_backend_send_key() {
  local meta=$1 key=$2 backend target terminal thread_id
  backend=$(fm_meta_get backend "$meta")
  [ -n "$backend" ] || backend=tmux
  case "$backend" in
    tmux)
      target=$(fm_meta_get window "$meta")
      tmux send-keys -t "$target" "$key"
      ;;
    orca)
      terminal=$(fm_meta_get terminal "$meta")
      [ -n "$terminal" ] || { echo "error: no terminal= in $meta" >&2; return 1; }
      case "$key" in
        Escape|C-c) fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json >/dev/null ;;
        Enter) fm_backend_orca_send_enter "$terminal" >/dev/null ;;
        *) echo "error: unsupported Orca key '$key'" >&2; return 1 ;;
      esac
      ;;
    codex-app)
      thread_id=$(fm_meta_get thread_id "$meta")
      [ -n "$thread_id" ] || { echo "error: no thread_id= in $meta" >&2; return 1; }
      case "$key" in
        Escape|C-c) "${FM_ROOT:-$(fm_backend_root)}/bin/fm-codex-app" interrupt "$thread_id" >/dev/null ;;
        Enter) "${FM_ROOT:-$(fm_backend_root)}/bin/fm-codex-app" send "$thread_id" "" ;;
        *) echo "error: unsupported Codex App key '$key'" >&2; return 1 ;;
      esac
      ;;
    *) echo "error: unknown backend '$backend'" >&2; return 1 ;;
  esac
}
