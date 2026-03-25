#!/usr/bin/env bash
# setup-ssh-keys.sh — First-time remote collaboration setup
# Handles: SSH key generation/distribution, full script deployment,
# per-machine hosts.conf generation, cross-machine SSH mesh, symlinks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/remote-collab"
CONFIG_FILE="$CONFIG_DIR/hosts.conf"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BOLD='\033[1m'; NC='\033[0m'

step()  { echo -e "\n${GREEN}${BOLD}[$1]${NC} $2"; }
pass()  { echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; }
warn()  { echo -e "  ${YELLOW}!${NC} $*"; }

# SSH helper with StrictHostKeyChecking=accept-new for first-time connections
ssh_first() {
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "$RESOLVED_PORT" \
    "$RESOLVED_USER@$RESOLVED_HOST" "$@"
}

ssh_batch() {
  ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -p "$RESOLVED_PORT" "$RESOLVED_USER@$RESOLVED_HOST" "$@"
}

# Get the local machine's hostname (used to identify self in config generation)
LOCAL_HOSTNAME=""
get_local_hostname() {
  if [[ -z "$LOCAL_HOSTNAME" ]]; then
    LOCAL_HOSTNAME="$(hostname)"
  fi
  printf '%s' "$LOCAL_HOSTNAME"
}

do_setup() {
  echo -e "${BOLD}Remote Collaboration Setup${NC}"
  echo "=========================="

  # Step 1: SSH key
  step "1/11" "Checking local SSH key..."
  if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    pass "Found ~/.ssh/id_ed25519"
  elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
    pass "Found ~/.ssh/id_rsa"
  else
    warn "No SSH key found. Generating ed25519 key..."
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N ""
    pass "Generated ~/.ssh/id_ed25519"
  fi

  # Step 2: Config file
  step "2/11" "Checking config file..."
  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    generate_config_template
    pass "Generated config template: $CONFIG_FILE"
    warn "Please review and edit hosts if needed."
  else
    pass "Config exists: $CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE"

  # Load config
  source "$SCRIPT_DIR/common.sh"
  load_config

  # Step 3: SSH key distribution (local → all remotes)
  step "3/11" "Distributing SSH keys to remote hosts..."
  local var alias
  for var in $(compgen -v | grep '^HOSTS_' || true); do
    alias="${var#HOSTS_}"
    resolve_host "$alias"
    echo -n "  $alias ($RESOLVED_USER@$RESOLVED_HOST): "
    if ssh_batch "echo ok" &>/dev/null; then
      pass "SSH already works (key present)"
    else
      warn "Key not installed. Running ssh-copy-id..."
      if ssh-copy-id -o StrictHostKeyChecking=accept-new -p "$RESOLVED_PORT" "$RESOLVED_USER@$RESOLVED_HOST"; then
        pass "Key installed"
      else
        fail "ssh-copy-id failed for $alias"
        warn "Manual fix: ssh-copy-id -p $RESOLVED_PORT $RESOLVED_USER@$RESOLVED_HOST"
      fi
    fi
  done

  # Step 4: Verify SSH
  step "4/11" "Verifying passwordless SSH..."
  for var in $(compgen -v | grep '^HOSTS_' || true); do
    alias="${var#HOSTS_}"
    resolve_host "$alias"
    if ssh_batch "echo ok" &>/dev/null; then
      pass "$alias: OK"
    else
      fail "$alias: FAILED — run: ssh-copy-id -p $RESOLVED_PORT $RESOLVED_USER@$RESOLVED_HOST"
    fi
  done

  # Step 5: Deploy ALL scripts to remote hosts
  step "5/11" "Deploying all scripts to remote hosts..."
  local all_scripts="common.sh remote-exec.sh remote-sync.sh remote-wrapper.sh doctor.sh setup-ssh-keys.sh"
  for var in $(compgen -v | grep '^HOSTS_' || true); do
    alias="${var#HOSTS_}"
    resolve_host "$alias"
    local ssh_target="$RESOLVED_USER@$RESOLVED_HOST"
    ssh_batch "mkdir -p ~/.claude/skills/remote-collab/scripts ~/.claude/skills/remote-collab/runtime/tasks ~/.claude/skills/remote-collab/runtime/transfers ~/.claude/skills/remote-collab/runtime/locks" 2>/dev/null || true
    local scp_files=""
    local f
    for f in $all_scripts; do
      scp_files="$scp_files $SCRIPT_DIR/$f"
    done
    scp -o StrictHostKeyChecking=accept-new -P "$RESOLVED_PORT" $scp_files \
      "${ssh_target}:~/.claude/skills/remote-collab/scripts/" 2>/dev/null || { fail "$alias: scp failed"; continue; }
    ssh_batch "chmod +x ~/.claude/skills/remote-collab/scripts/*.sh" 2>/dev/null
    pass "$alias: all 6 scripts deployed"
  done

  # Step 6: Generate & deploy per-machine hosts.conf to remotes
  step "6/11" "Generating & deploying per-machine hosts.conf..."
  generate_remote_configs

  # Step 7: Cross-machine SSH mesh (ensure all remotes can SSH to each other)
  step "7/11" "Building cross-machine SSH mesh..."
  build_ssh_mesh

  # Step 8: Syncthing API keys
  step "8/11" "Discovering Syncthing API keys..."
  discover_syncthing_keys

  # Step 9: PATH check
  step "9/11" "Checking PATH for ~/.local/bin..."
  mkdir -p "$HOME/.local/bin"
  if echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
    pass "~/.local/bin is in PATH"
  else
    warn "~/.local/bin is NOT in PATH. Add to your shell profile:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi

  # Step 10: Create symlinks (local + remote)
  step "10/11" "Creating symlinks..."
  echo "  Local:"
  for script in remote-exec remote-sync; do
    ln -sf "$SCRIPT_DIR/${script}.sh" "$HOME/.local/bin/$script"
    pass "$script → scripts/${script}.sh"
  done
  ln -sf "$SCRIPT_DIR/setup-ssh-keys.sh" "$HOME/.local/bin/remote-collab-setup"
  ln -sf "$SCRIPT_DIR/doctor.sh" "$HOME/.local/bin/remote-collab-doctor"
  pass "remote-collab-setup → scripts/setup-ssh-keys.sh"
  pass "remote-collab-doctor → scripts/doctor.sh"

  # Remote symlinks
  for var in $(compgen -v | grep '^HOSTS_' || true); do
    alias="${var#HOSTS_}"
    resolve_host "$alias"
    echo "  $alias:"
    ssh_batch "mkdir -p ~/.local/bin && \
      ln -sf ~/.claude/skills/remote-collab/scripts/remote-exec.sh ~/.local/bin/remote-exec && \
      ln -sf ~/.claude/skills/remote-collab/scripts/remote-sync.sh ~/.local/bin/remote-sync && \
      ln -sf ~/.claude/skills/remote-collab/scripts/setup-ssh-keys.sh ~/.local/bin/remote-collab-setup && \
      ln -sf ~/.claude/skills/remote-collab/scripts/doctor.sh ~/.local/bin/remote-collab-doctor" 2>/dev/null \
      && pass "symlinks created" \
      || fail "symlink creation failed"
  done

  # Step 11: Run doctor
  step "11/11" "Running diagnostics..."
  echo ""
  "$SCRIPT_DIR/doctor.sh" || true

  echo ""
  echo -e "${GREEN}${BOLD}Setup complete!${NC}"
  echo ""
  echo "Try:"
  echo "  remote-exec <host> \"hostname\""
  echo "  remote-sync st-status"
  echo "  remote-collab-doctor"
}

