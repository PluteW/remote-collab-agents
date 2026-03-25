---
name: remote-exec
description: Execute commands on remote machines via SSH over Tailscale. Triggers on "run X on mac", "execute on ubuntu", "check mac status", or /remote-exec.
---

# Remote Exec

Execute commands on remote hosts configured in `~/.config/remote-collab/hosts.conf`.

## When to Use

- User says "在 mac 上运行 X" / "run X on mac"
- User says "检查 mac 状态" / "check mac status"
- User invokes `/remote-exec`
- Any task requiring command execution on a remote machine

## How to Use

Run via Bash tool. The CLI symlink `remote-exec` points to `~/.claude/skills/remote-collab/scripts/remote-exec.sh`.

```bash
# Foreground (safe commands run immediately)
remote-exec mac "hostname"
remote-exec mac "ls ~/Desktop/MacShare/"

# Background task
remote-exec mac --bg "python3 long_task.py"
remote-exec mac --bg-list
remote-exec mac --bg-log <task_id>
remote-exec mac --bg-kill <task_id>

# Timeout override (default 300s)
remote-exec mac --timeout 60 "ping -c 3 google.com"

# Broadcast to all hosts
remote-exec all "uptime"
```

## Safety Rules (MUST follow)

1. **Safe commands** (ls, hostname, cat, etc.) — execute directly, no confirmation needed
2. **Dangerous commands** (rm, sudo, kill, etc.) — **ask user to confirm** before executing
3. **Shell metacharacters** (`;`, `&&`, `|`, `$()`, `>`) — **always ask user to confirm**
4. **Complex work** — delegate to the remote host's Claude Code or Codex, not raw shell commands
5. **File operations** — use `remote-sync` for file transfer, not `remote-exec` with redirection

## Configured Hosts

Hosts vary per machine (each machine only lists the *other* machines). See `~/.config/remote-collab/hosts.conf`.

| Alias | User@Host | Port | Notes |
|-------|-----------|------|-------|
| mac | alice@macbook-alice | 22 | macOS |
| workstation_a | alice@workstation-a | 22 | 主工作站, skill 开发机 |
| workstation-b | bob@workstation-b | 22 | 远程工作站 |

**注意**: workstation-a 是 skill 的源开发机器。如果 workstation-a 上有更新的脚本版本，应优先采用。

## Error Handling

- Connection timeout: 5 seconds (SSH `ConnectTimeout=5`)
- Auth: SSH key (BatchMode=yes), no password prompt
- If SSH fails, suggest running `remote-collab-doctor` to diagnose
