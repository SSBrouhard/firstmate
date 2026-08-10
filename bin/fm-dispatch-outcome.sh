#!/usr/bin/env bash
# fm-dispatch-outcome.sh - operational-home append-only memory of crew dispatch
# endings, plus a read-only bias summary for future intake judgment.
#
# Product intent: firstmate already picks harness/model/effort once at intake via
# config/crew-dispatch.json. This helper records verified endings so later
# judgment can bias toward profiles that finished similar work, without becoming
# a mid-session model gateway or an online bandit.
#
# Default log (gitignored under data/): data/dispatch-outcomes.jsonl
# Override with FM_DISPATCH_OUTCOMES or --log <path>.
#
# Commands:
#   record <id> --outcome <done|failed|escalated|blocked> [--note "..."]
#       Append one JSON line. Pulls harness/model/effort/kind/mode/project and
#       optional escalated_from from state/<id>.meta when present. Missing meta
#       is allowed (fields empty) so firstmate can still log a known ending.
#   suggest [--kind ship|scout] [--repo <name>] [--limit N]
#       Print a short human-readable bias summary from recent matching lines.
#       Never edits config/crew-dispatch.json.
#   show [--limit N]
#       Print the newest log lines (default 20).
#   help | -h | --help
#       Print this header.
#
# Safety:
#   - No network.
#   - Refuse unknown subcommands and invalid outcomes.
#   - record refuses an empty id.
#   - Never auto-mutates dispatch config.
#
# See docs/dispatch-outcome-memory.md for escalate-on-stuck policy and non-goals.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DEFAULT_LOG="$DATA/dispatch-outcomes.jsonl"
LOG_PATH="${FM_DISPATCH_OUTCOMES:-$DEFAULT_LOG}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-dispatch-outcome: %s\n' "$*" >&2
  exit 2
}

log_err() {
  printf 'fm-dispatch-outcome: %s\n' "$*" >&2
}

# Minimal JSON string escape for known scalar fields (no network, no jq required).
json_escape() {
  local s=${1-}
  local out='' i c hex
  local n=${#s}
  i=0
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    case "$c" in
      \\) out="${out}\\\\" ;;
      '"') out="${out}\\\"" ;;
      $'\n') out="${out}\\n" ;;
      $'\r') out="${out}\\r" ;;
      $'\t') out="${out}\\t" ;;
      [[:cntrl:]])
        printf -v hex '%02x' "'$c"
        out="${out}\\u00${hex}"
        ;;
      *) out="${out}${c}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