# Generate per-machine hosts.conf for each remote host.
# Each remote's config lists the OTHER machines (not itself) with correct usernames.
generate_remote_configs() {
  # Collect all host specs: alias -> user@host:port
  local -a all_aliases=()
  local var alias
  for var in $(compgen -v | grep '^HOSTS_' || true); do
    alias="${var#HOSTS_}"
    all_aliases+=("$alias")
  done

  local local_user local_host
  local_user="$(whoami)"
  local_host="$(get_local_hostname)"

  for var in $(compgen -v | grep '^HOSTS_' || true); do
    alias="${var#HOSTS_}"
    resolve_host "$alias"
    local target_user="$RESOLVED_USER"
    local target_host="$RESOLVED_HOST"
    local target_port="$RESOLVED_PORT"

    # Build config where this remote sees the OTHER machines + local machine
    local remote_conf
    remote_conf="$(mktemp)"

    cat > "$remote_conf" <<HEADER
#!/usr/bin/env bash
# Remote Collaboration Hosts Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Machine: $alias ($target_host)
# NOTE: Do not list the local machine. This file is for $alias.
HEADER

    # Add local machine as a host for this remote
    local local_alias
    local_alias=$(echo "$local_host" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]' | cut -c1-15)
    echo "HOSTS_${local_alias}=\"${local_user}@${local_host}:22\"" >> "$remote_conf"

    # Add other remotes (excluding this remote itself)
    local other_var other_alias
    for other_var in $(compgen -v | grep '^HOSTS_' || true); do
      other_alias="${other_var#HOSTS_}"
      [[ "$other_alias" == "$alias" ]] && continue
      echo "HOSTS_${other_alias}=\"${!other_var}\"" >> "$remote_conf"
    done

    # Append standard config body
    echo "" >> "$remote_conf"
    cat >> "$remote_conf" <<'CONF_BODY'
# Syncthing (filled automatically during setup)
SYNCTHING_LOCAL_API="http://127.0.0.1:8384"
SYNCTHING_LOCAL_KEY=""

# Safe commands — execute without confirmation
SAFE_COMMANDS=(
  ls pwd df hostname uptime date free which
  "tailscale status"
  "syncthing --version"
  nvidia-smi
  "rostopic list"
  "rosnode list"
  "conda info"
)

# Dangerous patterns (grep -E against full command string)
DANGEROUS_PATTERNS=(
  "^rm " "sudo " "reboot" "shutdown" "mkfs"
  "^dd " "kill " "> /dev/" "chmod 777"
)

# Shell metacharacters that always require confirmation
SHELL_META_PATTERNS='[;|&$`]|\$\(|<<'

DEFAULT_TIMEOUT=300
RSYNC_FLAGS="-avzP --partial-dir=.rsync-partial --delay-updates"
MAX_TASKS=20
MAX_TASK_DAYS=7
MAX_TASK_LOG_MB=100
CONF_BODY

    # Deploy to remote
    local ssh_target="${target_user}@${target_host}"
    ssh_batch "mkdir -p ~/.config/remote-collab" 2>/dev/null || true
    scp -o StrictHostKeyChecking=accept-new -P "$target_port" "$remote_conf" \
      "${ssh_target}:~/.config/remote-collab/hosts.conf" 2>/dev/null \
      && { ssh_batch "chmod 600 ~/.config/remote-collab/hosts.conf" 2>/dev/null; pass "$alias: hosts.conf deployed"; } \
      || fail "$alias: hosts.conf deployment failed"

    rm -f "$remote_conf"
  done
}

