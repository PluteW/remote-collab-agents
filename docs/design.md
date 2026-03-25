# Remote Collaboration Skills Design

**Date**: 2026-03-24
**Version**: 2.0
**Status**: Approved (post-review, incorporating Codex + internal review feedback)

## Overview

Two Claude Code skills + standalone CLI scripts for cross-computer collaboration between Ubuntu workstation(s) and Mac, built on Tailscale + SSH + rsync + Syncthing.

## Network Topology

| Host | Tailscale IP | OS | User | Role |
|------|--------------|----|------|------|
| workstation-a | 100.64.0.1 | Ubuntu 24.04 (RT kernel) | alice | Primary workstation / skill dev host |
| macbook-alice | 100.64.0.2 | macOS | alice | Secondary / camera node |
| workstation-b | 100.64.0.3 | Ubuntu 22.04 | bob | Remote workstation |

- Tailscale: workstation-a direct, workstation-b via relay (~1200ms)
- Syncthing: `MacShare` folder three-way sync (using Tailscale IPs as device addresses)
- SSH: Full mesh (6 directional connections), keys configured via setup script
- **Note**: Each machine has different username (workstation-b uses `bob`)
- **Note**: workstation-a is the skill source-of-truth machine

## Architecture

### Configuration — `~/.config/remote-collab/hosts.conf`

**Bash-specific** config format (requires `#!/usr/bin/env bash`). Loaded via restricted parser, NOT raw `source`.

**Security constraints:**
- File must be owned by current user and mode `0600`; reject if group/world-writable
- Parser only accepts known variable names (whitelist), ignores everything else
- No command substitution, no subshells — pure variable assignment

**Example `hosts.conf`:**

```bash
#!/usr/bin/env bash
# Remote Collaboration Hosts Configuration

# Host definitions: HOSTS_<alias>="<user>@<hostname_or_ip>:<port>"
HOSTS_mac="alice@macbook-alice:22"
HOSTS_ubuntu="alice@workstation-a:22"

# Syncthing API endpoints (accessed via SSH port forwarding for remote)
SYNCTHING_LOCAL_API="http://127.0.0.1:8384"
SYNCTHING_LOCAL_KEY="YOUR_API_KEY_HERE"
SYNCTHING_mac_KEY=""   # Mac's Syncthing API key (filled during setup)

# Safe commands — execute without confirmation (one per line)
SAFE_COMMANDS=(
  ls pwd df hostname uptime date free which
  "tailscale status"
  "syncthing --version"
  "rostopic list"
  "rosnode list"
  nvidia-smi
  "conda info"
)

# Dangerous patterns — force confirmation (grep -E patterns against FULL command string)
DANGEROUS_PATTERNS=(
  "^rm "
  "sudo "
  "reboot"
  "shutdown"
  "mkfs"
  "^dd "
  "kill "
  "> /dev/"
  "chmod 777"
  ":()\{ "
)

# Shell metacharacter patterns — always require confirmation
# Commands containing these are NEVER treated as safe
SHELL_META_PATTERNS='[;|&$`]|\$\(|<<'

# Default timeout for foreground commands (seconds, 0 = no timeout)
DEFAULT_TIMEOUT=300

# Default rsync flags
RSYNC_FLAGS="-avzP --partial-dir=.rsync-partial --delay-updates"

# Background task limits
MAX_TASKS=20          # max concurrent background tasks per host
MAX_TASK_DAYS=7       # auto-cleanup tasks older than this
MAX_TASK_LOG_MB=100   # max total log size per host before cleanup
```

Host resolution order: alias lookup in `HOSTS_*` → Tailscale hostname → Tailscale IP → raw IP.

### Restricted Config Parser (`common.sh`)

```bash
load_config() {
  local conf="$1"
  # Security: reject if not owned by user or world/group writable
  if [[ "$(stat -c '%U' "$conf" 2>/dev/null || stat -f '%Su' "$conf")" != "$(whoami)" ]]; then
    die "Config file not owned by current user: $conf"
  fi
  local perms
  perms=$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf")
  if [[ "$perms" != "600" ]]; then
    die "Config file must be mode 0600 (got $perms): $conf"
  fi
  # Only accept known variable assignments, no command substitution
  while IFS='=' read -r key value; do
    key="${key%%#*}"  # strip comments
    key="${key// /}"  # strip spaces
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      HOSTS_*|SYNCTHING_*|DEFAULT_TIMEOUT|RSYNC_FLAGS|MAX_TASKS|MAX_TASK_DAYS|MAX_TASK_LOG_MB)
        # Strip surrounding quotes
        value="${value%\"}" ; value="${value#\"}"
        value="${value%\'}" ; value="${value#\'}"
        declare -g "$key=$value"
        ;;
    esac
  done < "$conf"
  # Arrays need special handling — source only array blocks
  eval "$(grep -E '^(SAFE_COMMANDS|DANGEROUS_PATTERNS)=\(' "$conf" | head -2)"
}
```

### File Layout

```
~/.claude/skills/remote-collab/
├── design.md               # This document
├── remote-exec.md          # Skill 1: remote command execution
├── remote-sync.md          # Skill 2: remote data synchronization
└── scripts/
    ├── remote-exec.sh      # CLI: remote command execution
    ├── remote-sync.sh      # CLI: remote data synchronization
    ├── common.sh            # Shared: host resolution, config loading, safety check
    ├── remote-wrapper.sh   # Deployed to remote hosts for background task management
    ├── setup-ssh-keys.sh   # First-time SSH key setup
    └── doctor.sh            # Diagnostics command

