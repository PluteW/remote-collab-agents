#!/usr/bin/env bash
# remote-sync — Data synchronization via rsync + Syncthing management
# Part of remote-collab skills suite
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"; done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

SKILL_BASE="$SCRIPT_DIR/.."
RUNTIME_DIR="$SKILL_BASE/runtime"
TRANSFERS_DIR="$RUNTIME_DIR/transfers"
LOCKS_DIR="$RUNTIME_DIR/locks"
mkdir -p "$TRANSFERS_DIR" "$LOCKS_DIR"

usage() {
  cat <<'USAGE'
Usage:
  remote-sync push <target> [--bg] [--allow-overlap] [--force] <local_path> <remote_path>
  remote-sync pull <target> [--bg] [--allow-overlap] [--force] <remote_path> <local_path>
  remote-sync rsync-status [transfer_id]
  remote-sync st-status [folder]
  remote-sync st-add [--dry-run|--repair] <label> <local_path> <target>:<remote_path>
  remote-sync st-pause <folder>
  remote-sync st-resume <folder>
  remote-sync st-conflicts
  remote-sync st-recent [count]
  remote-sync -h|--help
USAGE
  exit 0
}

# ── Cross-platform helpers ──

_md5() {
  if command -v md5sum &>/dev/null; then
    md5sum | cut -c1-16
  else
    md5 | cut -c1-16
  fi
}

