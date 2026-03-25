#!/usr/bin/env bash
# remote-exec.sh -- Execute commands on remote hosts via SSH.
#
# This script relies on scripts/common.sh for:
# - load_config
# - resolve_host
# - ssh_cmd
# - get_all_hosts
# - check_command_safety (sets SAFETY_LEVEL)
# - confirm_command
# - logging helpers
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"; done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage:
  remote-exec <target> "<command>"
  remote-exec <target> --bg "<command>"
  remote-exec <target> --bg-list
  remote-exec <target> --bg-log <task_id>
  remote-exec <target> --bg-kill <task_id>
  remote-exec <target> --timeout <seconds> "<command>"
  remote-exec all "<command>"

Options:
  --bg              Run the command in the background on the remote host
  --bg-list         List remote background tasks
  --bg-log ID       Follow stdout for a background task
  --bg-kill ID      Kill a background task
  --timeout SECS    Foreground SSH timeout in seconds (0 disables timeout)
  -h, --help        Show this help text

Notes:
  - Broadcast mode runs sequentially and prefixes each output line by host.
  - Broadcast confirmation is shown once for all target hosts.
  - Background tasks are launched through ~/.claude/skills/remote-collab/scripts/remote-wrapper.sh.
EOF
}

run_ssh() {
  local remote_cmd="$1"
  build_ssh_array
  "${SSH_ARRAY[@]}" "$remote_cmd"
}

verify_ssh() {
  local target="$1"
  resolve_host "$target"
  build_ssh_array
  "${SSH_ARRAY[@]}" "printf ok" >/dev/null 2>&1
}

timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    printf '%s\n' "timeout"
    return 0
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    printf '%s\n' "gtimeout"
    return 0
  fi

  return 1
}

make_task_id() {
  local host="$1"
  local rand

  rand="$(xxd -p -l 4 /dev/urandom 2>/dev/null || true)"
  [[ -n "$rand" ]] || die "Failed to generate task id suffix via xxd"

  printf '%s-%s-%s\n' "$host" "$(date +%Y%m%d-%H%M%S)" "$rand"
}

run_foreground() {
  local cmd="$1"
  local timeout_secs="$2"
  local remote_cmd timeout_tool

  remote_cmd="bash -lc $(printf '%q' "$cmd")"

  if [[ "$timeout_secs" == "0" ]]; then
    run_ssh "$remote_cmd"
    return
  fi

  if timeout_tool="$(timeout_bin)"; then
    build_ssh_array
    "$timeout_tool" "$timeout_secs" "${SSH_ARRAY[@]}" "$remote_cmd"
    return
  fi

  log_warn "No timeout command available locally; running without timeout"
  run_ssh "$remote_cmd"
}

run_background() {
  local target="$1"
  local cmd="$2"
  local task_id remote_cmd

  task_id="$(make_task_id "$RESOLVED_HOST")"
  remote_cmd="~/.claude/skills/remote-collab/scripts/remote-wrapper.sh $(printf '%q' "$task_id") $(printf '%q' "$cmd")"

  run_ssh "$remote_cmd" >/dev/null
  log_info "Started background task on $target"
  log_info "Task ID: $task_id"
  log_info "View logs: remote-exec $target --bg-log $task_id"
}

