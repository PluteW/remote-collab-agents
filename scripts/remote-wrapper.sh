#!/usr/bin/env bash
# remote-wrapper.sh - Background task lifecycle manager for remote hosts.
# Usage: remote-wrapper.sh <task_id> <command...>
# shellcheck shell=bash

set -euo pipefail

TASK_ID="${1:-}"
if [[ -z "$TASK_ID" || $# -lt 2 ]]; then
  printf 'Usage: %s <task_id> <command...>\n' "${0##*/}" >&2
  exit 64
fi

# Validate task ID to prevent path traversal
if [[ ! "$TASK_ID" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  printf 'Invalid task ID (only alphanumeric, dot, hyphen, underscore allowed): %s\n' "$TASK_ID" >&2
  exit 65
fi
shift

CMD="$*"
TASK_BASE="${REMOTE_COLLAB_TASK_BASE:-$HOME/.claude/skills/remote-collab/runtime/tasks}"
TASK_DIR="$TASK_BASE/$TASK_ID"
STDOUT_LOG="$TASK_DIR/stdout.log"
STDERR_LOG="$TASK_DIR/stderr.log"
PID_FILE="$TASK_DIR/pid"
CMD_FILE="$TASK_DIR/cmd.txt"
START_FILE="$TASK_DIR/start_time"
CMDLINE_FILE="$TASK_DIR/cmdline"
STARTED_AT_FILE="$TASK_DIR/started_at"
EXITCODE_FILE="$TASK_DIR/exitcode"
EXIT_REASON_FILE="$TASK_DIR/exit_reason"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SH="$SCRIPT_DIR/common.sh"
if [[ -r "$COMMON_SH" ]]; then
  # shellcheck source=common.sh
  source "$COMMON_SH"
fi

mkdir -p "$TASK_DIR"
printf '%s\n' "$CMD" > "$CMD_FILE"
date '+%Y-%m-%d %H:%M:%S' > "$STARTED_AT_FILE"
: > "$STDOUT_LOG"
: > "$STDERR_LOG"

write_atomic_file() {
  local destination="$1"
  local tmp_file="${destination}.tmp.$$"
  shift
  printf '%s\n' "$*" > "$tmp_file"
  mv -f "$tmp_file" "$destination"
}

capture_identity_local() {
  local pid="$1"
  if declare -F capture_process_identity >/dev/null 2>&1; then
    capture_process_identity "$pid" "$START_FILE" "$CMDLINE_FILE"
    return 0
  fi

  : > "$START_FILE"
  : > "$CMDLINE_FILE"
  if [[ -r "/proc/$pid/stat" ]]; then
    awk '{print $22}' "/proc/$pid/stat" > "$START_FILE" 2>/dev/null || true
  else
    ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//' > "$START_FILE" || true
  fi

  if [[ -r "/proc/$pid/cmdline" ]]; then
    tr '\0' '\n' < "/proc/$pid/cmdline" > "$CMDLINE_FILE" 2>/dev/null || true
  else
    ps -o command= -p "$pid" > "$CMDLINE_FILE" 2>/dev/null || true
  fi
}

CHILD_PID=""
FINAL_REASON="crashed"

mark_exit() {
  local reason="$1"
  FINAL_REASON="$reason"
  write_atomic_file "$EXIT_REASON_FILE" "$reason"
}

cleanup_on_signal() {
  local signal_name="$1"
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    # On Linux (setsid available), kill entire process group; otherwise plain kill
    if command -v setsid >/dev/null 2>&1; then
      kill -- -"$CHILD_PID" 2>/dev/null || kill "$CHILD_PID" 2>/dev/null || true
    else
      kill "$CHILD_PID" 2>/dev/null || true
    fi
  fi
  mark_exit "killed"
}

trap 'cleanup_on_signal TERM' TERM
trap 'cleanup_on_signal INT' INT
trap 'cleanup_on_signal HUP' HUP

# setsid creates a new session (Linux only); on macOS fall back to plain background
if command -v setsid >/dev/null 2>&1; then
  setsid bash -lc "$CMD" >>"$STDOUT_LOG" 2>>"$STDERR_LOG" &
else
  bash -lc "$CMD" >>"$STDOUT_LOG" 2>>"$STDERR_LOG" &
fi
CHILD_PID=$!

printf '%s\n' "$CHILD_PID" > "$PID_FILE"
capture_identity_local "$CHILD_PID"

set +e
wait "$CHILD_PID"
exit_code=$?
set -e

write_atomic_file "$EXITCODE_FILE" "$exit_code"

if [[ -f "$EXIT_REASON_FILE" ]]; then
  exit 0
fi

if [[ "$exit_code" -eq 0 ]]; then
  mark_exit "completed"
elif [[ "$exit_code" -eq 143 || "$exit_code" -eq 130 || "$exit_code" -eq 129 ]]; then
  mark_exit "killed"
else
  mark_exit "crashed"
fi

exit 0