~/.config/remote-collab/
└── hosts.conf              # Host configuration (bash, mode 0600)

~/.local/bin/
├── remote-exec             # symlink → scripts/remote-exec.sh
├── remote-sync             # symlink → scripts/remote-sync.sh
├── remote-collab-setup     # symlink → scripts/setup-ssh-keys.sh
└── remote-collab-doctor    # symlink → scripts/doctor.sh
```

## Skill 1: remote-exec

### Claude Code Trigger
- Slash command: `/remote-exec`
- Natural language: "run X on mac", "execute Y on ubuntu"

### CLI Interface

```bash
remote-exec <target> "<command>"                  # foreground execution
remote-exec <target> --bg "<command>"             # background execution
remote-exec <target> --bg-list                    # list background tasks
remote-exec <target> --bg-log <task_id>           # view task output
remote-exec <target> --bg-kill <task_id>          # kill background task
remote-exec <target> --timeout <seconds> "<cmd>"  # custom timeout
remote-exec all "<command>"                       # broadcast to all hosts
```

### Security Model

Three-tier command classification:
1. **Shell metacharacter check**: if command contains `;`, `&&`, `||`, `$()`, backticks, heredocs → always requires confirmation (regardless of safe_commands)
2. **dangerous_patterns** matched (grep -E against **full command string**) → forced confirmation
3. **safe_commands** matched (exact match on full command or first word) → direct execution
4. **unclassified** → requires confirmation

This ensures `echo "hello"` is safe but `echo $(rm -rf /)` is not.

### Background Task Management

Tasks stored on the **remote host** in `~/.remote-collab/tasks/<task_id>/`:
- `cmd.txt` — original command
- `stdout.log` / `stderr.log` — output streams
- `pid` — process ID
- `start_time` — epoch timestamp (for PID identity verification)
- `cmdline` — `/proc/$pid/cmdline` snapshot (for PID identity verification)
- `exitcode` — written atomically on completion (via `mv`)
- `exit_reason` — `completed`, `killed`, `crashed`, `timeout`
- `started_at` — human-readable timestamp

Task ID format: `<hostname>-<YYYYMMDD-HHMMSS>-<8char_random>` (mktemp-style random suffix to prevent collisions)

**Remote wrapper script** (`remote-wrapper.sh`, deployed to `~/.remote-collab/bin/` on remote hosts):

```bash
#!/usr/bin/env bash
set -euo pipefail
TASK_ID="$1"; shift
CMD="$*"
TASK_DIR="$HOME/.remote-collab/tasks/$TASK_ID"
mkdir -p "$TASK_DIR"

# Spawn in new session (survives SSH disconnect)
setsid bash -lc "$CMD" > "$TASK_DIR/stdout.log" 2> "$TASK_DIR/stderr.log" &
CHILD_PID=$!

echo "$CHILD_PID" > "$TASK_DIR/pid"
echo "$CMD" > "$TASK_DIR/cmd.txt"
date +%s > "$TASK_DIR/start_time"
cat /proc/$CHILD_PID/cmdline 2>/dev/null > "$TASK_DIR/cmdline" || true
date '+%Y-%m-%d %H:%M:%S' > "$TASK_DIR/started_at"

# Trap signals for clean exit reporting
cleanup() {
  local reason="${1:-killed}"
  echo "$reason" > "$TASK_DIR/exit_reason.tmp"
  mv "$TASK_DIR/exit_reason.tmp" "$TASK_DIR/exit_reason"
}
trap 'cleanup killed' TERM INT HUP