bg_list() {
  local target="$1"

  resolve_host "$target"
  build_ssh_array

  log_info "Background tasks on $target"

  "${SSH_ARRAY[@]}" "MAX_TASK_DAYS=$(printf '%q' "$MAX_TASK_DAYS") MAX_TASK_LOG_MB=$(printf '%q' "$MAX_TASK_LOG_MB") bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

TASK_BASE="$HOME/.claude/skills/remote-collab/runtime/tasks"
MAX_TASK_DAYS="${MAX_TASK_DAYS:-7}"
MAX_TASK_LOG_MB="${MAX_TASK_LOG_MB:-100}"

human_ts() {
  local epoch="$1"
  if date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
    date -d "@$epoch" '+%Y-%m-%d %H:%M:%S'
  else
    date -r "$epoch" '+%Y-%m-%d %H:%M:%S'
  fi
}

process_start_epoch() {
  local pid="$1"
  local start_text

  start_text="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')"
  [[ -n "$start_text" ]] || return 1

  if date -d "$start_text" +%s >/dev/null 2>&1; then
    date -d "$start_text" +%s
  else
    date -j -f '%a %b %e %T %Y' "$start_text" +%s
  fi
}

cleanup_old_tasks() {
  local now cutoff
  now="$(date +%s)"
  cutoff=$((now - MAX_TASK_DAYS * 86400))

  [[ -d "$TASK_BASE" ]] || return 0

  local task_dir started_epoch
  for task_dir in "$TASK_BASE"/*; do
    [[ -d "$task_dir" ]] || continue

    started_epoch="$(cat "$task_dir/start_time" 2>/dev/null || printf '0')"
    [[ "$started_epoch" =~ ^[0-9]+$ ]] || started_epoch=0

    if (( started_epoch > 0 && started_epoch < cutoff )); then
      rm -rf "$task_dir"
    fi
  done
}

cleanup_logs_by_size() {
  local limit_bytes total_bytes
  limit_bytes=$((MAX_TASK_LOG_MB * 1024 * 1024))
  total_bytes=0

  [[ -d "$TASK_BASE" ]] || return 0

  local task_dir
  for task_dir in "$TASK_BASE"/*; do
    [[ -d "$task_dir" ]] || continue
    total_bytes=$((total_bytes + $(wc -c < "$task_dir/stdout.log" 2>/dev/null || printf '0')))
    total_bytes=$((total_bytes + $(wc -c < "$task_dir/stderr.log" 2>/dev/null || printf '0')))
  done

  (( total_bytes > limit_bytes )) || return 0

  while (( total_bytes > limit_bytes )); do
    local oldest_task="" oldest_epoch=""

    for task_dir in "$TASK_BASE"/*; do
      local task_epoch
      [[ -d "$task_dir" ]] || continue
      [[ -f "$task_dir/exitcode" ]] || continue

      task_epoch="$(cat "$task_dir/start_time" 2>/dev/null || printf '0')"
      [[ "$task_epoch" =~ ^[0-9]+$ ]] || task_epoch=0

      if [[ -z "$oldest_task" ]] || (( task_epoch < oldest_epoch )); then
        oldest_task="$task_dir"
        oldest_epoch="$task_epoch"
      fi
    done

    [[ -n "$oldest_task" ]] || break

    total_bytes=$((total_bytes - $(wc -c < "$oldest_task/stdout.log" 2>/dev/null || printf '0')))
    total_bytes=$((total_bytes - $(wc -c < "$oldest_task/stderr.log" 2>/dev/null || printf '0')))
    rm -rf "$oldest_task"
  done
}

task_status() {
  local task_dir="$1"
  local pid stored_start current_start reason exitcode

  if [[ -f "$task_dir/exitcode" ]]; then
    exitcode="$(cat "$task_dir/exitcode" 2>/dev/null || printf '?')"
    reason="$(cat "$task_dir/exit_reason" 2>/dev/null || printf 'completed')"
    printf '%s (exit %s)\n' "$reason" "$exitcode"
    return 0
  fi

  pid="$(cat "$task_dir/pid" 2>/dev/null || true)"
  stored_start="$(cat "$task_dir/start_time" 2>/dev/null || true)"

  if [[ -z "$pid" || -z "$stored_start" ]]; then
    printf 'lost\n'
    return 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'lost\n'
    return 0
  fi

  current_start="$(process_start_epoch "$pid" 2>/dev/null || true)"
  if [[ -z "$current_start" ]]; then
    printf 'running (pid %s, start unverified)\n' "$pid"
    return 0
  fi

  if [[ "$current_start" == "$stored_start" ]]; then
    printf 'running (pid %s)\n' "$pid"
  else
    printf 'stale (pid %s)\n' "$pid"
  fi
}

cleanup_old_tasks
cleanup_logs_by_size

if [[ ! -d "$TASK_BASE" ]]; then
  echo "  (no tasks)"
  exit 0
fi

shopt -s nullglob
task_dirs=("$TASK_BASE"/*)
if [[ ${#task_dirs[@]} -eq 0 ]]; then
  echo "  (no tasks)"
  exit 0
fi

for task_dir in "${task_dirs[@]}"; do
  task_id="$(basename "$task_dir")"
  cmd="$(cat "$task_dir/cmd.txt" 2>/dev/null || printf '?')"
  started_epoch="$(cat "$task_dir/start_time" 2>/dev/null || printf '0')"
  if [[ "$started_epoch" =~ ^[0-9]+$ ]] && (( started_epoch > 0 )); then
    started="$(human_ts "$started_epoch")"
  else
    started="$(cat "$task_dir/started_at" 2>/dev/null || printf '?')"
  fi
  status="$(task_status "$task_dir")"
  printf '%-40s %-28s %s | %s\n' "$task_id" "$status" "$started" "$cmd"
done
REMOTE_SCRIPT
}

bg_log() {
  local target="$1"
  local task_id="$2"

  validate_task_id "$task_id"
  resolve_host "$target"
  local remote_cmd
  remote_cmd="test -f ~/.claude/skills/remote-collab/runtime/tasks/$(printf '%q' "$task_id")/stdout.log && tail -f ~/.claude/skills/remote-collab/runtime/tasks/$(printf '%q' "$task_id")/stdout.log"
  run_ssh "$remote_cmd" || die "Cannot read log for task '$task_id' on $target"
}

bg_kill() {
  local target="$1"
  local task_id="$2"

  validate_task_id "$task_id"
  resolve_host "$target"
  build_ssh_array

  "${SSH_ARRAY[@]}" "TASK_ID=$(printf '%q' "$task_id") bash -s" <<'REMOTE_SCRIPT'
set -euo pipefail

task_dir="$HOME/.claude/skills/remote-collab/runtime/tasks/$TASK_ID"
[[ -d "$task_dir" ]] || { echo "Task not found: $TASK_ID" >&2; exit 1; }

pid="$(cat "$task_dir/pid" 2>/dev/null || true)"
stored_start="$(cat "$task_dir/start_time" 2>/dev/null || true)"
[[ -n "$pid" && -n "$stored_start" ]] || { echo "Task metadata incomplete: $TASK_ID" >&2; exit 1; }

current_start() {
  local pid="$1"
  local start_text
  start_text="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')"
  [[ -n "$start_text" ]] || return 1
  if date -d "$start_text" +%s >/dev/null 2>&1; then
    date -d "$start_text" +%s
  else
    date -j -f '%a %b %e %T %Y' "$start_text" +%s
  fi
}

if ! kill -0 "$pid" 2>/dev/null; then
  echo "Process already dead"
  exit 0
fi

live_start="$(current_start "$pid" 2>/dev/null || true)"
if [[ -n "$live_start" && "$live_start" != "$stored_start" ]]; then
  echo "Refusing to kill stale PID $pid for task $TASK_ID" >&2
  exit 1
fi

kill "$pid"
echo "Killed pid $pid"
REMOTE_SCRIPT
}

confirm_if_needed() {
  local target="$1"
  local cmd="$2"
  local level="$3"

  if [[ "$target" == "all" ]]; then
    local hosts=("${@:4}")
    local target_label
    target_label="$(printf '%s\n' "${hosts[@]}")"
    confirm_command "$target_label" "$cmd" "$level"
    return
  fi

  confirm_command "$target" "$cmd" "$level"
}

run_on_host() {
  local target="$1"
  local mode="$2"
  local cmd="$3"
  local timeout_secs="$4"

  resolve_host "$target"

  if [[ "$mode" == "background" ]]; then
    run_background "$target" "$cmd"
  else
    run_foreground "$cmd" "$timeout_secs"
  fi
}

broadcast_command() {
  local mode="$1"
  local cmd="$2"
  local timeout_secs="$3"
  local host output status failures
  local -a hosts

  hosts=()
  while IFS= read -r _h; do [[ -n "$_h" ]] && hosts+=("$_h"); done < <(get_all_hosts)
  [[ ${#hosts[@]} -gt 0 ]] || die "No hosts configured in hosts.conf"
  failures=0

  for host in "${hosts[@]}"; do
    if ! verify_ssh "$host"; then
      log_host "$host" "UNREACHABLE"
      failures=1
      continue
    fi

    if [[ "$mode" == "background" ]]; then
      if output="$(run_on_host "$host" "$mode" "$cmd" "$timeout_secs" 2>&1)"; then
        while IFS= read -r line; do
          [[ -n "$line" ]] && log_host "$host" "$line"
        done <<<"$output"
      else
        failures=1
        while IFS= read -r line; do
          [[ -n "$line" ]] && log_host "$host" "$line"
        done <<<"$output"
      fi
      continue
    fi

    if output="$(run_on_host "$host" "$mode" "$cmd" "$timeout_secs" 2>&1)"; then
      while IFS= read -r line; do
        log_host "$host" "$line"
      done <<<"$output"
    else
      status=$?
      while IFS= read -r line; do
        [[ -n "$line" ]] && log_host "$host" "$line"
      done <<<"$output"
      log_host "$host" "FAILED (exit $status)"
      failures=1
    fi
  done

  return "$failures"
}

main() {
  local target mode timeout_secs bg_action bg_task_id command

  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  load_config

  target="$1"
  shift

  mode="foreground"
  timeout_secs="${DEFAULT_TIMEOUT:-300}"
  bg_action=""
  bg_task_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bg)
        mode="background"
        shift
        ;;
      --bg-list)
        bg_action="list"
        shift
        ;;
      --bg-log)
        [[ $# -ge 2 ]] || die "--bg-log requires a task ID"
        bg_action="log"
        bg_task_id="$2"
        shift 2
        ;;
      --bg-kill)
        [[ $# -ge 2 ]] || die "--bg-kill requires a task ID"
        bg_action="kill"
        bg_task_id="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires seconds"
        timeout_secs="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  [[ "$timeout_secs" =~ ^[0-9]+$ ]] || die "--timeout must be a non-negative integer"

  case "$bg_action" in
    list)
      bg_list "$target"
      exit 0
      ;;
    log)
      bg_log "$target" "$bg_task_id"
      exit 0
      ;;
    kill)
      bg_kill "$target" "$bg_task_id"
      exit 0
      ;;
  esac

  command="${*:-}"
  [[ -n "$command" ]] || die "No command specified"

  check_command_safety "$command"
  case "${SAFETY_LEVEL:-confirm}" in
    safe)
      ;;
    dangerous)
      if [[ "$target" == "all" ]]; then
        all_hosts=()
        while IFS= read -r _h; do [[ -n "$_h" ]] && all_hosts+=("$_h"); done < <(get_all_hosts)
        [[ ${#all_hosts[@]} -gt 0 ]] || die "No hosts configured in hosts.conf"
        confirm_if_needed "$target" "$command" "dangerous" "${all_hosts[@]}" || exit 1
      else
        confirm_if_needed "$target" "$command" "dangerous" || exit 1
      fi
      ;;
    confirm|*)
      if [[ "$target" == "all" ]]; then
        all_hosts=()
        while IFS= read -r _h; do [[ -n "$_h" ]] && all_hosts+=("$_h"); done < <(get_all_hosts)
        [[ ${#all_hosts[@]} -gt 0 ]] || die "No hosts configured in hosts.conf"
        confirm_if_needed "$target" "$command" "confirm" "${all_hosts[@]}" || exit 1
      else
        confirm_if_needed "$target" "$command" "confirm" || exit 1
      fi
      ;;
  esac

  if [[ "$target" == "all" ]]; then
    broadcast_command "$mode" "$command" "$timeout_secs"
    exit 0
  fi

  verify_ssh "$target" || die "SSH connectivity check failed for $target"
  run_on_host "$target" "$mode" "$command" "$timeout_secs"
}

main "$@"
