#!/usr/bin/env bash
# common.sh - Shared library for remote-collab scripts.
# shellcheck shell=bash

set -euo pipefail

REMOTE_COLLAB_VERSION="1.0.0"
CONFIG_FILE="${REMOTE_COLLAB_CONFIG:-$HOME/.config/remote-collab/hosts.conf}"
SHELL_META_PATTERNS_DEFAULT='[;|&$`]|\$\(|<<'

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  BOLD=$'\033[1m'
  NC=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  BOLD=''
  NC=''
fi

SAFE_COMMANDS=()
DANGEROUS_PATTERNS=()
SAFETY_LEVEL="needs-confirmation"
SAFETY_REASON=""
RESOLVED_USER=""
RESOLVED_HOST=""
RESOLVED_PORT="22"

log_info() {
  printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$*"
}

log_warn() {
  printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2
}

log_error() {
  printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

log_host() {
  local host="$1"
  shift
  printf '%b[%s]%b %s\n' "$BLUE" "$host" "$NC" "$*"
}

stat_owner() {
  local path="$1"
  if stat --version >/dev/null 2>&1; then
    stat -c '%U' "$path"
  else
    stat -f '%Su' "$path"
  fi
}

stat_mode() {
  local path="$1"
  if stat --version >/dev/null 2>&1; then
    stat -c '%a' "$path"
  else
    stat -f '%Lp' "$path"
  fi
}

stat_mtime() {
  local path="$1"
  if stat --version >/dev/null 2>&1; then
    stat -c '%Y' "$path"
  else
    stat -f '%m' "$path"
  fi
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

is_single_quoted_literal() {
  local value="$1"
  [[ "$value" =~ ^\'.*\'$ ]]
}

# Safe array parser — reads array entries line-by-line, no eval
_parse_array_from_config() {
  local conf="$1" array_name="$2" target_var="$3"
  local in_array=false
  local entry=""

  eval "$target_var=()"

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Detect array start
    if [[ "$in_array" == false ]] && [[ "$line" =~ ^[[:space:]]*${array_name}[[:space:]]*=\( ]]; then
      in_array=true
      # Handle entries on the same line as opening paren
      local after_paren="${line#*\(}"
      after_paren="$(trim_whitespace "$after_paren")"
      [[ "$after_paren" == ")" || -z "$after_paren" ]] && continue
      line="$after_paren"
    fi

    if [[ "$in_array" == true ]]; then
      # Detect array end
      local trimmed
      trimmed="$(trim_whitespace "$line")"
      [[ "$trimmed" == ")" ]] && break

      # Strip comments (only outside quotes)
      trimmed="${trimmed%%#*}"
      trimmed="$(trim_whitespace "$trimmed")"
      [[ -z "$trimmed" ]] && continue

      # Process space-separated entries on one line
      while [[ -n "$trimmed" ]]; do
        if [[ "$trimmed" == \"* ]]; then
          # Double-quoted entry
          entry="${trimmed#\"}"
          entry="${entry%%\"*}"
          trimmed="${trimmed#\"${entry}\"}"
          trimmed="$(trim_whitespace "$trimmed")"
        elif [[ "$trimmed" == \'* ]]; then
          # Single-quoted entry (safe literal)
          entry="${trimmed#\'}"
          entry="${entry%%\'*}"
          trimmed="${trimmed#\'${entry}\'}"
          trimmed="$(trim_whitespace "$trimmed")"
        else
          # Unquoted entry (single word)
          entry="${trimmed%% *}"
          if [[ "$trimmed" == *" "* ]]; then
            trimmed="${trimmed#* }"
            trimmed="$(trim_whitespace "$trimmed")"
          else
            trimmed=""
          fi
        fi

        # Reject entries with shell metacharacters (prevent injection)
        if [[ "$entry" == *'$('* || "$entry" == *'`'* || "$entry" == *'${'* ]]; then
          die "Disallowed shell expansion in $array_name entry: $entry"
        fi

        eval "$target_var+=(\"$entry\")"
      done
    fi
  done < "$conf"
}

# Validate task ID to prevent path traversal
validate_task_id() {
  local task_id="$1"
  if [[ ! "$task_id" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    die "Invalid task ID (only alphanumeric, dot, hyphen, underscore allowed): $task_id"
  fi
}

# Build SSH command as an array (avoids eval + word splitting issues)
build_ssh_array() {
  SSH_ARRAY=(ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$RESOLVED_PORT" "$RESOLVED_USER@$RESOLVED_HOST")
}

load_config() {
  local conf="${1:-$CONFIG_FILE}"
  local owner=""
  local perms=""
  local line=""
  local key=""
  local value=""
  local array_block=""
  local saw_assignment=0

  [[ -f "$conf" ]] || die "Config file not found: $conf"

  owner="$(stat_owner "$conf")"
  perms="$(stat_mode "$conf")"
  [[ "$owner" == "$(whoami)" ]] || die "Config not owned by current user: $conf (owner: $owner)"
  [[ "$perms" == "600" ]] || die "Config must be mode 0600 (got $perms): $conf"

  SAFE_COMMANDS=()
  DANGEROUS_PATTERNS=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    if [[ "$line" =~ ^[[:space:]]*(SAFE_COMMANDS|DANGEROUS_PATTERNS)[[:space:]]*=\( ]]; then
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="$(trim_whitespace "$value")"
      case "$key" in
        HOSTS_*|SYNCTHING_*|SYNC_PATHS_*|DEFAULT_TIMEOUT|RSYNC_FLAGS|MAX_TASKS|MAX_TASK_DAYS|MAX_TASK_LOG_MB|SHELL_META_PATTERNS)
          if ! is_single_quoted_literal "$value"; then
            [[ "$value" == *'$('* || "$value" == *'`'* ]] && die "Disallowed command substitution in $key"
          fi
          if [[ "$value" =~ ^\".*\"$ ]] || [[ "$value" =~ ^\'.*\'$ ]]; then
            value="${value:1:${#value}-2}"
          fi
          printf -v "$key" '%s' "$value"
          saw_assignment=1
          ;;
        *)
          ;;
      esac
    fi
  done < "$conf"

  # Parse arrays safely line-by-line (no eval)
  _parse_array_from_config "$conf" "SAFE_COMMANDS" SAFE_COMMANDS
  _parse_array_from_config "$conf" "DANGEROUS_PATTERNS" DANGEROUS_PATTERNS

  DEFAULT_TIMEOUT="${DEFAULT_TIMEOUT:-300}"
  RSYNC_FLAGS="${RSYNC_FLAGS:--avzP --partial-dir=.rsync-partial --delay-updates}"
  MAX_TASKS="${MAX_TASKS:-20}"
  MAX_TASK_DAYS="${MAX_TASK_DAYS:-7}"
  MAX_TASK_LOG_MB="${MAX_TASK_LOG_MB:-100}"
  SHELL_META_PATTERNS="${SHELL_META_PATTERNS:-$SHELL_META_PATTERNS_DEFAULT}"

  if (( saw_assignment == 0 )) && [[ ${#SAFE_COMMANDS[@]} -eq 0 ]] && [[ ${#DANGEROUS_PATTERNS[@]} -eq 0 ]]; then
    log_warn "Config loaded, but no recognized settings were found in $conf"
  fi
}

resolve_host() {
  local target="$1"
  local var_name="HOSTS_${target}"
  local host_spec="${!var_name:-}"
  local rest=""

  RESOLVED_USER=""
  RESOLVED_HOST=""
  RESOLVED_PORT="22"

  if [[ -n "$host_spec" ]]; then
    RESOLVED_USER="${host_spec%%@*}"
    rest="${host_spec#*@}"
    RESOLVED_HOST="${rest%%:*}"
    if [[ "$rest" == *:* ]]; then
      RESOLVED_PORT="${rest##*:}"
    fi
    return 0
  fi

  if command -v tailscale >/dev/null 2>&1 && tailscale status 2>/dev/null | grep -q -- "$target"; then
    RESOLVED_USER="$(whoami)"
    RESOLVED_HOST="$target"
    return 0
  fi

  if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    RESOLVED_USER="$(whoami)"
    RESOLVED_HOST="$target"
    return 0
  fi

  die "Cannot resolve host: $target"
}

ssh_cmd() {
  printf 'ssh -o ConnectTimeout=5 -o BatchMode=yes -p %q %q@%q' \
    "$RESOLVED_PORT" "$RESOLVED_USER" "$RESOLVED_HOST"
}

get_all_hosts() {
  compgen -A variable HOSTS_ | sed 's/^HOSTS_//'
}

check_ssh() {
  local target="$1"
  resolve_host "$target"
  local ssh_command
  ssh_command="$(ssh_cmd)"
  eval "$ssh_command" "'echo ok'" >/dev/null 2>&1
}

check_command_safety() {
  local cmd="$1"
  local first_word="${cmd%% *}"
  local pattern=""
  local safe=""

  SAFETY_LEVEL="needs-confirmation"
  SAFETY_REASON="unclassified"

  if printf '%s\n' "$cmd" | grep -Eq "${SHELL_META_PATTERNS:-$SHELL_META_PATTERNS_DEFAULT}"; then
    SAFETY_REASON="shell-metacharacter"
    return 0
  fi

  for pattern in "${DANGEROUS_PATTERNS[@]:-}"; do
    if [[ -n "$pattern" ]] && printf '%s\n' "$cmd" | grep -Eq "$pattern"; then
      SAFETY_LEVEL="dangerous"
      SAFETY_REASON="$pattern"
      return 0
    fi
  done

  for safe in "${SAFE_COMMANDS[@]:-}"; do
    if [[ -n "$safe" ]] && [[ "$cmd" == "$safe" || "$first_word" == "$safe" ]]; then
      SAFETY_LEVEL="safe"
      SAFETY_REASON="$safe"
      return 0
    fi
  done
}

confirm_command() {
  local target="$1"
  local cmd="$2"
  local level="${3:-$SAFETY_LEVEL}"
  local prompt="Command requires confirmation"
  local response=""

  if [[ "$level" == "dangerous" ]]; then
    printf '%b%s%b\n' "$RED" "DANGEROUS COMMAND" "$NC" >&2
    prompt="Dangerous command requires confirmation"
  fi

  printf '%s\n' "$prompt" >&2
  printf '  Target: %s\n' "$target" >&2
  printf '  Command: %s\n' "$cmd" >&2
  read -r -p "Execute? [y/N] " response
  [[ "$response" =~ ^[Yy]$ ]]
}

capture_process_identity() {
  local pid="$1"
  local start_file="$2"
  local cmdline_file="$3"
  local ps_start=""
  local ps_command=""

  : > "$start_file"
  : > "$cmdline_file"

  if [[ -r "/proc/$pid/stat" ]]; then
    awk '{print $22}' "/proc/$pid/stat" > "$start_file" 2>/dev/null || true
  else
    ps_start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')"
    [[ -n "$ps_start" ]] && printf '%s\n' "$ps_start" > "$start_file"
  fi

  if [[ -r "/proc/$pid/cmdline" ]]; then
    tr '\0' '\n' < "/proc/$pid/cmdline" > "$cmdline_file" 2>/dev/null || true
  else
    ps_command="$(ps -o command= -p "$pid" 2>/dev/null)"
    [[ -n "$ps_command" ]] && printf '%s\n' "$ps_command" > "$cmdline_file"
  fi
}

verify_process_identity() {
  local pid="$1"
  local start_file="$2"
  local cmdline_file="$3"
  local current_start=""
  local current_cmdline=""
  local expected_start=""
  local expected_cmdline=""

  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -f "$start_file" && -f "$cmdline_file" ]] || return 1

  expected_start="$(<"$start_file")"
  expected_cmdline="$(<"$cmdline_file")"

  if [[ -r "/proc/$pid/stat" ]]; then
    current_start="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
  else
    current_start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')"
  fi

  if [[ -r "/proc/$pid/cmdline" ]]; then
    current_cmdline="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  else
    current_cmdline="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  fi

  [[ -n "$expected_start" && "$current_start" == "$expected_start" && "$current_cmdline" == "$expected_cmdline" ]]
}
