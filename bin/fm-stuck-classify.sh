#!/usr/bin/env bash
# fm-stuck-classify.sh - thin capability-stuck classifier and one-step
# escalate-on-stuck detection for a Firstmate operational home.
#
# Product intent: outcome memory already records endings and documents escalate
# policy (docs/dispatch-outcome-memory.md). This helper is the missing automated
# detection layer: pure classify from durable evidence, fail-closed one-step
# escalate onto a stronger standing crew-dispatch profile only, with audit trail
# and a hard thrash cap (no second auto-escalate on the same attempt).
#
# Commands:
#   classify [evidence flags...]
#       Pure decision. Prints verdict + reason + metrics fields. Exit 0 always
#       on a successful classify; exit 2 on usage error. By default, appends the
#       decision to FM_HOME/data/stuck-classify-decisions.jsonl, or to the data
#       root selected by FM_DATA_OVERRIDE. Each record contains the UTC timestamp,
#       optional task id, normalized evidence and metrics fields, verdict, reason
#       code, and detail. Set FM_STUCK_CLASSIFY_LOG=off to retain decision-only
#       behavior with no I/O, or set it to a path to override the log. Append
#       failures are reported on stderr but never change the decision or exit
#       status. Never spawns, never mutates dispatch config, never treats worker
#       self-report alone as enough.
#   resolve-stronger --from-profile <h[/m[/e]]> [--dispatch <path>]
#       Read-only: pick the next standing profile with a strictly greater public
#       strength value. Never invents harness/model/effort.
#   escalate <prior-id> --target-profile <h[/m[/e]]> [--dispatch <path>]
#            [--note "..."] --new-id <id> --reserve|--commit
#       Fail-closed apply path for a prior attempt already classified escalate:
#         1) refuse when prior meta already has escalated_from= (anti-lazy /
#            thrash cap: no second auto-escalate on the same attempt)
#         2) verify target_profile is the resolver's stronger standing profile
#         3) reserve the linkage after a durable escalate decision
#         4) spawn with the returned reservation_id and commit only after
#            follow-on metadata matches the reservation and target profile
#         5) append linkage and record the prior outcome as escalated
#   help | -h | --help
#       Print this header.
#
# Classify evidence flags (all optional with safe defaults that refuse escalate):
#   --endpoint-alive yes|no     omitted evidence returns uncertain
#   --crew-state <state>        working|parked|done|blocked|paused|failed|unknown
#                               (from fm-crew-state.sh vocabulary)
#   --failure-class <class>     capability|infra|external-wait|declared-pause|
#                               dead-endpoint|validation-advancing|ambiguous
#                               (default ambiguous)
#   --same-failure yes|no       same acceptance / product failure surface
#   --fix-attempts <N>          real fix rounds on that surface (default 0)
#   --recovery-exhausted yes|no stuck-worker recovery done on same product failure
#   --self-report-only yes|no   worker complaint with no failed-acceptance evidence
#   --already-escalated yes|no  this attempt already carries escalated_from=
#   --id <task-id>              optional: read already-escalated from state/<id>.meta
#   --n <N>                     capability-stuck threshold (default 2; env
#                               FM_STUCK_CLASSIFY_N overrides when --n omitted)
#   --json                      emit one JSON object instead of key=value lines
#
# Default N=2 means "same product failure after >=2 real fix attempts" with
# stuck-worker recovery exhausted on that same failure. The threshold remains
# tunable so operational evidence can raise or lower N without a rewrite.
#
# Verdicts:
#   escalate  - preconditions hold and capability-stuck signals fire
#   refuse    - explicit non-escalate class or missing evidence
#   uncertain - incomplete evidence; fail safe to operator, not silent escalate
#
# Reason codes (stable for metrics):
#   dead_endpoint, endpoint_not_alive, parked_operator, validation_advancing,
#   declared_pause, infra, external_wait, already_escalated, below_threshold,
#   self_report_only, ambiguous, unknown_crew_state, not_same_failure,
#   recovery_not_exhausted, terminal_state, missing_endpoint_evidence,
#   missing_escalation_history
#
# Safety:
#   - No network.
#   - Never auto-edits config/crew-dispatch.json.
#   - Never mid-session model gateway / proxy rewrite.
#   - Never second auto-escalate when escalated_from is already set.
#   - blocked vs escalated stay distinct: infra/external go refuse/blocked,
#     capability goes escalate/escalated.
#   - Self-report alone never escalates.
#
# See docs/dispatch-outcome-memory.md for policy, call sites, and non-goals.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
if [ -d "$FM_HOME" ]; then
  resolved_fm_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || resolved_fm_home=
  [ -z "$resolved_fm_home" ] || FM_HOME=$resolved_fm_home
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DEFAULT_DISPATCH="$CONFIG/crew-dispatch.json"
OUTCOME_BIN="${FM_DISPATCH_OUTCOME_BIN:-$SCRIPT_DIR/fm-dispatch-outcome.sh}"
DEFAULT_N="${FM_STUCK_CLASSIFY_N:-2}"
DECISION_LOG="${FM_STUCK_CLASSIFY_LOG:-$DATA/stuck-classify-decisions.jsonl}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-crew-dispatch-lib.sh
. "$SCRIPT_DIR/fm-crew-dispatch-lib.sh"
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-stuck-classify: %s\n' "$*" >&2
  exit 2
}

log_err() {
  printf 'fm-stuck-classify: %s\n' "$*" >&2
}

decision_log_parent() {
  local parent=$1 resolved parent_path
  case "$parent" in
    /*) parent_path=$parent ;;
    *) parent_path="$PWD/$parent" ;;
  esac
  decision_log_parent_has_unsafe_symlink "$parent_path" && return 1
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    if [ -L "$parent" ]; then
      case "$parent_path" in
        /var|/tmp) ;;
        *) return 1 ;;
      esac
    else
      [ -d "$parent" ] || return 1
    fi
  else
    mkdir -p "$parent" 2>/dev/null || return 1
  fi
  if [ -L "$parent" ]; then
    case "$parent_path" in
      /var|/tmp) ;;
      *) return 1 ;;
    esac
  else
    [ -d "$parent" ] || return 1
  fi
  decision_log_parent_has_unsafe_symlink "$parent_path" && return 1
  resolved=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  [ -d "$resolved" ] && [ ! -L "$resolved" ]
}

decision_log_parent_has_unsafe_symlink() {
  local path=$1 current rest component
  case "$path" in
    /*) current=/; rest=${path#/} ;;
    *) current=$PWD; rest=$path ;;
  esac
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$rest" = "$component" ]; then
      rest=
    else
      rest=${rest#*/}
    fi
    case "$component" in
      ''|.) continue ;;
      ..) current=$(dirname "$current") ;;
      *)
        current="${current%/}/$component"
        if [ -L "$current" ]; then
          case "$current" in
            /var|/tmp) ;;
            *) return 0 ;;
          esac
        fi
        ;;
    esac
  done
  return 1
}

decision_log_lock_dir_safe() {
  local path=$1 entry name owner_pid
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  if [ ! -d "$path" ] || [ -L "$path" ]; then
    [ -e "$path" ] || [ -L "$path" ] || return 2
    return 1
  fi
  for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      pid|writer|fm-home|pid-identity|watcher-path)
        if [ ! -f "$entry" ] || [ -L "$entry" ]; then
          [ -e "$entry" ] || [ -L "$entry" ] || return 2
          return 1
        fi
        ;;
      *)
        return 1
        ;;
    esac
  done
  if [ -e "$path/pid" ] || [ -L "$path/pid" ]; then
    owner_pid=$(cat "$path/pid" 2>/dev/null) || {
      [ -e "$path/pid" ] || [ -L "$path/pid" ] || return 2
      return 1
    }
    case "$owner_pid" in
      '') return 2 ;;
      *[!0-9]*) return 1 ;;
    esac
  fi
  return 0
}

