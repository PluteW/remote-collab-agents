---
name: remote-sync
description: Sync files between machines via rsync or manage Syncthing. Triggers on "send file to mac", "sync data", "pull from mac", "check sync status", or /remote-sync.
---

# Remote Sync

Transfer files via rsync and manage Syncthing shared folders.

## When to Use

- User says "把文件传到 mac" / "send file to mac"
- User says "从 mac 拉取" / "pull from mac"
- User says "同步状态" / "sync status"
- User invokes `/remote-sync`

## Shared Folder Paths (IMPORTANT)

rsync push/pull destinations are **restricted** to these shared folders (per machine):

| Machine running script | Target | Allowed Path |
|------------------------|--------|-------------|
| Mac | LOCAL | `/Users/alice/Desktop/MacShare` |
| Mac | workstation_a | `/home/alice/Desktop/WorkstationA-Share` |
| Mac | workstation-b | `/home/bob/Desktop/MacShare` |
| workstation-a | LOCAL | `/home/alice/Desktop/WorkstationA-Share` |
| workstation-a | mac | `/Users/alice/Desktop/MacShare` |
| workstation-a | workstation-b | `/home/bob/Desktop/MacShare` |
| workstation-b | LOCAL | `/home/bob/Desktop/MacShare` |
| workstation-b | mac | `/Users/alice/Desktop/MacShare` |
| workstation-b | workstation_a | `/home/alice/Desktop/WorkstationA-Share` |

Destinations outside these paths will be **rejected**. Use `--force` to override (requires user confirmation).

## How to Use

### rsync Transfer

```bash
# Push to Mac shared folder
remote-sync push mac ./data/result.hdf5 /Users/alice/Desktop/MacShare/result.hdf5

# Pull from Mac shared folder
remote-sync pull mac /Users/alice/Desktop/MacShare/output.csv /home/alice/Desktop/WorkstationA-Share/output.csv

# Background transfer for large files
remote-sync push mac --bg ./data/dataset.zarr /Users/alice/Desktop/MacShare/dataset.zarr

# Check transfer progress
remote-sync rsync-status
```

### Syncthing Management

```bash
# View all shared folders
remote-sync st-status

# View specific folder status
remote-sync st-status MacShare

# Add new shared folder (with preflight check)
remote-sync st-add "ProjectData" ~/data mac:~/data

# Dry run (check without creating)
remote-sync st-add --dry-run "ProjectData" ~/data mac:~/data

# Pause/resume sync
remote-sync st-pause MacShare
remote-sync st-resume MacShare

# Check for conflicts
remote-sync st-conflicts

# Recent sync activity
remote-sync st-recent 20
```

## Safety Rules (MUST follow)

1. **Shared folder boundary** — destinations must be within `SYNC_PATHS_*` configured paths
2. **No overlap** — cannot rsync into active Syncthing folders without `--allow-overlap`
3. **No system paths** — `/etc`, `/usr`, `/bin` etc. blocked without confirmation
4. **Path traversal blocked** — `../../` resolved to absolute before checking
5. **Atomic writes** — `--delay-updates --partial-dir` ensures readers never see incomplete files
6. **Concurrent lock** — directory lock prevents parallel rsync to same destination

## Syncthing Config Locations

```bash
# Ubuntu
~/.local/state/syncthing/config.xml

# Mac
~/Library/Application Support/Syncthing/config.xml

# Read folder paths
grep -A3 '<folder' <config.xml>
```

## Error Handling

- If rsync fails, check `remote-sync rsync-status <id>` for details
- If Syncthing API fails, ensure `SYNCTHING_LOCAL_KEY` is set in hosts.conf
- Run `remote-collab-doctor` to diagnose connectivity issues
