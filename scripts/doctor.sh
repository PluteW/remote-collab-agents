#!/usr/bin/env bash
# doctor.sh — Remote collaboration diagnostics
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"; done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    echo -e "  ${GREEN}[PASS]${NC} $label"
    ((PASS_COUNT++)) || true
  else
    echo -e "  ${RED}[FAIL]${NC} $label"
    ((FAIL_COUNT++)) || true
  fi
  return 0
}

check_warn() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    echo -e "  ${GREEN}[PASS]${NC} $label"
    ((PASS_COUNT++)) || true
  else
    echo -e "  ${YELLOW}[WARN]${NC} $label"
    ((WARN_COUNT++)) || true
  fi
}

run_doctor() {
  echo -e "${BOLD}Remote Collaboration Doctor${NC}"
  echo "==========================="

  # Config
  echo -e "\n${BOLD}Config:${NC}"
  check "Config file exists" test -f "$CONFIG_FILE"
  if [[ -f "$CONFIG_FILE" ]]; then
    local perms
    if stat --version &>/dev/null 2>&1; then
      perms=$(stat -c '%a' "$CONFIG_FILE")
    else
      perms=$(stat -f '%Lp' "$CONFIG_FILE")
    fi
    check "Config permissions (0600)" test "$perms" = "600"
    load_config 2>/dev/null || true
  fi

  # Tailscale
  echo -e "\n${BOLD}Tailscale:${NC}"
  check "Tailscale installed" command -v tailscale
  check "Tailscale running" tailscale status

  # Per-host checks
  local var alias
  for var in $(compgen -v 2>/dev/null | grep '^HOSTS_' || true); do
    alias="${var#HOSTS_}"
    resolve_host "$alias" 2>/dev/null || continue

    echo -e "\n${BOLD}Host: $alias ($RESOLVED_HOST)${NC}"
    check_warn "Tailscale reachable" tailscale ping -c 1 --timeout 3s "$RESOLVED_HOST"
    check "SSH passwordless" ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$RESOLVED_PORT" \
      "$RESOLVED_USER@$RESOLVED_HOST" "echo ok"
    check "Remote skill dir exists" ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$RESOLVED_PORT" \
      "$RESOLVED_USER@$RESOLVED_HOST" "test -d ~/.claude/skills/remote-collab"
    check "Remote wrapper deployed" ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$RESOLVED_PORT" \
      "$RESOLVED_USER@$RESOLVED_HOST" "test -x ~/.claude/skills/remote-collab/scripts/remote-wrapper.sh"
    check_warn "All scripts deployed" ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$RESOLVED_PORT" \
      "$RESOLVED_USER@$RESOLVED_HOST" \
      "test -f ~/.claude/skills/remote-collab/scripts/common.sh && test -f ~/.claude/skills/remote-collab/scripts/remote-exec.sh && test -f ~/.claude/skills/remote-collab/scripts/remote-sync.sh && test -f ~/.claude/skills/remote-collab/scripts/doctor.sh"
    check_warn "Remote hosts.conf exists" ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$RESOLVED_PORT" \
      "$RESOLVED_USER@$RESOLVED_HOST" "test -f ~/.config/remote-collab/hosts.conf"

    # Syncthing on remote
    local api_key_var="SYNCTHING_${alias}_KEY"
    if [[ -n "${!api_key_var:-}" ]]; then
      check_warn "Remote Syncthing running" ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$RESOLVED_PORT" \
        "$RESOLVED_USER@$RESOLVED_HOST" "curl -s http://127.0.0.1:8384/rest/system/status >/dev/null 2>&1"
    else
      echo -e "  ${YELLOW}[SKIP]${NC} Remote Syncthing (no API key configured)"
    fi
  done

  # Local Syncthing
  echo -e "\n${BOLD}Local Syncthing:${NC}"
  check_warn "Syncthing running" curl -s http://127.0.0.1:8384/rest/system/status
  if [[ -n "${SYNCTHING_LOCAL_KEY:-}" ]]; then
    check "API key valid" curl -sf -H "X-API-Key: $SYNCTHING_LOCAL_KEY" \
      "${SYNCTHING_LOCAL_API:-http://127.0.0.1:8384}/rest/system/status"
  fi

  # PATH
  echo -e "\n${BOLD}PATH:${NC}"
  check "~/.local/bin in PATH" bash -c "echo \"\$PATH\" | tr ':' '\\n' | grep -q \"$HOME/.local/bin\""
  check_warn "remote-exec in PATH" command -v remote-exec
  check_warn "remote-sync in PATH" command -v remote-sync

  # Summary
  echo -e "\n${BOLD}Summary:${NC} ${GREEN}$PASS_COUNT passed${NC}, ${RED}$FAIL_COUNT failed${NC}, ${YELLOW}$WARN_COUNT warnings${NC}"
  if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
  else
    echo -e "${RED}Some checks failed. Fix issues above and re-run: remote-collab-doctor${NC}"
  fi
  return "$FAIL_COUNT"
}

run_doctor "$@"