decision_log_lock_path_safe() {
  local path=$1 owner owner_parent lock_parent owner_base lock_base path_status
  path=$(fm_lock_abs_path "$path") || return 1
  if [ -L "$path" ]; then
    owner=$(readlink "$path" 2>/dev/null || true)
    if [ -z "$owner" ]; then
      [ -L "$path" ] || return 2
      return 1
    fi
    case "$owner" in
      /*) path=$owner ;;
      *) path="$(dirname "$path")/$owner" ;;
    esac
    owner=$(fm_lock_abs_path "$path") || return 1
    owner_parent=$(dirname "$owner")
    lock_parent=$(dirname "$(fm_lock_abs_path "$1")") || return 1
    [ "$owner_parent" = "$lock_parent" ] || return 1
    owner_base=$(basename "$owner")
    lock_base=$(basename "$(fm_lock_abs_path "$1")") || return 1
    case "$owner_base" in
      "$lock_base".owner.*) ;;
      *) return 1 ;;
    esac
    if [ -e "$owner" ] || [ -L "$owner" ]; then
      decision_log_lock_dir_safe "$owner"
      return $?
    fi
    return 0
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    decision_log_lock_dir_safe "$path"
    path_status=$?
    [ "$path_status" -eq 0 ] && return 0
    return "$path_status"
  fi
  return 0
}

acquire_decision_log_lock() {
  local lock=$1 timeout now deadline path_status rc
  lock=$(fm_lock_abs_path "$lock") || return 125
  timeout=${FM_LOCK_ACQUIRE_WAIT_TIMEOUT:-${FM_LOCK_ACQUIRE_WAIT_TIMEOUT_DEFAULT:-10}}
  case "$timeout" in
    ''|*[!0-9]*) timeout=${FM_LOCK_ACQUIRE_WAIT_TIMEOUT_DEFAULT:-10} ;;
    *) timeout=$((10#$timeout)) ;;
  esac
  [ "$timeout" -gt 0 ] || timeout=${FM_LOCK_ACQUIRE_WAIT_TIMEOUT_DEFAULT:-10}
  now=$(date +%s) || return 1
  deadline=$((now + timeout))
  while :; do
    if decision_log_lock_path_safe "$lock"; then
      :
    else
      path_status=$?
      [ "$path_status" -eq 2 ] || return 1
      now=$(date +%s) || return 1
      [ "$now" -lt "$deadline" ] || return 1
      sleep 0.02
      continue
    fi
    if decision_log_lock_path_safe "$lock.steal"; then
      :
    else
      path_status=$?
      [ "$path_status" -eq 2 ] || return 1
      now=$(date +%s) || return 1
      [ "$now" -lt "$deadline" ] || return 1
      sleep 0.02
      continue
    fi
    if fm_lock_try_acquire "$lock"; then
      return 0
    else
      rc=$?
    fi
    [ "$rc" -eq 125 ] && return 125
    now=$(date +%s) || return 1
    [ "$now" -lt "$deadline" ] || return 1
    sleep 0.02
  done
}

append_classify_decision_record() {
  local parent=$1 base=$2 line=$3
  command -v perl >/dev/null 2>&1 || return 1
  perl - "$parent" "$base" "$line" <<'PERL'
use strict;
use warnings;
use Errno qw(EEXIST ENOENT);
use Fcntl qw(:DEFAULT :flock);
use IO::Handle ();
use JSON::PP ();

my ($parent_path, $base, $line) = @ARGV;
defined $parent_path && defined $base && defined $line or exit 1;
$line !~ /[\r\n]/ or exit 1;
eval { JSON::PP::decode_json($line); 1 } or exit 1;

sub open_parent_dir {
  my ($path) = @_;
  my $absolute = $path =~ /\A\//;
  chdir "/" if $absolute;
  my @dirs;
  sysopen(my $current, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or return;
  push @dirs, $current;
  my $component_index = 0;
  for my $component (split m{/}, $path, -1) {
    next if $component eq '' || $component eq '.';
    my $flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW;
    if ($absolute && $component_index == 0 && ($component eq 'var' || $component eq 'tmp')) {
      $flags = O_RDONLY | O_DIRECTORY;
    }
    sysopen(my $next, "./$component", $flags) or return;
    chdir $next or return;
    push @dirs, $next;
    $component_index++;
  }
  return \@dirs;
}

my $parent_dirs = open_parent_dir($parent_path);
defined $parent_dirs or exit 1;
my $parent_lock_deadline = time + 1;
while (!flock($parent_dirs->[-1], LOCK_EX | LOCK_NB)) {
  time >= $parent_lock_deadline and exit 1;
  select undef, undef, undef, 0.01;
}
my $file_path = "./$base";
my $pending_path = "./$base.pending";
my $file;
if (!sysopen($file, $file_path, O_RDWR | O_APPEND | O_NOFOLLOW)) {
  $! == ENOENT or exit 1;
  sysopen($file, $file_path, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or exit 1;
}

my @path_stat = lstat($file_path) or exit 1;
my @file_stat = stat($file) or exit 1;
-f $file or exit 1;
$path_stat[0] == $file_stat[0] && $path_stat[1] == $file_stat[1] or exit 1;
$file_stat[3] == 1 or exit 1;

sub read_all {
  my ($fh) = @_;
  seek($fh, 0, 0) or return;
  local $/;
  my $content = <$fh>;
  return defined $content ? $content : '';
}

sub write_all {
  my ($fh, $content) = @_;
  my $written = 0;
  while ($written < length($content)) {
    my $count = syswrite($fh, $content, length($content) - $written, $written);
    return 0 if !defined $count || $count == 0;
    $written += $count;
  }
  return 1;
}

sub read_range {
  my ($fh, $offset, $length) = @_;
  seek($fh, $offset, 0) or return;
  my $content = '';
  while (length($content) < $length) {
    my $count = sysread($fh, $content, $length - length($content), length($content));
    return if !defined $count || $count == 0;
  }
  return $content;
}

sub fsync_handle {
  my ($fh) = @_;
  my $result = $fh->sync();
  return defined $result;
}

sub read_last_record {
  my ($fh, $size) = @_;
  return if $size == 0;
  my $last_byte = read_range($fh, $size - 1, 1);
  defined $last_byte or return;
  my $has_final_newline = $last_byte eq "\n";
  my $record_end = $has_final_newline ? $size - 1 : $size;
  my $search_end = $record_end;
  my $record_start = 0;
  my $chunk_size = 64 * 1024;
  my $record_limit = 1024 * 1024;
  while ($search_end > 0) {
    my $chunk_start = $search_end > $chunk_size ? $search_end - $chunk_size : 0;
    my $chunk = read_range($fh, $chunk_start, $search_end - $chunk_start);
    defined $chunk or return;
    my $break = rindex($chunk, "\n");
    if ($break >= 0) {
      $record_start = $chunk_start + $break + 1;
      last;
    }
    return if $record_end - $chunk_start > $record_limit;
    $search_end = $chunk_start;
  }
  my $record_length = $record_end - $record_start;
  return if $record_length <= 0 || $record_length > $record_limit;
  my $record = read_range($fh, $record_start, $record_length);
  defined $record or return;
  return ($record, $has_final_newline);
}

my $size = $file_stat[7];
defined $size && $size =~ /\A\d+\z/ or exit 1;

my $pending;
my $pending_payload;
my $had_pending = 0;
if (!sysopen($pending, $pending_path, O_RDWR | O_NOFOLLOW)) {
  $! == ENOENT or exit 1;
} else {
  $had_pending = 1;
  my @pending_path_stat = lstat($pending_path) or exit 1;
  my @pending_stat = stat($pending) or exit 1;
  -f $pending or exit 1;
  $pending_path_stat[0] == $pending_stat[0] && $pending_path_stat[1] == $pending_stat[1] or exit 1;
  $pending_stat[3] == 1 or exit 1;
  my $pending_content = read_all($pending);
  defined $pending_content or exit 1;
  my $pending_first_break = index($pending_content, "\n");
  $pending_first_break > 0 or exit 1;
  my $pending_first_text = substr($pending_content, 0, $pending_first_break);
  my $pending_second_break = index($pending_content, "\n", $pending_first_break + 1);
  my $pending_start_text;
  if ($pending_second_break > $pending_first_break + 1 &&
      $pending_first_text =~ /\A\d+\z/ &&
      substr($pending_content, $pending_first_break + 1, $pending_second_break - $pending_first_break - 1) =~ /\A\d+\z/) {
    my $pending_third_break = index($pending_content, "\n", $pending_second_break + 1);
    $pending_third_break > $pending_second_break + 1 or exit 1;
    my $pending_dev_text = $pending_first_text;
    my $pending_ino_text = substr($pending_content, $pending_first_break + 1, $pending_second_break - $pending_first_break - 1);
    $pending_dev_text =~ /\A\d+\z/ && $pending_ino_text =~ /\A\d+\z/ or exit 1;
    if (0 + $pending_dev_text != $file_stat[0] || 0 + $pending_ino_text != $file_stat[1]) {
      close($pending) or exit 1;
      unlink($pending_path) or exit 1;
      exit 1;
    }
    $pending_start_text = substr($pending_content, $pending_second_break + 1, $pending_third_break - $pending_second_break - 1);
    $pending_payload = substr($pending_content, $pending_third_break + 1);
  } else {
    close($pending) or exit 1;
    rename($pending_path, "$pending_path.legacy.$$") or exit 1;
    undef $pending;
    $had_pending = 0;
  }
  if ($had_pending) {
    $pending_start_text =~ /\A\d+\z/ or exit 1;
    my $pending_start = 0 + $pending_start_text;
    length($pending_payload) > 0 && substr($pending_payload, -1) eq "\n" or exit 1;
    my $pending_end = $pending_start + length($pending_payload);
    my $pending_prefix_length = $size >= $pending_start ? $size - $pending_start : 0;
    my $pending_prefix = $pending_prefix_length > 0
      ? read_range($file, $pending_start, $pending_prefix_length)
      : '';
    defined $pending_prefix or exit 1;
    if ($size >= $pending_end && substr($pending_prefix, 0, length($pending_payload)) eq $pending_payload) {
      unlink($pending_path) or exit 1;
      fsync_handle($parent_dirs->[-1]) or exit 1;
      close($pending) or exit 1;
      undef $pending;
      undef $pending_payload;
    } elsif ($size >= $pending_start && $size < $pending_end &&
        $pending_prefix eq substr($pending_payload, 0, $pending_prefix_length)) {
      truncate($file, $pending_start) or exit 1;
      seek($file, 0, 2) or exit 1;
      write_all($file, $pending_payload) or exit 1;
      fsync_handle($file) or exit 1;
      $size = $pending_end;
      unlink($pending_path) or exit 1;
      fsync_handle($parent_dirs->[-1]) or exit 1;
      close($pending) or exit 1;
      undef $pending;
      undef $pending_payload;
    } elsif ($size == $pending_start) {
      seek($file, 0, 2) or exit 1;
      write_all($file, $pending_payload) or exit 1;
      fsync_handle($file) or exit 1;
      $size = $pending_end;
      unlink($pending_path) or exit 1;
      fsync_handle($parent_dirs->[-1]) or exit 1;
      close($pending) or exit 1;
      undef $pending;
      undef $pending_payload;
    } else {
      exit 1;
    }
  }
}

my $separator = '';
if ($size > 0) {
  my ($record, $has_final_newline) = read_last_record($file, $size);
  defined $record or exit 1;
  if (!$has_final_newline) {
    $separator = "\n";
  }
  eval { JSON::PP::decode_json($record); 1 } or exit 1;
}

my $payload = $separator . $line . "\n";
my $start = $size;
my $pending_tmp = "$base.pending.$$";
my $pending_writer;
sysopen($pending_writer, $pending_tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or exit 1;
if (!write_all($pending_writer, "$file_stat[0]\n$file_stat[1]\n$start\n$payload") ||
    !fsync_handle($pending_writer) || !close($pending_writer) || !rename($pending_tmp, $pending_path) ||
    !fsync_handle($parent_dirs->[-1])) {
  close($pending_writer);
  unlink $pending_tmp;
  exit 1;
}

write_all($file, $payload) or exit 1;
fsync_handle($file) or exit 1;
my @after_stat = stat($file) or exit 1;
if ($after_stat[7] != $start + length($payload) || $after_stat[3] != 1) {
  exit 1;
}
my @after_path_stat = lstat($file_path) or exit 1;
if ($after_path_stat[0] != $after_stat[0] || $after_path_stat[1] != $after_stat[1]) {
  unlink($pending_path) or exit 1;
  exit 1;
}
my $integrity_path = "./$base.integrity";
my $integrity_writer;
if (!sysopen($integrity_writer, $integrity_path, O_RDWR | O_NOFOLLOW)) {
  $! == ENOENT or exit 1;
  sysopen($integrity_writer, $integrity_path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or exit 1;
}
my @integrity_path_stat = lstat($integrity_path) or exit 1;
my @integrity_stat = stat($integrity_writer) or exit 1;
-f $integrity_writer or exit 1;
$integrity_path_stat[0] == $integrity_stat[0] && $integrity_path_stat[1] == $integrity_stat[1] or exit 1;
$integrity_stat[3] == 1 or exit 1;
my $integrity_count = 0;
my $integrity_previous = read_all($integrity_writer);
if (defined $integrity_previous) {
  my @integrity_fields = split /\n/, $integrity_previous, -1;
  pop @integrity_fields if @integrity_fields && $integrity_fields[-1] eq '';
  $integrity_count = $integrity_fields[6] if @integrity_fields == 7 && $integrity_fields[6] =~ /\A\d+\z/;
}
$integrity_count++;
my $integrity_content = "$after_stat[0]\n$after_stat[1]\n$after_stat[7]\n$after_stat[9]\n$after_stat[10]\n1\n$integrity_count\n";
truncate($integrity_writer, 0) or exit 1;
seek($integrity_writer, 0, 0) or exit 1;
if (!write_all($integrity_writer, $integrity_content) ||
    ($integrity_count % 16 == 0 && !fsync_handle($integrity_writer)) ||
    !close($integrity_writer)) {
  close($integrity_writer);
  exit 1;
}
unlink($pending_path) or exit 1;
fsync_handle($parent_dirs->[-1]) or exit 1;
PERL
}

validate_classify_decision_stream() {
  local parent=$1 base=$2 timeout now deadline status
  command -v perl >/dev/null 2>&1 || return 1
  timeout=${FM_LOCK_ACQUIRE_WAIT_TIMEOUT:-${FM_LOCK_ACQUIRE_WAIT_TIMEOUT_DEFAULT:-10}}
  case "$timeout" in
    ''|*[!0-9]*) timeout=${FM_LOCK_ACQUIRE_WAIT_TIMEOUT_DEFAULT:-10} ;;
    *) timeout=$((10#$timeout)) ;;
  esac
  [ "$timeout" -gt 0 ] || timeout=${FM_LOCK_ACQUIRE_WAIT_TIMEOUT_DEFAULT:-10}
  now=$(date +%s) || return 1
  deadline=$((now + timeout))
  while :; do
    perl - "$parent" "$base" <<'PERL'
use strict;
use warnings;
use Errno qw(ENOENT);
use Fcntl qw(:DEFAULT);
use JSON::PP ();

my ($parent_path, $base) = @ARGV;
defined $parent_path && defined $base && $base !~ m{/} or exit 1;

sub open_parent_dir {
  my ($path) = @_;
  my $absolute = $path =~ /\A\//;
  chdir "/" if $absolute;
  my @dirs;
  sysopen(my $current, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or return;
  push @dirs, $current;
  my $component_index = 0;
  for my $component (split m{/}, $path, -1) {
    next if $component eq '' || $component eq '.';
    my $flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW;
    if ($absolute && $component_index == 0 && ($component eq 'var' || $component eq 'tmp')) {
      $flags = O_RDONLY | O_DIRECTORY;
    }
    sysopen(my $next, "./$component", $flags) or return;
    chdir $next or return;
    push @dirs, $next;
    $component_index++;
  }
  return \@dirs;
}

my $parent_dirs = open_parent_dir($parent_path);
defined $parent_dirs or exit 1;
my $file_path = "./$base";
my $file;
if (!sysopen($file, $file_path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)) {
  exit($! == ENOENT ? 0 : 1);
}
my @path_stat = lstat($file_path) or exit 1;
my @file_stat = stat($file) or exit 1;
-f $file or exit 1;
$path_stat[0] == $file_stat[0] && $path_stat[1] == $file_stat[1] or exit 1;
$file_stat[3] == 1 or exit 1;

sub finish_validation {
  my ($fh, $initial_stat, $valid) = @_;
  my @current_stat = stat($fh);
  if (!@current_stat || $current_stat[0] != $initial_stat->[0] ||
      $current_stat[1] != $initial_stat->[1] || $current_stat[7] != $initial_stat->[7] ||
      $current_stat[9] != $initial_stat->[9] || $current_stat[10] != $initial_stat->[10]) {
    exit 2;
  }
  exit($valid ? 0 : 1);
}
sub read_all {
  my ($fh) = @_;
  seek($fh, 0, 0) or return;
  local $/;
  my $content = <$fh>;
  return defined $content ? $content : '';
}

sub read_range {
  my ($fh, $offset, $length) = @_;
  return '' if $length == 0;
  seek($fh, $offset, 0) or return;
  my $content = '';
  while (length($content) < $length) {
    my $count = sysread($fh, $content, $length - length($content), length($content));
    return if !defined $count || $count == 0;
  }
  return $content;
}

sub valid_stream {
  my ($content) = @_;
  return 1 if $content eq '';
  my @records = split /\n/, $content, -1;
  pop @records if substr($content, -1) eq "\n";
  for my $record (@records) {
    length($record) > 0 or return 0;
    eval { JSON::PP::decode_json($record); 1 } or return 0;
  }
  return 1;
}

sub validate_range {
  my ($fh, $start, $end) = @_;
  return 0 if $start < 0 || $end < $start;
  my $content = read_range($fh, $start, $end - $start);
  return 0 if !defined $content;
  return 0 if $end > $start && substr($content, -1) ne "\n";
  return valid_stream($content);
}

sub validate_pending_prefix {
  my ($fh, $pending_start, $pending_payload) = @_;
  my $prefix = read_range($fh, 0, $pending_start);
  defined $prefix or return 0;
  return valid_stream($prefix) if $pending_start == 0 || substr($prefix, -1) eq "\n";
  return 0 unless substr($pending_payload, 0, 1) eq "\n";
  return valid_stream($prefix . $pending_payload);
}

sub read_checkpoint {
  my ($path, $file_stat) = @_;
  my $fh;
  if (!sysopen($fh, $path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)) {
    return if $! == ENOENT;
    return;
  }
  my @path_stat = lstat($path) or return;
  my @stat = stat($fh) or return;
  -f $fh && $path_stat[0] == $stat[0] && $path_stat[1] == $stat[1] && $stat[3] == 1 or return;
  my $content = read_all($fh);
  return if !defined $content;
  my @fields = split /\n/, $content, -1;
  pop @fields if @fields && $fields[-1] eq '';
  return if @fields != 7;
  for my $field (@fields) {
    return unless defined $field && $field =~ /\A\d+\z/;
  }
  return if $fields[0] != $file_stat->[0] || $fields[1] != $file_stat->[1];
  return if $fields[5] != 1 || $fields[2] != $file_stat->[7];
  return \@fields;
}

my $checkpoint = read_checkpoint("./$base.integrity", \@file_stat);
my $validated_offset = 0;
my $checkpoint_valid = 0;
if (defined $checkpoint) {
  my $checkpoint_size = 0 + $checkpoint->[2];
  if ($checkpoint_size == $file_stat[7] &&
      $checkpoint->[3] == $file_stat[9] && $checkpoint->[4] == $file_stat[10]) {
    $checkpoint_valid = 1;
    $validated_offset = $checkpoint_size;
  }
}
my $pending_path = "./$base.pending";
my $pending;
if (!sysopen($pending, $pending_path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)) {
  if ($! != ENOENT) {
    exit 1;
  }
  if (!$checkpoint_valid) {
    my $file_content = read_all($file);
    finish_validation($file, \@file_stat, defined $file_content && valid_stream($file_content));
  }
  finish_validation($file, \@file_stat, validate_range($file, $validated_offset, $file_stat[7]));
}
my @pending_path_stat = lstat($pending_path) or exit 1;
my @pending_stat = stat($pending) or exit 1;
-f $pending or exit 1;
$pending_path_stat[0] == $pending_stat[0] && $pending_path_stat[1] == $pending_stat[1] or exit 1;
$pending_stat[3] == 1 or exit 1;
my $pending_content = read_all($pending);
defined $pending_content or exit 1;
my $pending_first_break = index($pending_content, "\n");
$pending_first_break > 0 or exit 1;
my $pending_first_text = substr($pending_content, 0, $pending_first_break);
my $pending_second_break = index($pending_content, "\n", $pending_first_break + 1);
if ($pending_second_break > $pending_first_break + 1 &&
    $pending_first_text =~ /\A\d+\z/ &&
    substr($pending_content, $pending_first_break + 1, $pending_second_break - $pending_first_break - 1) =~ /\A\d+\z/) {
  my $pending_third_break = index($pending_content, "\n", $pending_second_break + 1);
  $pending_third_break > $pending_second_break + 1 or exit 1;
  my $pending_dev_text = $pending_first_text;
  my $pending_ino_text = substr($pending_content, $pending_first_break + 1, $pending_second_break - $pending_first_break - 1);
  0 + $pending_dev_text == $file_stat[0] && 0 + $pending_ino_text == $file_stat[1] or exit 1;
  my $pending_start_text = substr($pending_content, $pending_second_break + 1, $pending_third_break - $pending_second_break - 1);
  $pending_start_text =~ /\A\d+\z/ or exit 1;
  my $pending_start = 0 + $pending_start_text;
  my $pending_payload = substr($pending_content, $pending_third_break + 1);
  length($pending_payload) > 0 && substr($pending_payload, -1) eq "\n" or exit 1;
  my $pending_end = $pending_start + length($pending_payload);
  $pending_end <= $file_stat[7] or exit 1 if $checkpoint_valid && $validated_offset > $pending_start;
  if ($checkpoint_valid && $validated_offset > $pending_start) {
    finish_validation($file, \@file_stat, validate_range($file, $validated_offset, $file_stat[7]));
  }
  $pending_start >= $validated_offset or exit 1 if $checkpoint_valid;
  validate_pending_prefix($file, $pending_start, $pending_payload) or exit 1;
  my $pending_suffix = read_range($file, $pending_start, $file_stat[7] - $pending_start);
  defined $pending_suffix or exit 1;
  index($pending_payload, $pending_suffix) == 0 or exit 1;
  if (length($pending_suffix) >= length($pending_payload)) {
    valid_stream(substr($pending_suffix, length($pending_payload))) or exit 1;
  }
  finish_validation($file, \@file_stat, 1);
}
if (!$checkpoint_valid) {
  my $file_content = read_all($file);
  finish_validation($file, \@file_stat, defined $file_content && valid_stream($file_content));
}
finish_validation($file, \@file_stat, validate_range($file, $validated_offset, $file_stat[7]));
PERL
    status=$?
    [ "$status" -ne 2 ] && return "$status"
    now=$(date +%s) || return 1
    [ "$now" -lt "$deadline" ] || return 1
    sleep 0.02
  done
}

append_classify_decision() {
  local line=$1 parent lock base
  parent=$(dirname "$DECISION_LOG") || return 1
  decision_log_parent "$parent" || return 1
  parent=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  [ -w "$parent" ] || return 1
  base=$(basename "$DECISION_LOG") || return 1
  if [ -e "$DECISION_LOG" ] || [ -L "$DECISION_LOG" ]; then
    [ -f "$DECISION_LOG" ] && [ ! -L "$DECISION_LOG" ] || return 1
  fi
  validate_classify_decision_stream "$parent" "$base" || return 1
  # shellcheck source=bin/fm-wake-lib.sh
  if ! . "$SCRIPT_DIR/fm-wake-lib.sh"; then
    return 1
  fi
  lock="$parent/$base.lock"
  acquire_decision_log_lock "$lock" || return 1
  append_classify_decision_record "$parent" "$base" "$line"
  local status=$?
  fm_lock_release "$lock" || true
  return "$status"
}

meta_value() {
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^${key}=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

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

norm_yesno() {
  local v
  v=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')
  case "$v" in
    yes|y|true|1) printf 'yes' ;;
    no|n|false|0) printf 'no' ;;
    *) return 1 ;;
  esac
}

normalize_decimal() {
  local value=$1
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  while [ "${#value}" -gt 1 ] && [ "${value#0}" != "$value" ]; do
    value=${value#0}
  done
  printf '%s' "$value"
}

profile_field_escape() {
  local value=${1-} out='' i c
  for ((i = 0; i < ${#value}; i++)); do
    c=${value:i:1}
    case "$c" in
      '%') out="${out}%25" ;;
      '|') out="${out}%7C" ;;
      $'\n') out="${out}%0A" ;;
      $'\r') out="${out}%0D" ;;
      $'\t') out="${out}%09" ;;
      $'\034') out="${out}%1C" ;;
      *) out="${out}${c}" ;;
    esac
  done
  printf '%s' "$out"
}

profile_field_unescape() {
  local value=${1-} out='' i=0 n code
  n=${#value}
  while [ "$i" -lt "$n" ]; do
    if [ "${value:i:1}" = '%' ]; then
      [ $((i + 2)) -lt "$n" ] || return 1
      code=${value:i+1:2}
      case "$code" in
        25) out="${out}%" ;;
        7C) out="${out}|" ;;
        0A) out="${out}"$'\n' ;;
        0D) out="${out}"$'\r' ;;
        09) out="${out}"$'\t' ;;
        1C) out="${out}"$'\034' ;;
        *) return 1 ;;
      esac
      i=$((i + 3))
    else
      out="${out}${value:i:1}"
      i=$((i + 1))
    fi
  done
  printf '%s' "$out"
}

profile_encode_fields() {
  printf '%s|%s|%s\n' \
    "$(profile_field_escape "${1-}")" \
    "$(profile_field_escape "${2-}")" \
    "$(profile_field_escape "${3-}")"
}

profile_parse_display() {
  local raw=${1-} rest suffix prefix
  raw=$(printf '%s' "$raw" | tr -d '[:space:]')
  [ -n "$raw" ] || return 1
  PROFILE_H=${raw%%/*}
  rest=${raw#"$PROFILE_H"}
  rest=${rest#/}
  PROFILE_M=''
  PROFILE_E=''
  if [ -n "$rest" ]; then
    suffix=${rest##*/}
    if [ "$(effort_rank "$suffix")" -gt 0 ] && [[ "$rest" = */* ]]; then
      prefix=${rest%"/$suffix"}
      PROFILE_M=${prefix#/}
      PROFILE_E=$suffix
    else
      PROFILE_M=$rest
    fi
  fi
  [ -n "$PROFILE_H" ] || return 1
}

profile_key() {
  profile_parse_display "${1-}" || return 1
  profile_encode_fields "$PROFILE_H" "$PROFILE_M" "$PROFILE_E"
}

effort_rank() {
  case "${1-}" in
    low) printf 1 ;;
    medium) printf 2 ;;
    high) printf 3 ;;
    xhigh) printf 4 ;;
    max) printf 5 ;;
    *) printf 0 ;;
  esac
}

profile_from_meta() {
  local meta=$1 h m e key
  h=$(meta_value "$meta" harness)
  m=$(meta_value "$meta" model)
  e=$(meta_value "$meta" effort)
  [ -n "$h" ] || return 1
  profile_encode_fields "$h" "$m" "$e"
}

cmd_classify() {
  local endpoint_alive='' crew_state='' failure_class='' same_failure=''
  local fix_attempts='' recovery_exhausted='' self_report_only='' already_escalated=''
  local id='' n_threshold='' as_json=0 decision_generation=''

  endpoint_alive=unknown
  crew_state=unknown
  failure_class=ambiguous
  same_failure=no
  fix_attempts=0
  recovery_exhausted=no
  self_report_only=no
  already_escalated=unknown
  n_threshold=$DEFAULT_N

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --endpoint-alive)
        [ "$#" -gt 1 ] || die "--endpoint-alive requires yes|no"
        endpoint_alive=$(norm_yesno "$2") || die "--endpoint-alive wants yes|no"
        shift 2
        ;;
      --endpoint-alive=*)
        endpoint_alive=$(norm_yesno "${1#--endpoint-alive=}") || die "--endpoint-alive wants yes|no"
        shift
        ;;
      --crew-state)
        [ "$#" -gt 1 ] || die "--crew-state requires a value"
        crew_state=$2
        shift 2
        ;;
      --crew-state=*)
        crew_state=${1#--crew-state=}
        shift
        ;;
      --failure-class)
        [ "$#" -gt 1 ] || die "--failure-class requires a value"
        failure_class=$2
        shift 2
        ;;
      --failure-class=*)
        failure_class=${1#--failure-class=}
        shift
        ;;
      --same-failure)
        [ "$#" -gt 1 ] || die "--same-failure requires yes|no"
        same_failure=$(norm_yesno "$2") || die "--same-failure wants yes|no"
        shift 2
        ;;
      --same-failure=*)
        same_failure=$(norm_yesno "${1#--same-failure=}") || die "--same-failure wants yes|no"
        shift
        ;;
      --fix-attempts)
        [ "$#" -gt 1 ] || die "--fix-attempts requires a non-negative integer"
        fix_attempts=$2
        shift 2
        ;;
      --fix-attempts=*)
        fix_attempts=${1#--fix-attempts=}
        shift
        ;;
      --recovery-exhausted)
        [ "$#" -gt 1 ] || die "--recovery-exhausted requires yes|no"
        recovery_exhausted=$(norm_yesno "$2") || die "--recovery-exhausted wants yes|no"
        shift 2
        ;;
      --recovery-exhausted=*)
        recovery_exhausted=$(norm_yesno "${1#--recovery-exhausted=}") || die "--recovery-exhausted wants yes|no"
        shift
        ;;
      --self-report-only)
        [ "$#" -gt 1 ] || die "--self-report-only requires yes|no"
        self_report_only=$(norm_yesno "$2") || die "--self-report-only wants yes|no"
        shift 2
        ;;
      --self-report-only=*)
        self_report_only=$(norm_yesno "${1#--self-report-only=}") || die "--self-report-only wants yes|no"
        shift
        ;;
      --already-escalated)
        [ "$#" -gt 1 ] || die "--already-escalated requires yes|no"
        already_escalated=$(norm_yesno "$2") || die "--already-escalated wants yes|no"
        shift 2
        ;;
      --already-escalated=*)
        already_escalated=$(norm_yesno "${1#--already-escalated=}") || die "--already-escalated wants yes|no"
        shift
        ;;
      --id)
        [ "$#" -gt 1 ] || die "--id requires a task id"
        id=$2
        shift 2
        ;;
      --id=*)
        id=${1#--id=}
        shift
        ;;
      --n)
        [ "$#" -gt 1 ] || die "--n requires a positive integer"
        n_threshold=$2
        shift 2
        ;;
      --n=*)
        n_threshold=${1#--n=}
        shift
        ;;
      --json)
        as_json=1
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
        die "unknown classify flag: $1"
        ;;
      *)
        die "unexpected classify argument: $1"
        ;;
    esac
  done

  case "$fix_attempts" in
    ''|*[!0-9]*) die "--fix-attempts must be a non-negative integer" ;;
  esac
  case "$n_threshold" in
    ''|*[!0-9]*) die "--n must be a positive integer" ;;
  esac
  fix_attempts=$(normalize_decimal "$fix_attempts") || die "--fix-attempts must be a non-negative integer"
  n_threshold=$(normalize_decimal "$n_threshold") || die "--n must be a positive integer"
  [ "$n_threshold" -ge 1 ] || die "--n must be >= 1"

  case "$crew_state" in
    working|parked|done|blocked|paused|failed|unknown) ;;
    *) die "invalid --crew-state '$crew_state'" ;;
  esac

  case "$failure_class" in
    capability|infra|external-wait|declared-pause|dead-endpoint|validation-advancing|ambiguous) ;;
    *) die "invalid --failure-class '$failure_class'" ;;
  esac

  if [ -n "$id" ]; then
    fm_task_id_path_safe "$id" || die "invalid task id '$id'"
    if [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ]; then
      local ef meta_snapshot
      meta_snapshot=$(<"$STATE/$id.meta")
      decision_generation=$(printf '%s\n' "$meta_snapshot" | awk -F= '$1 == "spawn_generation" { value=substr($0, index($0, "=") + 1) } END { print value }')
      if [ "$already_escalated" = unknown ]; then
        ef=$(printf '%s\n' "$meta_snapshot" | awk -F= '$1 == "escalated_from" { value=substr($0, index($0, "=") + 1) } END { print value }')
        if [ -n "$ef" ]; then
          already_escalated=yes
        else
          already_escalated=no
        fi
      fi
    fi
  fi

  local verdict=refuse reason='' detail=''

  # Explicit non-escalate classes first (ordered, stable reason codes).
  if [ "$failure_class" = dead-endpoint ]; then
    verdict=refuse
    reason=dead_endpoint
    detail='endpoint not alive; use stuck recovery, not profile escalate'
  elif [ "$endpoint_alive" = no ]; then
    verdict=refuse
    reason=endpoint_not_alive
    detail='endpoint not alive; use stuck recovery, not profile escalate'
  elif [ "$endpoint_alive" != yes ]; then
    verdict=uncertain
    reason=missing_endpoint_evidence
    detail='endpoint liveness evidence is missing; fail safe to operator, not silent escalate'
  elif [ "$already_escalated" = yes ]; then
    verdict=refuse
    reason=already_escalated
    detail='escalated_from already set; no second auto-escalate on this attempt'
  elif [ "$failure_class" = infra ]; then
    verdict=refuse
    reason=infra
    detail='infrastructure failure; log blocked, do not escalate profile'
  elif [ "$failure_class" = external-wait ]; then
    verdict=refuse
    reason=external_wait
    detail='external process wait; log blocked, do not escalate profile'
  elif [ "$crew_state" = parked ]; then
    verdict=refuse
    reason=parked_operator
    detail='operator gate, ask-user, merge wait, or external process wait'
  elif [ "$failure_class" = declared-pause ] || [ "$crew_state" = paused ]; then
    verdict=refuse
    reason=declared_pause
    detail='declared external wait; pause and recheck, do not escalate'
  elif [ "$failure_class" = validation-advancing ]; then
    verdict=refuse
    reason=validation_advancing
    detail='validation or CI still advancing; keep supervising'
  elif [ "$crew_state" = unknown ]; then
    verdict=uncertain
    reason=unknown_crew_state
    detail='durable crew state is unknown; fail safe to operator, not silent escalate'
  elif [ "$crew_state" = "done" ] || [ "$crew_state" = failed ]; then
    verdict=refuse
    reason=terminal_state
    detail="crew state is terminal ($crew_state); classify is for live stuck attempts"
  elif [ "$self_report_only" = yes ]; then
    verdict=refuse
    reason=self_report_only
    detail='worker self-report alone is never sufficient (anti-lazy-escape)'
  elif [ "$failure_class" = ambiguous ]; then
    verdict=uncertain
    reason=ambiguous
    detail='failure class ambiguous; fail safe to operator, not silent escalate'
  elif [ "$failure_class" != capability ]; then
    verdict=refuse
    reason=ambiguous
    detail="unhandled failure class '$failure_class'"
  elif [ "$same_failure" != yes ]; then
    verdict=refuse
    reason=not_same_failure
    detail='capability path requires same product failure surface across attempts'
  elif [ "$fix_attempts" -lt "$n_threshold" ]; then
    verdict=refuse
    reason=below_threshold
    detail="fix attempts $fix_attempts < N=$n_threshold"
  elif [ "$recovery_exhausted" != yes ]; then
    # Prefer recovery-exhausted when available; still allow escalate when
    # attempts already meet N on same capability failure and recovery flag is
    # explicitly no only if we want strictness. Heuristics: "recovery exhausted
    # on same narrow product failure" is a positive signal. For v1 default we
    # require either recovery_exhausted=yes OR fix_attempts >= N (already true)
    # with same_failure - require recovery_exhausted to reduce false escalate.
    verdict=refuse
    reason=recovery_not_exhausted
    detail='stuck-worker recovery not exhausted on the same product failure'
  elif [ "$already_escalated" = unknown ]; then
    verdict=uncertain
    reason=missing_escalation_history
    detail='anti-thrash evidence is missing; fail safe to operator, not silent escalate'
  else
    verdict=escalate
    reason=capability_stuck
    detail="alive + capability + same failure after >=$n_threshold attempts + recovery exhausted"
  fi

  local timestamp decision_id decision_json output_json
  printf -v output_json '{"verdict":"%s","reason":"%s","detail":"%s","endpoint_alive":"%s","crew_state":"%s","failure_class":"%s","same_failure":"%s","fix_attempts":%s,"n_threshold":%s,"recovery_exhausted":"%s","self_report_only":"%s","already_escalated":"%s","id":"%s"}' \
    "$(json_escape "$verdict")" \
    "$(json_escape "$reason")" \
    "$(json_escape "$detail")" \
    "$(json_escape "$endpoint_alive")" \
    "$(json_escape "$crew_state")" \
    "$(json_escape "$failure_class")" \
    "$(json_escape "$same_failure")" \
    "$fix_attempts" \
    "$n_threshold" \
    "$(json_escape "$recovery_exhausted")" \
    "$(json_escape "$self_report_only")" \
    "$(json_escape "$already_escalated")" \
    "$(json_escape "$id")"
  if [ "$DECISION_LOG" != off ]; then
    if timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
      && [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      decision_id="${timestamp}.${BASHPID:-$$}.${RANDOM:-0}"
      printf -v decision_json '{"timestamp":"%s","decision_id":"%s","id":"%s","generation":"%s","endpoint_alive":"%s","crew_state":"%s","failure_class":"%s","same_failure":"%s","fix_attempts":%s,"n_threshold":%s,"recovery_exhausted":"%s","self_report_only":"%s","already_escalated":"%s","verdict":"%s","reason":"%s","detail":"%s"}' \
        "$(json_escape "$timestamp")" \
        "$(json_escape "$decision_id")" \
        "$(json_escape "$id")" \
        "$(json_escape "$decision_generation")" \
        "$(json_escape "$endpoint_alive")" \
        "$(json_escape "$crew_state")" \
        "$(json_escape "$failure_class")" \
        "$(json_escape "$same_failure")" \
        "$fix_attempts" \
        "$n_threshold" \
        "$(json_escape "$recovery_exhausted")" \
        "$(json_escape "$self_report_only")" \
        "$(json_escape "$already_escalated")" \
        "$(json_escape "$verdict")" \
        "$(json_escape "$reason")" \
        "$(json_escape "$detail")"
      if ! append_classify_decision "$decision_json"; then
        log_err "decision log append failed at $DECISION_LOG; returning classify decision without logging"
      fi
    else
      log_err "decision log append failed at $DECISION_LOG; UTC timestamp unavailable"
    fi
  fi

  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$output_json"
  else
    printf 'verdict=%s\n' "$verdict"
    printf 'reason=%s\n' "$reason"
    printf 'detail=%s\n' "$detail"
    printf 'endpoint_alive=%s\n' "$endpoint_alive"
    printf 'crew_state=%s\n' "$crew_state"
    printf 'failure_class=%s\n' "$failure_class"
    printf 'same_failure=%s\n' "$same_failure"
    printf 'fix_attempts=%s\n' "$fix_attempts"
    printf 'n_threshold=%s\n' "$n_threshold"
    printf 'recovery_exhausted=%s\n' "$recovery_exhausted"
    printf 'self_report_only=%s\n' "$self_report_only"
    printf 'already_escalated=%s\n' "$already_escalated"
    [ -n "$id" ] && printf 'id=%s\n' "$id"
  fi
  return 0
}

list_standing_profiles() {
  local file=$1
  [ -f "$file" ] || return 1
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  jq -r '
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else [] end;
    ([.rules[]? | profiles(.use)[]] + [profiles(.default)[]?])[] as $profile
    | select(($profile.harness | type) == "string" and ($profile.harness | length) > 0)
    | select(($profile.strength | type) == "number")
    | [
        $profile.harness,
        ($profile.model // ""),
        ($profile.effort // ""),
        ($profile.strength | tostring)
      ]
    | join("\u001c")
  ' "$file" 2>/dev/null
}

dispatch_profiles_valid() {
  local file=$1
  fm_crew_dispatch_valid "$file"
}

profile_parts() {
  local raw=$1 encoded_h encoded_m encoded_e
  IFS='|' read -r encoded_h encoded_m encoded_e <<<"$raw"
  PROFILE_H=$(profile_field_unescape "$encoded_h") || return 1
  PROFILE_M=$(profile_field_unescape "$encoded_m") || return 1
  PROFILE_E=$(profile_field_unescape "$encoded_e") || return 1
}

profile_display() {
  profile_parts "$1" || return 1
  printf '%s' "$PROFILE_H"
  if [ -n "$PROFILE_M" ] || [ -n "$PROFILE_E" ]; then
    printf '/%s' "$PROFILE_M"
  fi
  [ -n "$PROFILE_E" ] && printf '/%s' "$PROFILE_E"
  printf '\n'
}

cmd_resolve_stronger() {
  local from_profile='' dispatch=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from-profile)
        [ "$#" -gt 1 ] || die "--from-profile requires harness[/model[/effort]]"
        from_profile=$2
        shift 2
        ;;
      --from-profile=*)
        from_profile=${1#--from-profile=}
        shift
        ;;
      --dispatch)
        [ "$#" -gt 1 ] || die "--dispatch requires a path"
        dispatch=$2
        shift 2
        ;;
      --dispatch=*)
        dispatch=${1#--dispatch=}
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown resolve-stronger flag: $1"
        ;;
    esac
  done

  [ -n "$from_profile" ] || die "resolve-stronger requires --from-profile"
  from_profile=$(profile_key "$from_profile") || die "invalid --from-profile"

  if [ -z "$dispatch" ]; then
    if [ -f "$DEFAULT_DISPATCH" ]; then
      dispatch=$DEFAULT_DISPATCH
    else
      die "no crew-dispatch.json found (pass --dispatch)"
    fi
  fi
  [ -f "$dispatch" ] || die "dispatch file not found: $dispatch"
  command -v jq >/dev/null 2>&1 || die "jq required to read standing profiles from $dispatch"
  dispatch_profiles_valid "$dispatch" || die "invalid dispatch profiles: $dispatch"

  local best_key='' from_strength='' best_strength='' h m e strength key
  local -a best_keys=()
  while IFS=$'\034' read -r h m e strength || [ -n "${h-}" ]; do
    [ -n "${h:-}" ] || continue
    key=$(profile_encode_fields "$h" "$m" "$e")
    if [ "$key" = "$from_profile" ]; then
      if [ -z "$from_strength" ]; then
        from_strength=$strength
      elif [ "$from_strength" != "$strength" ]; then
        die "from profile has conflicting explicit strengths in $dispatch"
      fi
      continue
    fi
  done < <(list_standing_profiles "$dispatch")

  [ -n "$from_strength" ] || die "from profile must have one explicit standing strength in $dispatch"

  while IFS=$'\034' read -r h m e strength || [ -n "${h-}" ]; do
    [ -n "${h:-}" ] || continue
    key=$(profile_encode_fields "$h" "$m" "$e")
    [ "$key" = "$from_profile" ] && continue
    [ "$strength" -gt "$from_strength" ] || continue
    if [ "${#best_keys[@]}" -eq 0 ] || [ "$strength" -lt "$best_strength" ]; then
      best_keys=("$key")
      best_strength=$strength
    elif [ "$strength" -eq "$best_strength" ]; then
      best_keys+=("$key")
    fi
  done < <(list_standing_profiles "$dispatch")

  if [ "${#best_keys[@]}" -eq 0 ]; then
    log_err "no stronger standing profile than '$(profile_display "$from_profile")' in $dispatch"
    printf 'verdict=refuse\n'
    printf 'reason=no_stronger_standing\n'
    printf 'from_profile=%s\n' "$(profile_display "$from_profile")"
    printf 'dispatch=%s\n' "$dispatch"
    return 1
  fi

  best_key=$(printf '%s\n' "${best_keys[@]}" | LC_ALL=C sort -u)
  [ "$(printf '%s\n' "$best_key" | wc -l | tr -d ' ')" -eq 1 ] \
    || die "next stronger strength must identify exactly one standing profile in $dispatch"

  printf 'verdict=ok\n'
  printf 'from_profile=%s\n' "$(profile_display "$from_profile")"
  printf 'target_profile=%s\n' "$(profile_display "$best_key")"
  printf 'from_strength=%s\n' "$from_strength"
  printf 'target_strength=%s\n' "$best_strength"
  printf 'dispatch=%s\n' "$dispatch"
  printf 'note=standing profiles only; re-spawn required (no mid-session model swap)\n'
  return 0
}

sync_regular_file() {
  local path=$1
  perl - "$path" <<'PERL'
use strict;
use warnings;
use Fcntl qw(:DEFAULT);
use File::Basename qw(dirname);
use IO::Handle ();
my ($path) = @ARGV;
sysopen(my $file, $path, O_RDWR | O_NOFOLLOW) or exit 1;
my @path_stat = lstat($path) or exit 1;
my @file_stat = stat($file) or exit 1;
-f $file && $path_stat[0] == $file_stat[0] && $path_stat[1] == $file_stat[1] && $file_stat[3] == 1 or exit 1;
defined $file->sync() or exit 1;
close($file) or exit 1;
sysopen(my $parent, dirname($path), O_RDONLY | O_DIRECTORY) or exit 1;
defined $parent->sync() or exit 1;
PERL
}

ensure_meta_field() {
  local meta=$1 key=$2 value=$3 existing
  [ -f "$meta" ] || return 1
  existing=$(meta_value "$meta" "$key")
  if [ -n "$existing" ]; then
    [ "$existing" = "$value" ] || return 1
    sync_regular_file "$meta"
    return $?
  fi
  command -v perl >/dev/null 2>&1 || return 1
  perl - "$meta" "$key=$value" <<'PERL'
use strict;
use warnings;
use Fcntl qw(:DEFAULT);
use File::Basename qw(dirname);
use IO::Handle ();
my ($path, $line) = @ARGV;
sysopen(my $file, $path, O_WRONLY | O_APPEND | O_NOFOLLOW) or exit 1;
my @path_stat = lstat($path) or exit 1;
my @file_stat = stat($file) or exit 1;
-f $file && $path_stat[0] == $file_stat[0] && $path_stat[1] == $file_stat[1] && $file_stat[3] == 1 or exit 1;
my $payload = "$line\n";
my $offset = 0;
while ($offset < length($payload)) {
  my $count = syswrite($file, $payload, length($payload) - $offset, $offset);
  defined $count && $count > 0 or exit 1;
  $offset += $count;
}
defined $file->sync() or exit 1;
close($file) or exit 1;
sysopen(my $parent, dirname($path), O_RDONLY | O_DIRECTORY) or exit 1;
defined $parent->sync() or exit 1;
PERL
}

write_pending_escalation() {
  local path=$1 prior_id=$2 from_profile=$3 target_profile=$4 new_id=$5 note=$6 transaction_id=$7 decision_id=$8 generation=$9 tmp
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  if ! printf '{"prior_id":"%s","from_profile":"%s","target_profile":"%s","new_id":"%s","note":"%s","transaction_id":"%s","decision_id":"%s","generation":"%s"}\n' \
    "$(json_escape "$prior_id")" \
    "$(json_escape "$(profile_display "$from_profile")")" \
    "$(json_escape "$(profile_display "$target_profile")")" \
    "$(json_escape "$new_id")" \
    "$(json_escape "$note")" \
    "$(json_escape "$transaction_id")" \
    "$(json_escape "$decision_id")" \
    "$(json_escape "$generation")" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  perl -MIO::Handle -e 'open my $f, "+<", $ARGV[0] or exit 1; defined $f->sync or exit 1' "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  sync_state_directory
}

write_reservation_claim() {
  local path=$1 transaction_id=$2 prior_id=$3 new_id=$4 target_profile=$5 decision_id=$6 generation=$7 tmp
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  if ! printf 'transaction_id=%s\nprior_id=%s\nnew_id=%s\ntarget_profile=%s\ndecision_id=%s\ngeneration=%s\n' \
    "$transaction_id" "$prior_id" "$new_id" "$(profile_display "$target_profile")" "$decision_id" "$generation" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  perl -MIO::Handle -e 'open my $f, "+<", $ARGV[0] or exit 1; defined $f->sync or exit 1' "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  sync_state_directory
}

sync_state_directory() {
  perl -MIO::Handle -MFcntl=:DEFAULT -e 'sysopen(my $d, $ARGV[0], O_RDONLY | O_DIRECTORY) or exit 1; defined $d->sync or exit 1' "$STATE"
}

remove_transaction_files() {
  local pending_path=$1 claim_path=$2
  rm -f "$claim_path" || return 1
  sync_state_directory || return 1
  rm -f "$pending_path" || return 1
  sync_state_directory
}

# True when markers, outcome, and transaction journal are fully settled.
# Used for crash-safe commit retries after a late fsync failure.
# Note text is optional: a generation-bound escalated outcome is enough.
escalation_commit_settled() {
  local prior_meta=$1 new_meta=$2 from_display=$3 prior_id=$4 generation=$5 note=$6 pending_path=$7 claim_path=$8
  local log_path=${FM_DISPATCH_OUTCOMES:-$DATA/dispatch-outcomes.jsonl}
  [ -f "$prior_meta" ] && [ ! -L "$prior_meta" ] || return 1
  [ -f "$new_meta" ] && [ ! -L "$new_meta" ] || return 1
  [ "$(meta_value "$prior_meta" escalated_from)" = "$from_display" ] || return 1
  [ "$(meta_value "$new_meta" escalated_from)" = "$from_display" ] || return 1
  [ "$(meta_value "$new_meta" escalated_prior_id)" = "$prior_id" ] || return 1
  if [ -n "$note" ] && outcome_recorded "$prior_id" "$generation" "$note"; then
    :
  elif [ -f "$log_path" ] && jq -e -s \
    --arg prior_id "$prior_id" \
    --arg generation "$generation" \
    'any(.[]; .id == $prior_id and .generation == $generation and .outcome == "escalated")' \
    "$log_path" >/dev/null 2>&1; then
    :
  else
    return 1
  fi
  { [ ! -e "$pending_path" ] && [ ! -L "$pending_path" ]; } || return 1
  { [ ! -e "$claim_path" ] && [ ! -L "$claim_path" ]; } || return 1
  return 0
}

decision_log_lock_path() {
  local parent base
  [ "$DECISION_LOG" != off ] || return 1
  parent=$(dirname "$DECISION_LOG") || return 1
  decision_log_parent "$parent" || return 1
  parent=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  base=$(basename "$DECISION_LOG") || return 1
  printf '%s\n' "$parent/$base.lock"
}

latest_escalate_decision() {
  local id=$1 generation=$2
  [ "$DECISION_LOG" != off ] || return 1
  [ -f "$DECISION_LOG" ] && [ ! -L "$DECISION_LOG" ] || return 1
  jq -cer -s --arg id "$id" --arg generation "$generation" '
    [.[] | select(.id == $id and .generation == $generation)]
    | last
    | select(.verdict == "escalate")
    | .decision_id
    | select(type == "string" and length > 0)
  ' "$DECISION_LOG" 2>/dev/null
}

decision_binding_valid() {
  local id=$1 generation=$2 decision_id=$3
  [ "$DECISION_LOG" != off ] || return 1
  [ -f "$DECISION_LOG" ] && [ ! -L "$DECISION_LOG" ] || return 1
  jq -e -s --arg id "$id" --arg generation "$generation" --arg decision_id "$decision_id" '
    any(.[]; .id == $id and .generation == $generation and .decision_id == $decision_id and .verdict == "escalate")
  ' "$DECISION_LOG" >/dev/null 2>&1
}

pending_field() {
  local path=$1 field=$2
  jq -er --arg field "$field" '.[$field]' "$path" 2>/dev/null
}

outcome_recorded() {
  local log_path=${FM_DISPATCH_OUTCOMES:-$DATA/dispatch-outcomes.jsonl} prior_id=$1 generation=$2 note=$3
  [ -f "$log_path" ] || return 1
  jq -e -s \
    --arg prior_id "$prior_id" \
    --arg generation "$generation" \
    --arg note "$note" \
    'any(.[]; .id == $prior_id and .generation == $generation and .outcome == "escalated" and .note == $note)' \
    "$log_path" >/dev/null 2>&1
}

resolve_stronger_target() {
  local from_profile=$1 dispatch=$2 resolution resolved_target
  if ! resolution=$(cmd_resolve_stronger --from-profile "$(profile_display "$from_profile")" --dispatch "$dispatch" 2>&1); then
    die "no stronger standing profile for '$(profile_display "$from_profile")'"
  fi
  resolved_target=$(printf '%s\n' "$resolution" | awk -F= '$1 == "target_profile" { value=$2 } END { print value }')
  profile_key "$resolved_target" || die "resolver returned an invalid target profile"
}

cmd_escalate() {
  local prior_id='' target_profile='' note='' new_id='' dispatch='' dry_run=0 phase=''

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target-profile)
        [ "$#" -gt 1 ] || die "--target-profile requires harness[/model[/effort]]"
        target_profile=$2
        shift 2
        ;;
      --target-profile=*)
        target_profile=${1#--target-profile=}
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
      --new-id)
        [ "$#" -gt 1 ] || die "--new-id requires a task id"
        new_id=$2
        shift 2
        ;;
      --new-id=*)
        new_id=${1#--new-id=}
        shift
        ;;
      --dispatch)
        [ "$#" -gt 1 ] || die "--dispatch requires a path"
        dispatch=$2
        shift 2
        ;;
      --dispatch=*)
        dispatch=${1#--dispatch=}
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --reserve)
        [ -z "$phase" ] || die "--reserve and --commit are mutually exclusive"
        phase=reserve
        shift
        ;;
      --commit)
        [ -z "$phase" ] || die "--reserve and --commit are mutually exclusive"
        phase=commit
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "unknown escalate flag: $1"
        ;;
      *)
        if [ -z "$prior_id" ]; then
          prior_id=$1
          shift
        else
          die "unexpected argument: $1"
        fi
        ;;
    esac
  done

  [ -n "$prior_id" ] || die "escalate requires <prior-id>"
  fm_task_id_path_safe "$prior_id" || die "invalid prior task id '$prior_id'"
  [ -n "$target_profile" ] || die "escalate requires --target-profile"
  target_profile=$(profile_key "$target_profile") || die "invalid --target-profile"
  if [ -n "$new_id" ]; then
    fm_task_id_path_safe "$new_id" || die "invalid --new-id '$new_id'"
    [ "$new_id" != "$prior_id" ] || die "--new-id must differ from <prior-id>"
  fi
  if [ "$dry_run" -eq 0 ]; then
    [ -n "$new_id" ] || die "escalate requires --new-id for follow-on linkage"
    [ -n "$phase" ] || die "escalate requires --reserve before spawn or --commit after spawn"
  fi

  local prior_meta="$STATE/$prior_id.meta"
  local existing_ef prior_profile escalated_from_value attempt_lock claim_lock prior_spawn_lock new_spawn_lock resolved_target resolution new_meta
  local prior_generation decision_id transaction_id claim_path claim_transaction claim_prior claim_target claim_decision claim_generation new_generation new_reservation
  local pending_path pending_prior pending_from pending_target pending_new pending_note pending_transaction pending_decision pending_generation
  local pending_exists=0 requested_target new_existing_ef launch_complete_generation
  local prior_spawn_lock_held=0 new_spawn_lock_held=0 decision_log_lock='' decision_log_lock_held=0
  local first_spawn_lock second_spawn_lock first_spawn_holder second_spawn_holder
  local ordered_ids first_id
  local from_display metrics_note
  decision_id=''
  transaction_id=''
  claim_transaction=''

  if [ -z "$dispatch" ]; then
    dispatch=$DEFAULT_DISPATCH
  fi
  [ -f "$dispatch" ] || die "dispatch file not found: $dispatch"
  command -v jq >/dev/null 2>&1 || die "jq required to verify standing profiles"
  dispatch_profiles_valid "$dispatch" || die "invalid dispatch profiles: $dispatch"

  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  attempt_lock="$STATE/.$prior_id.stuck-escalate.lock"
  claim_lock="$STATE/.stuck-escalation-reservations.lock"
  prior_spawn_lock="$STATE/.spawn-$prior_id.lock"
  new_spawn_lock=
  [ -z "$new_id" ] || new_spawn_lock="$STATE/.spawn-$new_id.lock"
  pending_path="$STATE/.$prior_id.stuck-escalate.pending"
  claim_path=
  [ -z "$new_id" ] || claim_path="$STATE/.$new_id.stuck-escalation-reservation"

  # Acquire escalate + claim locks, then both task lifecycle locks in
  # deterministic ID order before any task metadata reads so concurrent
  # teardown cannot delete prior meta mid-transaction.
  fm_lock_try_acquire "$attempt_lock" || die "escalate already in progress for $prior_id"
  if ! fm_lock_try_acquire "$claim_lock"; then
    fm_lock_release "$attempt_lock"
    die "another escalation reservation is in progress"
  fi
  if [ -n "$new_id" ]; then
    # Deterministic ID order without PATH tools (policy suite uses a minimal PATH).
    ordered_ids=$(printf '%s\n%s\n' "$prior_id" "$new_id" | LC_ALL=C sort)
    first_id=${ordered_ids%%$'\n'*}
    if [ "$first_id" = "$prior_id" ]; then
      first_spawn_lock=$prior_spawn_lock
      first_spawn_holder=prior
      second_spawn_lock=$new_spawn_lock
      second_spawn_holder=new
    else
      first_spawn_lock=$new_spawn_lock
      first_spawn_holder=new
      second_spawn_lock=$prior_spawn_lock
      second_spawn_holder=prior
    fi
    if ! fm_lock_try_acquire "$first_spawn_lock"; then
      fm_lock_release "$claim_lock"
      fm_lock_release "$attempt_lock"
      if [ "$first_spawn_holder" = prior ]; then
        die "task $prior_id lifecycle is busy"
      fi
      die "task $new_id lifecycle is busy"
    fi
    if [ "$first_spawn_holder" = prior ]; then
      prior_spawn_lock_held=1
    else
      new_spawn_lock_held=1
    fi
    if ! fm_lock_try_acquire "$second_spawn_lock"; then
      [ "$prior_spawn_lock_held" = 0 ] || fm_lock_release "$prior_spawn_lock"
      [ "$new_spawn_lock_held" = 0 ] || fm_lock_release "$new_spawn_lock"
      prior_spawn_lock_held=0
      new_spawn_lock_held=0
      fm_lock_release "$claim_lock"
      fm_lock_release "$attempt_lock"
      if [ "$second_spawn_holder" = prior ]; then
        die "task $prior_id lifecycle is busy"
      fi
      die "task $new_id lifecycle is busy"
    fi
    if [ "$second_spawn_holder" = prior ]; then
      prior_spawn_lock_held=1
    else
      new_spawn_lock_held=1
    fi
  else
    if ! fm_lock_try_acquire "$prior_spawn_lock"; then
      fm_lock_release "$claim_lock"
      fm_lock_release "$attempt_lock"
      die "task $prior_id lifecycle is busy"
    fi
    prior_spawn_lock_held=1
  fi
  trap '[ "${decision_log_lock_held:-0}" = 0 ] || fm_lock_release "$decision_log_lock"; [ "${prior_spawn_lock_held:-0}" = 0 ] || fm_lock_release "$prior_spawn_lock"; [ "${new_spawn_lock_held:-0}" = 0 ] || fm_lock_release "$new_spawn_lock"; fm_lock_release "$claim_lock"; fm_lock_release "$attempt_lock"' EXIT

  [ -f "$prior_meta" ] && [ ! -L "$prior_meta" ] || die "prior meta not found or unsafe: $prior_meta"
  if ! prior_profile=$(profile_from_meta "$prior_meta" 2>/dev/null); then
    die "prior meta must record harness/model/effort before escalate"
  fi
  escalated_from_value=$prior_profile
  prior_generation=$(meta_value "$prior_meta" spawn_generation)
  if [ "$dry_run" -eq 0 ]; then
    [ -n "$prior_generation" ] || die "prior meta must record spawn_generation before escalate"
  fi

  existing_ef=$(meta_value "$prior_meta" escalated_from)
  if [ -e "$pending_path" ] || [ -L "$pending_path" ]; then
    [ -f "$pending_path" ] && [ ! -L "$pending_path" ] || die "pending escalation record is unsafe: $pending_path"
    pending_exists=1
    pending_prior=$(pending_field "$pending_path" prior_id) || die "pending escalation record is invalid"
    pending_from=$(pending_field "$pending_path" from_profile) || die "pending escalation record is invalid"
    pending_target=$(pending_field "$pending_path" target_profile) || die "pending escalation record is invalid"
    pending_new=$(pending_field "$pending_path" new_id) || die "pending escalation record is invalid"
    pending_note=$(pending_field "$pending_path" note) || die "pending escalation record is invalid"
    pending_transaction=$(pending_field "$pending_path" transaction_id) || die "pending escalation record is invalid"
    pending_decision=$(pending_field "$pending_path" decision_id) || die "pending escalation record is invalid"
    pending_generation=$(pending_field "$pending_path" generation) || die "pending escalation record is invalid"
    [ "$pending_prior" = "$prior_id" ] || die "pending escalation record does not match prior id"
    requested_target=$(profile_display "$target_profile")
    [ "$pending_target" = "$requested_target" ] || die "pending escalation record does not match target profile"
    [ "$pending_new" = "$new_id" ] || die "pending escalation record does not match new id"
    [ "$pending_generation" = "$prior_generation" ] || die "pending escalation record does not match prior generation"
    [ -z "$note" ] || [ "$note" = "$pending_note" ] || die "pending escalation record has a different note"
    escalated_from_value=$(profile_key "$pending_from") || die "pending escalation record has an invalid source profile"
    target_profile=$(profile_key "$pending_target") || die "pending escalation record has an invalid target profile"
    [ "$escalated_from_value" = "$prior_profile" ] || die "pending escalation source does not match prior meta"
    note=$pending_note
    transaction_id=$pending_transaction
    decision_id=$pending_decision
    decision_binding_valid "$prior_id" "$prior_generation" "$decision_id" \
      || die "pending escalation is not bound to a durable escalate decision"
    [ -z "$existing_ef" ] || [ "$existing_ef" = "$pending_from" ] || die "pending escalation marker does not match its source"
    if ! resolved_target=$(resolve_stronger_target "$prior_profile" "$dispatch"); then
      die "pending target is no longer the resolved stronger standing profile"
    fi
    [ "$resolved_target" = "$target_profile" ] || die "pending target is no longer the resolved stronger standing profile"
  else
    from_display=$(profile_display "$escalated_from_value")
    metrics_note="stuck_classify escalate prior=$prior_id from=$from_display to=$(profile_display "$target_profile")"
    [ -n "$note" ] && metrics_note="$metrics_note; $note"
    # Idempotent success: markers + outcome already durable and journal cleared
    # (e.g. prior commit died after cleanup when final directory fsync failed).
    if [ "$dry_run" -eq 0 ] && [ "$phase" = commit ] && [ -n "$existing_ef" ] && [ -n "$new_id" ]; then
      new_meta="$STATE/$new_id.meta"
      if [ -f "$new_meta" ] && [ ! -L "$new_meta" ] \
        && escalation_commit_settled "$prior_meta" "$new_meta" "$from_display" \
          "$prior_id" "$prior_generation" "$metrics_note" "$pending_path" "$claim_path"; then
        printf 'verdict=escalated\n'
        printf 'prior_id=%s\n' "$prior_id"
        printf 'prior_profile=%s\n' "$from_display"
        printf 'target_profile=%s\n' "$(profile_display "$target_profile")"
        printf 'escalated_from=%s\n' "$from_display"
        printf 'new_id=%s\n' "$new_id"
        printf 'outcome=escalated\n'
        printf 'note=%s\n' "$metrics_note"
        printf 'metrics.action=escalate\n'
        printf 'metrics.thrash_cap=one_step\n'
        printf 'metrics.standing_profile_only=yes\n'
        printf 'metrics.blocked_vs_escalated=escalated\n'
        trap - EXIT
        [ "$decision_log_lock_held" = 0 ] || fm_lock_release "$decision_log_lock"
        [ "$prior_spawn_lock_held" = 0 ] || fm_lock_release "$prior_spawn_lock"
        [ "$new_spawn_lock_held" = 0 ] || fm_lock_release "$new_spawn_lock"
        fm_lock_release "$claim_lock"
        fm_lock_release "$attempt_lock"
        return 0
      fi
    fi
    [ -z "$existing_ef" ] || die "already_escalated: prior meta has escalated_from=$existing_ef (no second auto-escalate)"
    if ! resolved_target=$(resolve_stronger_target "$prior_profile" "$dispatch"); then
      die "no stronger standing profile for prior task $prior_id"
    fi
    [ "$resolved_target" = "$target_profile" ] || die "target profile is not the resolved stronger standing profile"
    [ "$phase" != commit ] || die "no reserved escalation exists for $prior_id"
    if [ "$dry_run" -eq 0 ]; then
      # Linearize latest-decision selection with reservation publication under
      # the decision-log lock so a concurrent classify cannot leave reserve
      # bound to a stale escalate after a newer refusal is already logged.
      decision_log_lock=$(decision_log_lock_path) \
        || die "reserve requires a durable classify decision log"
      acquire_decision_log_lock "$decision_log_lock" \
        || die "could not acquire classify decision log lock for reserve"
      decision_log_lock_held=1
      decision_id=$(latest_escalate_decision "$prior_id" "$prior_generation") \
        || die "reserve requires the latest durable classify decision for this task generation to be verdict=escalate"
      if [ -f "$claim_path" ] && [ ! -L "$claim_path" ]; then
        claim_prior=$(meta_value "$claim_path" prior_id)
        claim_target=$(meta_value "$claim_path" target_profile)
        claim_decision=$(meta_value "$claim_path" decision_id)
        claim_generation=$(meta_value "$claim_path" generation)
        if [ "$claim_prior" = "$prior_id" ] && [ "$claim_target" = "$(profile_display "$target_profile")" ] \
          && [ "$claim_decision" = "$decision_id" ] && [ "$claim_generation" = "$prior_generation" ]; then
          transaction_id=$(meta_value "$claim_path" transaction_id)
        fi
      fi
      [ -n "$transaction_id" ] \
        || transaction_id="$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null).${BASHPID:-$$}.${RANDOM:-0}"
    fi
  fi

  if [ "$dry_run" -eq 0 ] && [ -n "$claim_path" ] && { [ -e "$claim_path" ] || [ -L "$claim_path" ]; }; then
    [ -f "$claim_path" ] && [ ! -L "$claim_path" ] || die "reservation claim is unsafe: $claim_path"
    claim_transaction=$(meta_value "$claim_path" transaction_id)
    [ -n "$transaction_id" ] && [ "$claim_transaction" = "$transaction_id" ] \
      || die "new id is reserved by a different escalation transaction"
  elif [ "$pending_exists" -eq 1 ] && [ "$phase" = commit ]; then
    write_reservation_claim "$claim_path" "$transaction_id" "$prior_id" "$new_id" "$target_profile" "$decision_id" "$prior_generation" \
      || die "reserved escalation could not recover its global new-id claim"
  fi

  if [ "$phase" = commit ]; then
    new_meta="$STATE/$new_id.meta"
    [ -f "$new_meta" ] && [ ! -L "$new_meta" ] || die "new meta not found or unsafe: $new_meta"
    [ -w "$new_meta" ] || die "new meta is not writable: $new_meta"
    new_existing_ef=$(meta_value "$new_meta" escalated_from)
    new_reservation=$(meta_value "$new_meta" escalation_reservation)
    new_generation=$(meta_value "$new_meta" spawn_generation)
    launch_complete_generation=$(meta_value "$new_meta" launch_complete_generation)
    [ -n "$new_generation" ] || die "new meta must record spawn_generation"
    [ "$launch_complete_generation" = "$new_generation" ] \
      || die "new meta does not prove launch completion for its spawn generation"
    [ "$new_reservation" = "$transaction_id" ] \
      || die "new meta is not bound to this escalation reservation"
    if [ "$pending_exists" -eq 1 ]; then
      [ -z "$new_existing_ef" ] || [ "$new_existing_ef" = "$pending_from" ] \
        || die "pending escalation marker does not match its source"
    else
      [ -z "$new_existing_ef" ] || die "new meta already has escalated_from= (refuse thrash / double-write)"
    fi
    [ "$(profile_from_meta "$new_meta")" = "$target_profile" ] \
      || die "new meta profile does not match --target-profile"
  elif [ "$phase" = reserve ]; then
    [ ! -e "$STATE/$new_id.meta" ] && [ ! -L "$STATE/$new_id.meta" ] \
      || die "reserve requires a not-yet-spawned --new-id"
  fi
  [ -w "$prior_meta" ] || die "prior meta is not writable: $prior_meta"

  from_display=$(profile_display "$escalated_from_value")
  metrics_note="stuck_classify escalate prior=$prior_id from=$from_display to=$(profile_display "$target_profile")"
  [ -n "$note" ] && metrics_note="$metrics_note; $note"

  if [ "$dry_run" -eq 1 ]; then
    printf 'verdict=dry-run\n'
    printf 'prior_id=%s\n' "$prior_id"
    printf 'prior_profile=%s\n' "$from_display"
    printf 'target_profile=%s\n' "$(profile_display "$target_profile")"
    printf 'escalated_from=%s\n' "$from_display"
    [ -n "$new_id" ] && printf 'new_id=%s\n' "$new_id"
    printf 'outcome=escalated\n'
    printf 'note=%s\n' "$metrics_note"
    printf 'metrics.action=escalate\n'
    printf 'metrics.thrash_cap=one_step\n'
    printf 'metrics.standing_profile_only=yes\n'
    trap - EXIT
    [ "$decision_log_lock_held" = 0 ] || fm_lock_release "$decision_log_lock"
    [ "$prior_spawn_lock_held" = 0 ] || fm_lock_release "$prior_spawn_lock"
    [ "$new_spawn_lock_held" = 0 ] || fm_lock_release "$new_spawn_lock"
    fm_lock_release "$claim_lock"
    fm_lock_release "$attempt_lock"
    return 0
  fi

  [ -x "$OUTCOME_BIN" ] || [ -f "$OUTCOME_BIN" ] || die "outcome helper missing: $OUTCOME_BIN"

  if [ "$phase" = reserve ]; then
    if [ ! -e "$claim_path" ] && [ ! -L "$claim_path" ]; then
      write_reservation_claim "$claim_path" "$transaction_id" "$prior_id" "$new_id" "$target_profile" "$decision_id" "$prior_generation" \
        || die "failed to create global new-id reservation claim"
    fi
    if [ "$pending_exists" -eq 0 ]; then
      write_pending_escalation "$pending_path" "$prior_id" "$escalated_from_value" "$target_profile" "$new_id" "$note" \
        "$transaction_id" "$decision_id" "$prior_generation" || die "failed to create pending escalation record"
    fi
    if ! sync_regular_file "$claim_path" \
      || ! sync_regular_file "$pending_path" \
      || ! sync_state_directory; then
      die "failed to make escalation reservation durable"
    fi
    if [ "$decision_log_lock_held" = 1 ]; then
      decision_log_lock_held=0
      fm_lock_release "$decision_log_lock" || true
    fi
    printf 'verdict=reserved\n'
    printf 'prior_id=%s\n' "$prior_id"
    printf 'prior_profile=%s\n' "$from_display"
    printf 'target_profile=%s\n' "$(profile_display "$target_profile")"
    printf 'new_id=%s\n' "$new_id"
    printf 'reservation_id=%s\n' "$transaction_id"
    trap - EXIT
    [ "$prior_spawn_lock_held" = 0 ] || fm_lock_release "$prior_spawn_lock"
    [ "$new_spawn_lock_held" = 0 ] || fm_lock_release "$new_spawn_lock"
    fm_lock_release "$claim_lock"
    fm_lock_release "$attempt_lock"
    return 0
  fi

  if ! sync_regular_file "$claim_path" \
    || ! sync_regular_file "$pending_path" \
    || ! sync_state_directory; then
    die "failed to make pending escalation durable before commit"
  fi
  ensure_meta_field "$prior_meta" escalated_from "$from_display" \
    || die "failed to write prior escalation marker"
  ensure_meta_field "$new_meta" escalated_from "$from_display" \
    || die "failed to write new escalation marker"
  ensure_meta_field "$new_meta" escalated_prior_id "$prior_id" \
    || die "failed to write new escalation prior-id binding"

  if ! outcome_recorded "$prior_id" "$prior_generation" "$metrics_note"; then
    if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$OUTCOME_BIN" record "$prior_id" --outcome escalated --note "$metrics_note" --once; then
      die "failed to record escalated outcome for $prior_id; pending transaction remains"
    fi
  fi
  if ! remove_transaction_files "$pending_path" "$claim_path"; then
    # Markers and outcome may already be durable while a late directory fsync
    # fails. If the journal is gone and linkage is complete, succeed idempotently.
    if escalation_commit_settled "$prior_meta" "$new_meta" "$from_display" \
      "$prior_id" "$prior_generation" "$metrics_note" "$pending_path" "$claim_path"; then
      :
    else
      die "escalation committed but transaction records could not be removed"
    fi
  fi

  printf 'verdict=escalated\n'
  printf 'prior_id=%s\n' "$prior_id"
  printf 'prior_profile=%s\n' "$from_display"
  printf 'target_profile=%s\n' "$(profile_display "$target_profile")"
  printf 'escalated_from=%s\n' "$from_display"
  [ -n "$new_id" ] && printf 'new_id=%s\n' "$new_id"
  printf 'outcome=escalated\n'
  printf 'note=%s\n' "$metrics_note"
  printf 'metrics.action=escalate\n'
  printf 'metrics.thrash_cap=one_step\n'
  printf 'metrics.standing_profile_only=yes\n'
  printf 'metrics.blocked_vs_escalated=escalated\n'
  trap - EXIT
  [ "$decision_log_lock_held" = 0 ] || fm_lock_release "$decision_log_lock"
  [ "$prior_spawn_lock_held" = 0 ] || fm_lock_release "$prior_spawn_lock"
  [ "$new_spawn_lock_held" = 0 ] || fm_lock_release "$new_spawn_lock"
  fm_lock_release "$claim_lock"
  fm_lock_release "$attempt_lock"
  return 0
}

main() {
  local cmd=${1-}
  if [ -z "$cmd" ]; then
    usage
    exit 2
  fi
  shift || true
  case "$cmd" in
    classify)
      cmd_classify "$@"
      ;;
    resolve-stronger)
      cmd_resolve_stronger "$@"
      ;;
    escalate)
      cmd_escalate "$@"
      ;;
    help|-h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown command '$cmd' (want classify|resolve-stronger|escalate|help)"
      ;;
  esac
}

main "$@"