# Build cross-machine SSH mesh: ensure all remotes can SSH to each other.
# This is best-effort — if a remote lacks ssh-keygen, prints manual instructions.
build_ssh_mesh() {
  local -a aliases=()
  local var alias
  for var in $(compgen -v | grep '^HOSTS_' || true); do
    alias="${var#HOSTS_}"
    aliases+=("$alias")
  done

  # For each pair (A, B), check if A can SSH to B
  local src dst
  for src in "${aliases[@]}"; do
    for dst in "${aliases[@]}"; do
      [[ "$src" == "$dst" ]] && continue

      resolve_host "$src"
      local src_user="$RESOLVED_USER" src_host="$RESOLVED_HOST" src_port="$RESOLVED_PORT"

      resolve_host "$dst"
      local dst_user="$RESOLVED_USER" dst_host="$RESOLVED_HOST" dst_port="$RESOLVED_PORT"

      echo -n "  $src → $dst: "

      # Test if src can already SSH to dst
      if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$src_port" \
        "$src_user@$src_host" \
        "ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $dst_port $dst_user@$dst_host 'echo ok'" &>/dev/null; then
        pass "OK"
        continue
      fi

      # Check if src has an SSH key
      local src_pubkey
      src_pubkey=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$src_port" \
        "$src_user@$src_host" \
        "cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null" 2>/dev/null || true)

      if [[ -z "$src_pubkey" ]]; then
        # Try to generate key on src via our SSH
        warn "No SSH key on $src. Generating..."
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$src_port" \
          "$src_user@$src_host" \
          "command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -q" 2>/dev/null; then
          src_pubkey=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$src_port" \
            "$src_user@$src_host" "cat ~/.ssh/id_ed25519.pub" 2>/dev/null || true)
        fi
      fi

      if [[ -z "$src_pubkey" ]]; then
        fail "NEEDS MANUAL FIX"
        warn "  $src has no SSH key and ssh-keygen unavailable."
        warn "  Manual: ssh into $src, run: ssh-keygen -t ed25519"
        warn "  Then: ssh-copy-id -p $dst_port $dst_user@$dst_host"
        continue
      fi

      # Install src's pubkey on dst
      if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$dst_port" \
        "$dst_user@$dst_host" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$src_pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null; then
        # Accept host key on src side
        ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$src_port" \
          "$src_user@$src_host" \
          "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -p $dst_port $dst_user@$dst_host 'echo ok'" &>/dev/null || true
        pass "Key installed"
      else
        fail "NEEDS MANUAL FIX"
        warn "  Manual: ssh-copy-id from $src to $dst"
      fi
    done
  done
}