meta_value() {
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^${key}=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

repo_name_from_project() {
  local project=${1-}
  [ -n "$project" ] || return 0
  basename "$project"
}

iso_now() {
  # UTC ISO-8601; fall back to epoch seconds if date -u fails.
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +%s
}

ensure_log_parent() {
  local dir
  dir=$(dirname "$LOG_PATH")
  mkdir -p "$dir"
}

acquire_log_lock() {
  local lock=$1 i=0 rc
  while [ "$i" -lt 50 ]; do
    if fm_lock_try_acquire "$lock"; then
      return 0
    else
      rc=$?
    fi
    [ "$rc" -eq 125 ] && return 125
    sleep 0.02
    i=$((i + 1))
  done
  return 1
}

tsv_safe() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

cmd_record() {
  local id='' outcome='' note=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --outcome)
        [ "$#" -gt 1 ] || die "--outcome requires a value"
        outcome=$2
        shift 2
        ;;
      --outcome=*)
        outcome=${1#--outcome=}
        shift
        ;;
      --note)
        [ "$#" -gt 1 ] || die "--note requires a value"
        note=$2
        shift 2
        ;;
      --note=*)
        note=${1#--note=}
        shift
        ;;
      --log)
        [ "$#" -gt 1 ] || die "--log requires a path"
        LOG_PATH=$2
        shift 2
        ;;
      --log=*)
        LOG_PATH=${1#--log=}
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown record flag: $1"
        ;;
      *)
        if [ -z "$id" ]; then
          id=$1
          shift
        else
          die "unexpected argument: $1"
        fi
        ;;
    esac
  done

  [ -n "$id" ] || die "record requires <id>"
  fm_task_id_path_safe "$id" || die "invalid task id '$id' (want path-safe [A-Za-z0-9._-]+, no leading dot)"
  [ -n "$outcome" ] || die "record requires --outcome <done|failed|escalated|blocked>"
  case "$outcome" in
    done|failed|escalated|blocked) ;;
    *) die "invalid outcome '$outcome' (want done|failed|escalated|blocked)" ;;
  esac

  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"

  local meta="$STATE/$id.meta"
  local harness model effort kind mode project escalated_from repo ts line lock
  harness=$(meta_value "$meta" harness)
  model=$(meta_value "$meta" model)
  effort=$(meta_value "$meta" effort)
  kind=$(meta_value "$meta" kind)
  mode=$(meta_value "$meta" mode)
  project=$(meta_value "$meta" project)
  escalated_from=$(meta_value "$meta" escalated_from)
  repo=$(repo_name_from_project "$project")
  ts=$(iso_now)

  # Build one compact JSON object without requiring jq.
  line=$(printf '{"ts":"%s","id":"%s","outcome":"%s","harness":"%s","model":"%s","effort":"%s","kind":"%s","mode":"%s","project":"%s","repo":"%s","escalated_from":"%s","note":"%s"}' \
    "$(json_escape "$ts")" \
    "$(json_escape "$id")" \
    "$(json_escape "$outcome")" \
    "$(json_escape "$harness")" \
    "$(json_escape "$model")" \
    "$(json_escape "$effort")" \
    "$(json_escape "$kind")" \
    "$(json_escape "$mode")" \
    "$(json_escape "$project")" \
    "$(json_escape "$repo")" \
    "$(json_escape "$escalated_from")" \
    "$(json_escape "$note")")

  ensure_log_parent
  lock="${LOG_PATH}.lock"
  if ! acquire_log_lock "$lock"; then
    log_err "unable to acquire outcome log lock at $lock"
    return 1
  fi
  if ! printf '%s\n' "$line" >>"$LOG_PATH"; then
    fm_lock_release "$lock" || true
    log_err "unable to append outcome to $LOG_PATH"
    return 1
  fi
  fm_lock_release "$lock" || true
  printf 'recorded %s outcome=%s log=%s\n' "$id" "$outcome" "$LOG_PATH"
}

# Load all log lines into LOG_LINES (oldest first). Callers walk newest-first.
load_log_lines() {
  LOG_LINES=()
  [ -f "$LOG_PATH" ] || return 0
  if command -v mapfile >/dev/null 2>&1; then
    mapfile -t LOG_LINES <"$LOG_PATH" || true
  else
    while IFS= read -r _line || [ -n "$_line" ]; do
      LOG_LINES+=("$_line")
    done <"$LOG_PATH"
  fi
}

json_unescape() {
  local value=$1 out='' i=0 n c hex decoded
  n=${#value}
  while [ "$i" -lt "$n" ]; do
    c=${value:i:1}
    if [ "$c" != $'\\' ]; then
      out="${out}${c}"
      i=$((i + 1))
      continue
    fi
    i=$((i + 1))
    [ "$i" -lt "$n" ] || return 1
    c=${value:i:1}
    case "$c" in
      '"') out="${out}\"" ;;
      $'\\') out="${out}\\" ;;
      n) out="${out}"$'\n' ;;
      r) out="${out}"$'\r' ;;
      t) out="${out}"$'\t' ;;
      u)
        [ $((i + 4)) -lt "$n" ] || return 1
        hex=${value:i+1:4}
        case "$hex" in
          00[0-9A-Fa-f][0-9A-Fa-f])
            printf -v decoded '%b' "\\x${hex#00}"
            out="${out}${decoded}"
            i=$((i + 4))
            ;;
          *) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

field_from_json_line() {
  local line=$1 key=$2 needle suffix raw='' i=0 n c escaped=0 found=0
  needle="\"${key}\":\""
  case "$line" in
    *"$needle"*) suffix=${line#*"$needle"} ;;
    *) return 0 ;;
  esac
  n=${#suffix}
  while [ "$i" -lt "$n" ]; do
    c=${suffix:i:1}
    if [ "$escaped" -eq 1 ]; then
      raw="${raw}\\${c}"
      escaped=0
    else
      case "$c" in
        $'\\') escaped=1 ;;
        '"') found=1; break ;;
        *) raw="${raw}${c}" ;;
      esac
    fi
    i=$((i + 1))
  done
  [ "$found" -eq 1 ] || return 0
  json_unescape "$raw"
}