# Wait for child and record exit
wait $CHILD_PID 2>/dev/null
EXIT_CODE=$?
echo "$EXIT_CODE" > "$TASK_DIR/exitcode.tmp"
mv "$TASK_DIR/exitcode.tmp" "$TASK_DIR/exitcode"
if [[ $EXIT_CODE -eq 0 ]]; then
  cleanup completed
else
  cleanup crashed
fi
```

**PID identity verification** (prevents PID-recycling false positives):
- Read `pid` + `start_time` from task dir
- Check `kill -0 $pid` (process exists)
- Compare stored `start_time` against `/proc/$pid/stat` field 22 (starttime) or `ps -o lstart= -p $pid`
- If PID exists but identity doesn't match → mark task as `stale`

**Stale task detection** (`--bg-list`):
- PID dead + no `exitcode` → status: `lost`
- PID alive + identity mismatch → status: `stale`
- PID alive + identity match → status: `running`
- `exitcode` exists → read `exit_reason` for final status

**Auto-cleanup**: on each `--bg-list` invocation, remove task dirs older than `MAX_TASK_DAYS`. If total log size exceeds `MAX_TASK_LOG_MB`, remove oldest completed tasks first.

### Broadcast Semantics (`remote-exec all`)

- **Execution**: sequential (one host at a time)
- **Output**: prefixed with `[hostname]` per line
- **Failure handling**: if one host is unreachable (SSH timeout), print warning `[hostname] UNREACHABLE` and continue to next host
- **Confirmation**: prompted once for all hosts (shows command + list of targets)

### Timeout and Signal Handling

- Default timeout: 300s (configurable in `hosts.conf` and per-invocation with `--timeout`)
- `Ctrl+C` in foreground mode: SIGINT propagates through SSH to remote process
- Timeout reached: SSH session killed, remote process receives SIGHUP (standard SSH behavior)

### Execution Flow

1. Load config via restricted parser (`common.sh:load_config`)
2. Parse target host (resolve alias/hostname/IP)
3. Verify SSH connectivity (`ssh -o ConnectTimeout=3 -o BatchMode=yes`)
4. Classify command safety:
   a. Check shell metacharacters → if found, require confirmation
   b. Check dangerous_patterns (grep -E full command) → if matched, force confirmation
   c. Check safe_commands → if matched, execute directly
   d. Otherwise → require confirmation
5. Execute via SSH:
   - Foreground: `timeout $TIMEOUT ssh user@host "bash -lc '<command>'"` — stream stdout/stderr
   - Background: `ssh user@host "~/.remote-collab/bin/remote-wrapper.sh <task_id> <command>"` — return task_id
6. Return: exit code + stdout + stderr (foreground) or task_id (background)

## Skill 2: remote-sync

### Two Sub-functions

#### A) rsync On-demand Transfer

```bash
remote-sync push <target> <local_path> <remote_path>        # upload
remote-sync pull <target> <remote_path> <local_path>         # download
remote-sync push <target> --bg <local_path> <remote_path>    # background upload
remote-sync pull <target> --bg <remote_path> <local_path>    # background download
remote-sync rsync-status                                      # all rsync transfer progress
remote-sync rsync-status <transfer_id>                        # specific transfer
```

Default rsync flags: `-avzP --partial-dir=.rsync-partial --delay-updates`
- `--partial-dir`: incomplete files stored in hidden dir, not at final destination
- `--delay-updates`: atomic move of files at end of transfer (readers never see partial files)

**Path safety**:
- Destination path must be under `$HOME` or explicitly listed safe paths
- Attempting to write to system paths (`/etc/`, `/usr/`, `/bin/`) triggers confirmation
- **Syncthing overlap protection**: if destination is inside an active Syncthing folder (checked via Syncthing API), warn and require `--allow-overlap` flag

**Background transfers** stored locally in `~/.remote-collab/transfers/<id>/`:
- `progress.log` — rsync output (using `--info=progress2` for parseable single-line progress)
- `pid` — local rsync process ID
- `start_time` — epoch (for PID identity verification, same as remote-exec)
- `exitcode` — written atomically on completion (`mv` from `.tmp`)
- `cmd.txt` — full rsync command for resume/retry

**Directory locking**: `flock` on `~/.remote-collab/locks/<path_hash>.lock` prevents concurrent rsync to same destination.

#### B) Syncthing Management

```bash
remote-sync st-status [folder]                                   # sync status
remote-sync st-add <label> <local_path> <target>:<remote_path>   # add shared folder
remote-sync st-add --dry-run <label> <local> <target>:<remote>   # preflight check only
remote-sync st-add --repair <label>                              # fix one-sided config
remote-sync st-pause <folder>                                     # pause sync
remote-sync st-resume <folder>                                    # resume sync
remote-sync st-conflicts                                          # list conflict files
remote-sync st-recent [count]                                     # recently synced files
```

**Syncthing API access**:
- Local: direct HTTP to `127.0.0.1:8384` with API key from `hosts.conf`
- Remote: SSH ephemeral port forwarding with cleanup:
  ```bash
  # Allocate random local port, fail early if port taken
  ssh -fNL 0:127.0.0.1:8384 -o ExitOnForwardFailure=yes <host>
  # Parse allocated port from ssh output
  # Store SSH tunnel PID for cleanup via trap
  ```
- Tunnel auto-cleaned via `trap` on script exit

**`st-add` two-phase flow**:

Phase 1 — Preflight:
1. Generate folder ID: `<label>-<8char_hash>`
2. Check folder ID uniqueness on both local and remote Syncthing
3. Check path uniqueness on both sides (no existing folder uses same path)
4. Normalize path casing (macOS is case-insensitive)
5. Get local + remote Syncthing device IDs
6. Verify devices know each other (if not, add device trust on both sides)
7. Print summary and ask for confirmation (or just print if `--dry-run`)

Phase 2 — Commit:
1. Create folder config on local Syncthing (`POST /rest/config/folders`)
2. Create folder config on remote Syncthing (via SSH port forward)
3. Verify: poll both sides for `GET /rest/db/status`:
   - folder exists, devices connected, state progressing toward idle
4. On failure at any step: rollback — delete folder config from whichever side was created

**`st-add --repair`**: checks both sides for existing config, reconciles missing side.

## Doctor Command

`remote-collab-doctor` — comprehensive diagnostics:

```bash
remote-collab-doctor [host]    # check specific host, or all if omitted
```

Checks:
1. Config file exists, permissions correct (0600)
2. Tailscale running, peer reachable (`tailscale ping`)
3. SSH passwordless auth works (`ssh -o BatchMode=yes`)
4. Remote `~/.remote-collab/` directory exists
5. Remote `remote-wrapper.sh` deployed and executable
6. Syncthing running locally
7. Syncthing running on remote (via SSH)
8. Syncthing device trust established (mutual)
9. Syncthing API keys valid
10. `~/.local/bin` in `$PATH`

Output: `[PASS]` / `[FAIL]` / `[WARN]` per check with fix instructions.

## Setup Script

`setup-ssh-keys.sh` handles first-time configuration:

1. Check/generate SSH key (`ed25519`)
2. Generate `~/.config/remote-collab/hosts.conf` template if not exists, set `chmod 0600`
3. Read host definitions from `hosts.conf` (via restricted parser)
4. `ssh-copy-id` to each remote host (requires one-time password entry)
5. Verify passwordless SSH to each host
6. Deploy ALL 6 scripts to `~/.claude/skills/remote-collab/scripts/` on each remote host
7. Generate and deploy per-machine `hosts.conf` to each remote host (each lists only other machines)
8. Build cross-machine SSH mesh (ensure all remotes can SSH to each other, not just local→remote)
9. Discover and store remote Syncthing API keys (via SSH + Syncthing REST API)
10. Verify `~/.local/bin` is in `$PATH`; if not, print instructions to add it
11. Create symlinks in `~/.local/bin/` (local + all remotes)
12. Run `doctor` to validate full setup
13. Print summary

**Human intervention points** (documented in REFERENCE.md):
- First-time SSH password authentication for `ssh-copy-id`
- Remote machines missing `openssh-server`, `ssh-keygen`, or `ssh-copy-id`
- Username mismatches between machines
- Syncthing device addresses must use Tailscale IPs

## Design Decisions

- **Bash-specific config** (not YAML/POSIX): explicit bash requirement, avoids YAML parsing deps
- **Restricted config parser**: prevents code injection from config file while keeping human-readable format
- **Tailscale for networking**: handles NAT traversal, DNS, encryption — no manual network config
- **setsid wrapper for background tasks**: survives SSH disconnect, captures exit code atomically
- **PID identity verification**: prevents PID-recycling false positives via start_time + cmdline comparison
- **SSH ephemeral port forwarding for remote Syncthing**: avoids hardcoded port conflicts, auto-cleanup
- **`--delay-updates` + `--partial-dir` for rsync**: readers never see incomplete files
- **Syncthing overlap protection**: prevents rsync + Syncthing conflicts on same directory
- **Two-phase st-add with rollback**: prevents asymmetric config on failure
- **Sequential broadcast**: predictable output ordering, avoids interleaved stdout
- **flock directory locking**: prevents concurrent rsync to same destination
- **doctor command**: first-time debugging and ongoing health checks