generate_config_template() {
  cat > "$CONFIG_FILE" <<'CONF_HEADER'
#!/usr/bin/env bash
# Remote Collaboration Hosts Configuration
CONF_HEADER

  echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$CONFIG_FILE"
  echo "" >> "$CONFIG_FILE"

  # Auto-detect Tailscale peers
  echo "# Host definitions: HOSTS_<alias>=\"<user>@<hostname_or_ip>:<port>\"" >> "$CONFIG_FILE"
  local current_hostname
  current_hostname=$(hostname)
  if command -v tailscale &>/dev/null; then
    tailscale status 2>/dev/null | while read -r ip host user rest; do
      [[ -z "$host" || "$host" == "$current_hostname" ]] && continue
      local alias_name
      alias_name=$(echo "$host" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]' | cut -c1-15)
      echo "HOSTS_${alias_name}=\"$(whoami)@${host}:22\"" >> "$CONFIG_FILE"
    done
  fi
  echo "" >> "$CONFIG_FILE"

  cat >> "$CONFIG_FILE" <<'CONF_BODY'
# Syncthing (filled automatically during setup)
SYNCTHING_LOCAL_API="http://127.0.0.1:8384"
SYNCTHING_LOCAL_KEY=""

# Safe commands — execute without confirmation
SAFE_COMMANDS=(
  ls pwd df hostname uptime date free which
  "tailscale status"
  "syncthing --version"
  nvidia-smi
  "rostopic list"
  "rosnode list"
  "conda info"
)

# Dangerous patterns (grep -E against full command string)
DANGEROUS_PATTERNS=(
  "^rm " "sudo " "reboot" "shutdown" "mkfs"
  "^dd " "kill " "> /dev/" "chmod 777"
)

# Shell metacharacters that always require confirmation
SHELL_META_PATTERNS='[;|&$`]|\$\(|<<'

DEFAULT_TIMEOUT=300
RSYNC_FLAGS="-avzP --partial-dir=.rsync-partial --delay-updates"
MAX_TASKS=20
MAX_TASK_DAYS=7
MAX_TASK_LOG_MB=100
CONF_BODY
}

discover_syncthing_keys() {
  # Local Syncthing
  if curl -s http://127.0.0.1:8384 &>/dev/null; then
    local local_key=""
    local config_path
    for config_path in \
      "$HOME/.config/syncthing/config.xml" \
      "$HOME/.local/state/syncthing/config.xml" \
      "$HOME/Library/Application Support/Syncthing/config.xml"; do
      if [[ -f "$config_path" ]]; then
        local_key=$(grep '<apikey>' "$config_path" 2>/dev/null | sed 's/.*<apikey>//' | sed 's/<.*//' | head -1 || true)
        [[ -n "$local_key" ]] && break
      fi
    done
    if [[ -n "$local_key" ]]; then
      # Update config file
      if grep -q '^SYNCTHING_LOCAL_KEY=' "$CONFIG_FILE"; then
        sed -i.bak "s|^SYNCTHING_LOCAL_KEY=.*|SYNCTHING_LOCAL_KEY=\"$local_key\"|" "$CONFIG_FILE"
        rm -f "${CONFIG_FILE}.bak"
      fi
      pass "Local Syncthing key found"
    else
      warn "Could not find local Syncthing API key"
    fi
  else
    warn "Local Syncthing not running"
  fi

  # Remote Syncthing
  local var alias
  for var in $(compgen -v | grep '^HOSTS_' || true); do
    alias="${var#HOSTS_}"
    resolve_host "$alias"
    local remote_key
    remote_key=$(ssh -o ConnectTimeout=5 -p "$RESOLVED_PORT" \
      "$RESOLVED_USER@$RESOLVED_HOST" \
      "grep '<apikey>' ~/.config/syncthing/config.xml ~/.local/state/syncthing/config.xml ~/Library/Application\ Support/Syncthing/config.xml 2>/dev/null | sed 's/.*<apikey>//' | sed 's/<.*//' | head -1" \
      2>/dev/null || true)
    if [[ -n "$remote_key" ]]; then
      if grep -q "^SYNCTHING_${alias}_KEY=" "$CONFIG_FILE"; then
        sed -i.bak "s|^SYNCTHING_${alias}_KEY=.*|SYNCTHING_${alias}_KEY=\"$remote_key\"|" "$CONFIG_FILE"
        rm -f "${CONFIG_FILE}.bak"
      else
        echo "SYNCTHING_${alias}_KEY=\"$remote_key\"" >> "$CONFIG_FILE"
      fi
      pass "$alias: Syncthing key found"
    else
      warn "$alias: Syncthing not found or key unavailable"
    fi
  done
}

do_setup "$@"