# ── Path safety check ──
check_path_safety() {
  local path="$1"

  # Resolve relative paths to absolute to prevent ../../ traversal (W7 fix)
  if [[ "$path" == .* || "$path" != /* ]]; then
    path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")" || path="$1"
  fi

  case "$path" in
    "$HOME"*|/tmp/*|/var/tmp/*) return 0 ;;
    /etc/*|/usr/*|/bin/*|/sbin/*|/boot/*|/dev/*|/proc/*|/sys/*)
      log_warn "Writing to system path: $path"
      local response
      read -rp "Are you sure? [y/N] " response
      [[ "$response" =~ ^[Yy]$ ]] || exit 1
      ;;
  esac
}

# ── Shared folder boundary check ──
# Ensures rsync destinations are within configured Syncthing shared folder paths.
# Dies if path is outside boundary unless --force is used.
check_shared_folder_boundary() {
  local path="$1"
  local target="$2"      # host alias (e.g., "mac") or "LOCAL"
  local force="$3"       # "true" to bypass
  local sync_paths_var sync_paths

  if [[ "$target" == "LOCAL" ]]; then
    sync_paths_var="SYNC_PATHS_LOCAL"
  else
    sync_paths_var="SYNC_PATHS_${target}"
  fi
  sync_paths="${!sync_paths_var:-}"

  # If no shared folder paths configured for this target, skip check
  if [[ -z "$sync_paths" ]]; then
    return 0
  fi

  # Normalize: remove trailing slash for comparison
  local norm_path="${path%/}"
  local norm_sync="${sync_paths%/}"

  # Check if path is within the shared folder
  if [[ "$norm_path" == "$norm_sync" || "$norm_path" == "$norm_sync/"* ]]; then
    return 0
  fi

  if [[ "$force" == "true" ]]; then
    log_warn "Destination '$path' is OUTSIDE shared folder '$sync_paths' (--force override)"
    return 0
  fi

  die "Destination '$path' is outside shared folder boundary '$sync_paths'. Use --force to override."
}

# ── Syncthing overlap check ──
check_syncthing_overlap() {
  local path="$1"
  local allow_overlap="${2:-false}"
  local api_key="${SYNCTHING_LOCAL_KEY:-}"
  [[ -z "$api_key" ]] && return 0

  local folders
  folders=$(curl -s -H "X-API-Key: $api_key" \
    "${SYNCTHING_LOCAL_API:-http://127.0.0.1:8384}/rest/config/folders" 2>/dev/null) || return 0

  local folder_path
  while IFS= read -r folder_path; do
    [[ -z "$folder_path" ]] && continue
    # Use trailing-slash boundary to avoid /data matching /data2
    local fp_slash="${folder_path%/}/"
    local p_slash="${path%/}/"
    if [[ "$p_slash" == "$fp_slash"* ]] || [[ "$fp_slash" == "$p_slash"* ]]; then
      if [[ "$allow_overlap" == "true" ]]; then
        log_warn "Destination overlaps Syncthing folder: $folder_path (--allow-overlap set)"
        return 0
      else
        die "Destination overlaps active Syncthing folder: $folder_path. Use --allow-overlap to override."
      fi
    fi
  done < <(echo "$folders" | python3 -c "import sys,json; [print(f['path']) for f in json.load(sys.stdin)]" 2>/dev/null || true)
}

# ── rsync push/pull ──
do_rsync() {
  local direction="$1"; shift
  local target="$1"; shift
  local bg=false
  local allow_overlap=false
  local force=false

  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bg) bg=true; shift ;;
      --allow-overlap) allow_overlap=true; shift ;;
      --force) force=true; shift ;;
      *) break ;;
    esac
  done

  [[ $# -ge 2 ]] || die "Usage: remote-sync $direction <target> [--bg] <path1> <path2>"
  local path1="$1" path2="$2"

  resolve_host "$target"
  local ssh_port="$RESOLVED_PORT"
  local remote_prefix="$RESOLVED_USER@$RESOLVED_HOST:"
  local src dst

  if [[ "$direction" == "push" ]]; then
    src="$path1"
    dst="${remote_prefix}${path2}"
    # Shared folder boundary: remote path must be within SYNC_PATHS_<target>
    check_shared_folder_boundary "$path2" "$target" "$force"
    # Also block obvious system paths
    case "$path2" in
      /etc/*|/usr/*|/bin/*|/sbin/*|/boot/*|/dev/*|/proc/*|/sys/*)
        log_warn "Pushing to system path on remote: $path2"
        local response
        read -rp "Are you sure? [y/N] " response
        [[ "$response" =~ ^[Yy]$ ]] || exit 1
        ;;
    esac
  else
    src="${remote_prefix}${path1}"
    dst="$path2"
    # Shared folder boundary: local path must be within SYNC_PATHS_LOCAL
    check_shared_folder_boundary "$path2" "LOCAL" "$force"
    check_path_safety "$path2"
    check_syncthing_overlap "$path2" "$allow_overlap"
  fi

  # Directory lock (based on destination hash)
  local lock_hash
  lock_hash=$(echo "$dst" | _md5)
  local lock_file="$LOCKS_DIR/${lock_hash}.lock"

  # Build rsync command as array (no eval)
  local -a rsync_cmd
  # Split RSYNC_FLAGS on whitespace into array elements
  read -ra rsync_flags_arr <<< "$RSYNC_FLAGS"
  rsync_cmd=(rsync "${rsync_flags_arr[@]}" -e "ssh -p $ssh_port" -- "$src" "$dst")

  if [[ "$bg" == "true" ]]; then
    local transfer_id
    transfer_id="$(date +%Y%m%d-%H%M%S)-$(head -c4 /dev/urandom | xxd -p)"
    local transfer_dir="$TRANSFERS_DIR/$transfer_id"
    mkdir -p "$transfer_dir"
    printf '%s\n' "${rsync_cmd[*]}" > "$transfer_dir/cmd.txt"

    if command -v flock &>/dev/null; then
      (
        flock -n 200 || { echo "locked" > "$transfer_dir/exitcode"; exit 1; }
        "${rsync_cmd[@]}" --info=progress2 \
          > "$transfer_dir/progress.log" 2>&1
        local ec=$?
        echo "$ec" > "$transfer_dir/exitcode.tmp"
        mv "$transfer_dir/exitcode.tmp" "$transfer_dir/exitcode"
      ) 200>"$lock_file" &
    else
      (
        "${rsync_cmd[@]}" --info=progress2 \
          > "$transfer_dir/progress.log" 2>&1
        local ec=$?
        echo "$ec" > "$transfer_dir/exitcode.tmp"
        mv "$transfer_dir/exitcode.tmp" "$transfer_dir/exitcode"
      ) &
    fi

    echo $! > "$transfer_dir/pid"
    date +%s > "$transfer_dir/start_time"
    log_info "Background transfer started: $transfer_id"
    log_info "Check progress: remote-sync rsync-status $transfer_id"
  else
    if command -v flock &>/dev/null; then
      (
        flock -n 200 || die "Another transfer to same destination is running. Use rsync-status to check."
        "${rsync_cmd[@]}"
      ) 200>"$lock_file"
    else
      "${rsync_cmd[@]}"
    fi
  fi
}

# ── rsync-status ──
do_rsync_status() {
  local specific_id="${1:-}"
  if [[ -n "$specific_id" ]]; then
    local dir="$TRANSFERS_DIR/$specific_id"
    [[ -d "$dir" ]] || die "Transfer not found: $specific_id"
    echo "Transfer: $specific_id"
    echo "Command: $(cat "$dir/cmd.txt" 2>/dev/null || echo '?')"
    if [[ -f "$dir/exitcode" ]]; then
      echo "Status: completed (exit $(cat "$dir/exitcode"))"
    elif [[ -f "$dir/pid" ]] && kill -0 "$(cat "$dir/pid")" 2>/dev/null; then
      echo "Status: running"
      echo "Progress:"
      tail -1 "$dir/progress.log" 2>/dev/null || echo "  (no progress yet)"
    else
      echo "Status: lost"
    fi
    return
  fi

  log_info "Rsync transfers:"
  if [[ ! -d "$TRANSFERS_DIR" ]] || [[ -z "$(ls -A "$TRANSFERS_DIR" 2>/dev/null)" ]]; then
    echo "  (no transfers)"
    return
  fi
  for dir in "$TRANSFERS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local id status
    id="$(basename "$dir")"
    if [[ -f "$dir/exitcode" ]]; then
      status="done($(cat "$dir/exitcode"))"
    elif [[ -f "$dir/pid" ]] && kill -0 "$(cat "$dir/pid")" 2>/dev/null; then
      status="running"
    else
      status="lost"
    fi
    printf "  %-30s %-10s %s\n" "$id" "$status" "$(head -c60 "$dir/cmd.txt" 2>/dev/null || echo '?')"
  done
}

# ── Syncthing helpers ──

st_api_local() {
  local endpoint="$1"
  local method="${2:-GET}"
  local data="${3:-}"
  local api_key="${SYNCTHING_LOCAL_KEY:-}"
  local api_url="${SYNCTHING_LOCAL_API:-http://127.0.0.1:8384}"

  [[ -z "$api_key" ]] && die "SYNCTHING_LOCAL_KEY not set in hosts.conf"

  if [[ "$method" == "GET" ]]; then
    curl -s -H "X-API-Key: $api_key" "$api_url$endpoint"
  else
    curl -s -X "$method" -H "X-API-Key: $api_key" -H "Content-Type: application/json" \
      -d "$data" "$api_url$endpoint"
  fi
}

# SSH tunnel state
ST_REMOTE_PORT=""
ST_TUNNEL_PID=""

st_open_tunnel() {
  local target="$1"
  resolve_host "$target"

  # Find available local port
  ST_REMOTE_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")

  # Launch tunnel in background (without -f, so $! works)
  ssh -NL "${ST_REMOTE_PORT}:127.0.0.1:8384" \
    -o ExitOnForwardFailure=yes \
    -o ConnectTimeout=5 \
    -p "$RESOLVED_PORT" "$RESOLVED_USER@$RESOLVED_HOST" &
  ST_TUNNEL_PID=$!

  # Wait briefly for tunnel to establish
  sleep 1

  # Verify tunnel is alive
  if ! kill -0 "$ST_TUNNEL_PID" 2>/dev/null; then
    die "Failed to establish SSH tunnel to $target for Syncthing API"
  fi

  # Register cleanup
  trap "kill $ST_TUNNEL_PID 2>/dev/null; wait $ST_TUNNEL_PID 2>/dev/null || true" EXIT
}

st_api_remote() {
  local endpoint="$1"
  local method="${2:-GET}"
  local data="${3:-}"
  local target="$4"
  local api_key_var="SYNCTHING_${target}_KEY"
  local api_key="${!api_key_var:-}"

  [[ -z "$api_key" ]] && die "Syncthing API key for $target not configured (set $api_key_var in hosts.conf)"

  if [[ "$method" == "GET" ]]; then
    curl -s -H "X-API-Key: $api_key" "http://127.0.0.1:${ST_REMOTE_PORT}$endpoint"
  else
    curl -s -X "$method" -H "X-API-Key: $api_key" -H "Content-Type: application/json" \
      -d "$data" "http://127.0.0.1:${ST_REMOTE_PORT}$endpoint"
  fi
}

# ── Syncthing subcommands ──

do_st_status() {
  local folder="${1:-}"
  if [[ -n "$folder" ]]; then
    local folder_status
    folder_status=$(st_api_local "/rest/db/status?folder=$folder")
    echo "$folder_status" | python3 -c "
import sys, json
folder = sys.argv[1]
d = json.load(sys.stdin)
print(f'Folder: {folder}')
print(f'  State: {d.get(\"state\",\"unknown\")}')
print(f'  Global Files: {d.get(\"globalFiles\",0)}')
print(f'  Local Files: {d.get(\"localFiles\",0)}')
print(f'  Need Files: {d.get(\"needFiles\",0)}')
print(f'  Errors: {d.get(\"errors\",0)}')
" "$folder"
  else
    local result
    result=$(st_api_local "/rest/config/folders")
    echo "$result" | python3 -c "
import sys, json
folders = json.load(sys.stdin)
if not folders:
    print('  (no folders configured)')
else:
    for f in folders:
        print(f'  {f[\"label\"]:20s} {f[\"path\"]:40s} type={f[\"type\"]}')
"
  fi
}

do_st_pause() {
  [[ -z "${1:-}" ]] && die "Usage: remote-sync st-pause <folder>"
  local json_data
  json_data=$(python3 -c "import sys,json; print(json.dumps({'folder': sys.argv[1]}))" "$1")
  st_api_local "/rest/db/pause" "POST" "$json_data"
  log_info "Paused: $1"
}

do_st_resume() {
  [[ -z "${1:-}" ]] && die "Usage: remote-sync st-resume <folder>"
  local json_data
  json_data=$(python3 -c "import sys,json; print(json.dumps({'folder': sys.argv[1]}))" "$1")
  st_api_local "/rest/db/resume" "POST" "$json_data"
  log_info "Resumed: $1"
}

do_st_conflicts() {
  st_api_local "/rest/config/folders" | python3 -c "
import sys,json,os,glob
folders=json.load(sys.stdin)
found=False
for f in folders:
    path = f['path']
    conflicts = glob.glob(os.path.join(path, '**/*.sync-conflict-*'), recursive=True)
    for c in conflicts:
        found=True
        print(f'  {c}')
if not found:
    print('  No conflicts found.')
"
}

do_st_recent() {
  local count="${1:-10}"
  st_api_local "/rest/events?since=0&limit=$count&events=ItemFinished" | python3 -c "
import sys,json
events=json.load(sys.stdin)
if not events:
    print('  (no recent events)')
else:
    for e in events:
        d=e.get('data',{})
        print(f'  {e.get(\"time\",\"?\"):25s} {d.get(\"action\",\"?\"):8s} {d.get(\"item\",\"?\")}')
" 2>/dev/null || echo "  (no recent events)"
}

do_st_add() {
  local dry_run=false
  local repair=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true; shift ;;
      --repair) repair=true; shift ;;
      *) break ;;
    esac
  done

  if [[ "$repair" == "true" ]]; then
    [[ $# -ge 1 ]] || die "Usage: remote-sync st-add --repair <label>"
    do_st_repair "$1"
    return
  fi

  [[ $# -ge 3 ]] || die "Usage: remote-sync st-add [--dry-run] <label> <local_path> <target>:<remote_path>"

  local label="$1"
  local local_path="$2"
  local target_spec="$3"
  local target="${target_spec%%:*}"
  local remote_path="${target_spec#*:}"

  local folder_id
  folder_id="${label}-$(echo "${label}${local_path}${remote_path}" | _md5 | cut -c1-8)"

  log_info "Preflight check for folder: $label (ID: $folder_id)"

  # Get local device ID
  local local_id
  local_id=$(st_api_local "/rest/system/status" | python3 -c "import sys,json; print(json.load(sys.stdin)['myID'])")
  log_info "Local device: ${local_id:0:12}..."

  # Open tunnel to remote
  st_open_tunnel "$target"
  local remote_id
  remote_id=$(st_api_remote "/rest/system/status" "GET" "" "$target" | python3 -c "import sys,json; print(json.load(sys.stdin)['myID'])")
  log_info "Remote device ($target): ${remote_id:0:12}..."

  # Check folder ID and path uniqueness on both sides
  local local_folders remote_folders
  local_folders=$(st_api_local "/rest/config/folders")
  remote_folders=$(st_api_remote "/rest/config/folders" "GET" "" "$target")

  echo "$local_folders" | python3 -c "
import sys, json
folder_id, local_path = sys.argv[1], sys.argv[2]
folders = json.load(sys.stdin)
for f in folders:
    if f['id'] == folder_id:
        print('ERROR: Folder ID ' + folder_id + ' already exists locally'); sys.exit(1)
    if f['path'] == local_path:
        print('ERROR: Path ' + local_path + ' already used by folder ' + f['label']); sys.exit(1)
" "$folder_id" "$local_path" || die "Folder conflict on local Syncthing"

  echo "$remote_folders" | python3 -c "
import sys, json
folder_id, remote_path = sys.argv[1], sys.argv[2]
folders = json.load(sys.stdin)
for f in folders:
    if f['id'] == folder_id:
        print('ERROR: Folder ID ' + folder_id + ' already exists on remote'); sys.exit(1)
    if f['path'] == remote_path:
        print('ERROR: Path ' + remote_path + ' already used by folder ' + f['label']); sys.exit(1)
" "$folder_id" "$remote_path" || die "Folder conflict on remote Syncthing"

  log_info "Preflight passed. No conflicts."
  echo "  Label:      $label"
  echo "  Folder ID:  $folder_id"
  echo "  Local:      $local_path"
  echo "  Remote ($target): $remote_path"
  echo "  Type:       sendreceive"

  if [[ "$dry_run" == "true" ]]; then
    log_info "Dry run complete. No changes made."
    return
  fi

  local response
  read -rp "Create shared folder? [y/N] " response
  [[ "$response" =~ ^[Yy]$ ]] || return

  # Phase 2: Commit — build JSON safely via argv (no shell interpolation)
  local local_config
  local_config=$(python3 -c "
import sys, json
folder_id, label, path, dev1, dev2 = sys.argv[1:6]
print(json.dumps({
    'id': folder_id, 'label': label, 'path': path, 'type': 'sendreceive',
    'devices': [{'deviceID': dev1}, {'deviceID': dev2}],
    'rescanIntervalS': 60
}))
" "$folder_id" "$label" "$local_path" "$local_id" "$remote_id")

  local remote_config
  remote_config=$(python3 -c "
import sys, json
folder_id, label, path, dev1, dev2 = sys.argv[1:6]
print(json.dumps({
    'id': folder_id, 'label': label, 'path': path, 'type': 'sendreceive',
    'devices': [{'deviceID': dev1}, {'deviceID': dev2}],
    'rescanIntervalS': 60
}))
" "$folder_id" "$label" "$remote_path" "$local_id" "$remote_id")

  log_info "Creating folder on local Syncthing..."
  if ! st_api_local "/rest/config/folders" "POST" "$local_config" >/dev/null; then
    die "Failed to create folder on local Syncthing"
  fi

  log_info "Creating folder on remote Syncthing ($target)..."
  if ! st_api_remote "/rest/config/folders" "POST" "$remote_config" "$target" >/dev/null; then
    log_error "Failed on remote. Rolling back local..."
    st_api_local "/rest/config/folders/$folder_id" "DELETE" >/dev/null 2>&1 || true
    die "Rolled back. Remote Syncthing may need manual check. Try: remote-sync st-add --repair $label"
  fi

  log_info "Folder created on both sides. Waiting for initial sync..."
  sleep 3
  do_st_status "$folder_id"
}

do_st_repair() {
  local label="$1"
  log_info "Repair mode for folder label: $label"

  # Check local
  local local_folders
  local_folders=$(st_api_local "/rest/config/folders")
  local local_found
  local_found=$(echo "$local_folders" | python3 -c "
import sys, json
label = sys.argv[1]
folders = json.load(sys.stdin)
for f in folders:
    if f['label'] == label:
        print(f['id']); sys.exit(0)
print('')
" "$label" 2>/dev/null)

  if [[ -n "$local_found" ]]; then
    log_info "Found folder '$label' (ID: $local_found) on local Syncthing"
    log_warn "Repair for remote side not yet fully automated. Check remote Syncthing Web UI."
    log_info "Local folder config:"
    echo "$local_folders" | python3 -c "
import sys, json
label = sys.argv[1]
for f in json.load(sys.stdin):
    if f['label'] == label:
        print(json.dumps(f, indent=2))
" "$label"
  else
    log_warn "Folder '$label' not found on local Syncthing."
    log_info "If it exists on remote, you may need to re-create with: remote-sync st-add <label> <local_path> <target>:<remote_path>"
  fi
}

# ── Main dispatch ──
main() {
  [[ $# -lt 1 ]] && usage

  local subcmd="$1"; shift

  case "$subcmd" in
    push)           do_rsync push "$@" ;;
    pull)           do_rsync pull "$@" ;;
    rsync-status)   do_rsync_status "$@" ;;
    st-status)      do_st_status "$@" ;;
    st-add)         do_st_add "$@" ;;
    st-pause)       do_st_pause "$@" ;;
    st-resume)      do_st_resume "$@" ;;
    st-conflicts)   do_st_conflicts ;;
    st-recent)      do_st_recent "$@" ;;
    -h|--help)      usage ;;
    *)              die "Unknown subcommand: $subcmd. Run 'remote-sync --help' for usage." ;;
  esac
}

main "$@"