cmd_show() {
  local limit=20
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit)
        [ "$#" -gt 1 ] || die "--limit requires a value"
        limit=$2
        shift 2
        ;;
      --limit=*)
        limit=${1#--limit=}
        shift
        ;;
      --log)
        [ "$#" -gt 1 ] || die "--log requires a path"
        LOG_PATH=$2
        shift 2
        ;;
      --log=*)
        LOG_PATH=${1#--log=}
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown show argument: $1"
        ;;
    esac
  done
  case "$limit" in
    ''|*[!0-9]*) die "--limit must be a positive integer" ;;
    0) die "--limit must be a positive integer" ;;
  esac

  if [ ! -f "$LOG_PATH" ]; then
    printf 'no outcome log at %s\n' "$LOG_PATH"
    return 0
  fi

  local total
  total=$(wc -l <"$LOG_PATH" | tr -d ' ')
  printf 'dispatch outcomes: %s lines in %s (showing newest %s)\n' "$total" "$LOG_PATH" "$limit"
  if command -v tail >/dev/null 2>&1; then
    tail -n "$limit" "$LOG_PATH"
  else
    # Unlikely fallback.
    cat "$LOG_PATH"
  fi
}

cmd_suggest() {
  local kind_filter='' repo_filter='' limit=50
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind)
        [ "$#" -gt 1 ] || die "--kind requires a value"
        kind_filter=$2
        shift 2
        ;;
      --kind=*)
        kind_filter=${1#--kind=}
        shift
        ;;
      --repo)
        [ "$#" -gt 1 ] || die "--repo requires a value"
        repo_filter=$2
        shift 2
        ;;
      --repo=*)
        repo_filter=${1#--repo=}
        shift
        ;;
      --limit)
        [ "$#" -gt 1 ] || die "--limit requires a value"
        limit=$2
        shift 2
        ;;
      --limit=*)
        limit=${1#--limit=}
        shift
        ;;
      --log)
        [ "$#" -gt 1 ] || die "--log requires a path"
        LOG_PATH=$2
        shift 2
        ;;
      --log=*)
        LOG_PATH=${1#--log=}
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown suggest argument: $1"
        ;;
    esac
  done

  if [ -n "$kind_filter" ]; then
    case "$kind_filter" in
      ship|scout) ;;
      *) die "--kind must be ship or scout" ;;
    esac
  fi
  case "$limit" in
    ''|*[!0-9]*) die "--limit must be a positive integer" ;;
    0) die "--limit must be a positive integer" ;;
  esac

  if [ ! -f "$LOG_PATH" ]; then
    printf 'No outcome log at %s yet.\n' "$LOG_PATH"
    printf 'Bias: none. Record endings with: fm-dispatch-outcome.sh record <id> --outcome <done|failed|escalated|blocked>\n'
    printf 'Do not auto-edit config/crew-dispatch.json from this tool.\n'
    return 0
  fi

  load_log_lines
  local total=${#LOG_LINES[@]}
  if [ "$total" -eq 0 ]; then
    printf 'Outcome log %s is empty.\n' "$LOG_PATH"
    printf 'Do not auto-edit config/crew-dispatch.json from this tool.\n'
    return 0
  fi

  # Walk newest-first, keep up to limit matching lines.
  local -a matched=()
  local i line kind repo
  for ((i = total - 1; i >= 0; i--)); do
    line=${LOG_LINES[i]}
    [ -n "$line" ] || continue
    if [ -n "$kind_filter" ]; then
      kind=$(field_from_json_line "$line" kind)
      [ "$kind" = "$kind_filter" ] || continue
    fi
    if [ -n "$repo_filter" ]; then
      repo=$(field_from_json_line "$line" repo)
      [ "$repo" = "$repo_filter" ] || continue
    fi
    matched+=("$line")
    [ "${#matched[@]}" -ge "$limit" ] && break
  done

  local n=${#matched[@]}
  printf 'Dispatch outcome bias (newest %s matching of %s total in %s)\n' "$n" "$total" "$LOG_PATH"
  if [ -n "$kind_filter" ] || [ -n "$repo_filter" ]; then
    printf 'Filters: kind=%s repo=%s\n' "${kind_filter:-*}" "${repo_filter:-*}"
  fi
  if [ "$n" -eq 0 ]; then
    printf 'No matching outcomes.\n'
    printf 'Do not auto-edit config/crew-dispatch.json from this tool.\n'
    return 0
  fi

  # Aggregate with temp TSV + awk so this stays Bash 3.2-safe (no associative arrays).
  local tmpdir rows
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-dispatch-outcome.XXXXXX") || die "mktemp failed"
  rows="$tmpdir/rows.tsv"
  : >"$rows"

  local outcome harness model effort profile kr
  local done_n=0 failed_n=0 escalated_n=0 blocked_n=0 other_n=0

  for line in "${matched[@]}"; do
    outcome=$(field_from_json_line "$line" outcome)
    harness=$(field_from_json_line "$line" harness)
    model=$(field_from_json_line "$line" model)
    effort=$(field_from_json_line "$line" effort)
    kind=$(field_from_json_line "$line" kind)
    repo=$(field_from_json_line "$line" repo)
    [ -n "$harness" ] || harness='?'
    [ -n "$model" ] || model='?'
    [ -n "$effort" ] || effort='?'
    [ -n "$kind" ] || kind='?'
    [ -n "$repo" ] || repo='?'
    outcome=$(tsv_safe "$outcome")
    harness=$(tsv_safe "$harness")
    model=$(tsv_safe "$model")
    effort=$(tsv_safe "$effort")
    kind=$(tsv_safe "$kind")
    repo=$(tsv_safe "$repo")
    profile="${harness}/${model}/${effort}"
    kr="${kind} / ${repo}"
    # TSV: outcome, kind_repo, profile (no tabs expected in these fields)
    printf '%s\t%s\t%s\n' "$outcome" "$kr" "$profile" >>"$rows"
    case "$outcome" in
      done) done_n=$((done_n + 1)) ;;
      failed) failed_n=$((failed_n + 1)) ;;
      escalated) escalated_n=$((escalated_n + 1)) ;;
      blocked) blocked_n=$((blocked_n + 1)) ;;
      *) other_n=$((other_n + 1)) ;;
    esac
  done

  printf 'Outcomes: done=%s failed=%s escalated=%s blocked=%s other=%s\n' \
    "$done_n" "$failed_n" "$escalated_n" "$blocked_n" "$other_n"

  printf 'By kind/repo:\n'
  awk -F'\t' '
    {
      total[$2]++
      if ($1 == "done") done[$2]++
    }
    END {
      for (k in total) {
        d = (k in done) ? done[k] : 0
        printf "  %s: done %s/%s\n", k, d, total[k]
      }
    }
  ' "$rows" | LC_ALL=C sort

  printf 'By profile (harness/model/effort):\n'
  awk -F'\t' '
    {
      profiles[$3] = 1
      if ($1 == "done") done[$3]++
      else if ($1 == "failed") failed[$3]++
      else other[$3]++
    }
    END {
      for (p in profiles) {
        d = (p in done) ? done[p] : 0
        f = (p in failed) ? failed[p] : 0
        o = (p in other) ? other[p] : 0
        printf "  %s: done=%s failed=%s other=%s\n", p, d, f, o
      }
    }
  ' "$rows" | LC_ALL=C sort

  # Highest done-count profile among those with any done ending (profile\tcount).
  local best_line best best_done
  best_line=$(awk -F'\t' '
    $1 == "done" { done[$3]++ }
    END {
      best = ""; best_n = 0
      for (p in done) {
        if (done[p] > best_n) { best_n = done[p]; best = p }
      }
      if (best != "") printf "%s\t%s\n", best, best_n
    }
  ' "$rows")
  if [ -n "$best_line" ]; then
    best=$(printf '%s\n' "$best_line" | awk -F'\t' '{print $1}')
    best_done=$(printf '%s\n' "$best_line" | awk -F'\t' '{print $2}')
    printf 'Bias (heuristic, not auto-applied): among recent matches, %s has the most done endings (%s).\n' \
      "$best" "$best_done"
  else
    printf 'Bias (heuristic, not auto-applied): no done endings in the matching window.\n'
  fi
  printf 'Use this only as intake judgment input. Do not auto-edit config/crew-dispatch.json.\n'
  rm -rf "$tmpdir"
}

main() {
  local cmd=${1:-}
  if [ -z "$cmd" ]; then
    usage
    exit 2
  fi
  shift || true
  case "$cmd" in
    record)
      cmd_record "$@"
      ;;
    suggest)
      cmd_suggest "$@"
      ;;
    show)
      cmd_show "$@"
      ;;
    help|-h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown command '$cmd' (want record|suggest|show|help)"
      ;;
  esac
}

main "$@"
