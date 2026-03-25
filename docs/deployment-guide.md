# Remote Collaboration Deployment Guide / 远程协作部署指南

This guide walks through deploying the remote-collab toolset across multiple machines connected via Tailscale VPN. It covers prerequisites, first-machine setup, adding new machines, common issues, and a verification checklist.

本指南详解如何在多台通过 Tailscale VPN 连接的机器上部署 remote-collab 工具集，涵盖先决条件、首台机器配置、新机器加入、常见问题及验证清单。

---

## Table of Contents / 目录

1. [Prerequisites / 先决条件](#1-prerequisites--先决条件)
2. [First Machine Setup / 首台机器配置](#2-first-machine-setup--首台机器配置)
3. [Adding New Machines / 添加新机器](#3-adding-new-machines--添加新机器)
4. [Common Issues and Solutions / 常见问题与解决方案](#4-common-issues-and-solutions--常见问题与解决方案)
5. [Verification Checklist / 验证清单](#5-verification-checklist--验证清单)

---

## 1. Prerequisites / 先决条件

### Tailscale

All machines must join the same Tailscale network to form a private mesh VPN.
所有机器必须加入同一个 Tailscale 网络，形成私有 mesh VPN。

```bash
# Install Tailscale / 安装 Tailscale
# Ubuntu
curl -fsSL https://tailscale.com/install.sh | sh

# macOS
brew install tailscale   # or download from https://tailscale.com/download

# Join the network / 加入网络
sudo tailscale up

# Verify connectivity / 验证连通性
tailscale status
tailscale ping -c 3 <peer-ip>
```

Example network topology / 网络拓扑示例:

| Host / 主机 | Tailscale IP | OS | User / 用户 | Role / 角色 |
|---|---|---|---|---|
| workstation-a | 100.64.0.1 | Ubuntu 24.04 | alice | Primary workstation / 主工作站 |
| macbook-alice | 100.64.0.2 | macOS | alice | Auxiliary node / 辅助节点 |
| workstation-b | 100.64.0.3 | Ubuntu 22.04 | bob | Remote workstation / 远程工作站 |

### SSH (OpenSSH)

Every machine needs an SSH server and client installed.
每台机器都需要安装 SSH 服务端和客户端。

```bash
# Ubuntu — install OpenSSH server / 安装 OpenSSH 服务端
sudo apt install openssh-server

# Verify sshd is running / 确认 sshd 运行中
systemctl status sshd

# macOS — enable Remote Login in System Settings > General > Sharing
# macOS — 在"系统设置 > 通用 > 共享"中开启"远程登录"
```

### Syncthing

Syncthing provides shared folder synchronization across machines.
Syncthing 负责跨机器的共享文件夹同步。

```bash
# Ubuntu
sudo apt install syncthing

# macOS
brew install syncthing

# Start Syncthing / 启动 Syncthing
syncthing serve --no-browser &
```

> **Important / 重要**: Syncthing device addresses **must** use Tailscale IPs (e.g., `tcp://100.64.0.1:22000`), not hostnames or `dynamic`.
> Syncthing 设备地址**必须**使用 Tailscale IP（如 `tcp://100.64.0.1:22000`），不能用主机名或 `dynamic`。

---

## 2. First Machine Setup / 首台机器配置

This section walks through setting up the first machine (e.g., macbook-alice) as the control node.
本节以首台机器（如 macbook-alice）作为控制节点进行配置。

### Step 1: Deploy scripts / 第一步：部署脚本

Copy all 6 scripts to the skills directory:
将全部 6 个脚本复制到 skills 目录：

```bash
mkdir -p ~/.claude/skills/remote-collab/scripts/
cp common.sh remote-exec.sh remote-sync.sh remote-wrapper.sh doctor.sh setup-ssh-keys.sh \
   ~/.claude/skills/remote-collab/scripts/
chmod +x ~/.claude/skills/remote-collab/scripts/*.sh
```

### Step 2: Create CLI symlinks / 第二步：创建 CLI 符号链接

```bash
mkdir -p ~/.local/bin

ln -sf ~/.claude/skills/remote-collab/scripts/remote-exec.sh ~/.local/bin/remote-exec
ln -sf ~/.claude/skills/remote-collab/scripts/remote-sync.sh ~/.local/bin/remote-sync
ln -sf ~/.claude/skills/remote-collab/scripts/doctor.sh ~/.local/bin/remote-collab-doctor
```

Make sure `~/.local/bin` is in your `PATH`.
确保 `~/.local/bin` 在你的 `PATH` 中。

### Step 3: Generate SSH key / 第三步：生成 SSH 密钥

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
```

### Step 4: Create hosts.conf / 第四步：创建 hosts.conf

Each machine's config lists **only the other machines** (never itself).
每台机器的配置**只列出其他机器**（不列出自己）。

```bash
mkdir -p ~/.config/remote-collab
chmod 700 ~/.config/remote-collab

cat > ~/.config/remote-collab/hosts.conf << 'EOF'
# macbook-alice's hosts.conf — lists the OTHER machines only
# macbook-alice 的 hosts.conf — 只列出其他机器
HOSTS_workstation_a="alice@workstation-a:22"
HOSTS_workstation-b="bob@workstation-b:22"
EOF

chmod 0600 ~/.config/remote-collab/hosts.conf
```

> **Note on usernames / 用户名注意**: Different machines may have different login users. workstation-b uses `bob`, while others use `alice`. Always specify the correct remote username.
> 不同机器的登录用户名可能不同。workstation-b 用的是 `bob`，其他是 `alice`。务必写对远程用户名。

### Step 5: Distribute SSH keys / 第五步：分发 SSH 密钥

```bash
# Copy your public key to each remote machine
# 将公钥复制到每台远程机器
ssh-copy-id -p 22 alice@workstation-a
ssh-copy-id -p 22 bob@workstation-b
```

### Step 6: Configure Syncthing / 第六步：配置 Syncthing

1. Open the Syncthing web UI (default: `http://127.0.0.1:8384`).
   打开 Syncthing Web UI（默认：`http://127.0.0.1:8384`）。

2. Add each remote device using its **Tailscale IP**:
   使用 **Tailscale IP** 添加每台远程设备：
   - Address / 地址: `tcp://100.64.0.1:22000` (workstation-a)
   - Address / 地址: `tcp://100.64.0.3:22000` (workstation-b)

3. Create or share a single folder (e.g., `MacShare`):
   创建或共享一个文件夹（如 `MacShare`）：

| Machine / 机器 | Local Path / 本地路径 |
|---|---|
| macbook-alice | `/Users/alice/Desktop/MacShare` |
| workstation-a | `/home/alice/Desktop/WorkstationA-Share` |
| workstation-b | `/home/bob/Desktop/MacShare` |

> **Important / 重要**: Use a single shared folder across all machines. Do not create separate per-machine folders — this causes confusion.
> 所有机器统一使用一个共享文件夹，不要为每台机器各创建一个，那样会造成混乱。

### Step 7: Run the setup wizard (optional) / 第七步：运行配置向导（可选）

If available, the setup script automates Steps 3-5:
如果可用，setup 脚本可自动完成第 3-5 步：

```bash
~/.claude/skills/remote-collab/scripts/setup-ssh-keys.sh
```

### Step 8: Verify / 第八步：验证

```bash
remote-collab-doctor
```

All checks should pass. See the [Verification Checklist](#5-verification-checklist--验证清单) for details.
所有检查应通过，详见[验证清单](#5-verification-checklist--验证清单)。

---

## 3. Adding New Machines / 添加新机器

When a new machine joins the collaboration network, follow these steps from an existing (already-configured) machine.
新机器加入时，从一台已配置好的机器执行以下步骤。

### 3.1 On the new machine / 在新机器上

```bash
# 1. Install and join Tailscale / 安装并加入 Tailscale
sudo tailscale up

# 2. Install SSH server (Ubuntu) / 安装 SSH 服务端
sudo apt install openssh-server

# 3. Generate SSH key / 生成 SSH 密钥
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''

# 4. Install Syncthing / 安装 Syncthing
sudo apt install syncthing
```

### 3.2 From an existing machine / 从已有机器操作

```bash
# 1. Check Tailscale connectivity / 检查 Tailscale 连通性
tailscale status
tailscale ping -c 3 <new-machine-tailscale-ip>

# 2. Copy your SSH key to the new machine / 复制 SSH 密钥到新机器
ssh-copy-id -p 22 <user>@<new-machine>

# 3. Deploy scripts to the new machine / 部署脚本到新机器
rsync -avz ~/.claude/skills/remote-collab/ <user>@<new-machine>:~/.claude/skills/remote-collab/

# 4. Create CLI symlinks on the new machine / 在新机器上创建 CLI 链接
ssh <user>@<new-machine> "mkdir -p ~/.local/bin && \
  ln -sf ~/.claude/skills/remote-collab/scripts/remote-exec.sh ~/.local/bin/remote-exec && \
  ln -sf ~/.claude/skills/remote-collab/scripts/remote-sync.sh ~/.local/bin/remote-sync && \
  ln -sf ~/.claude/skills/remote-collab/scripts/doctor.sh ~/.local/bin/remote-collab-doctor"
```

### 3.3 Build the SSH mesh / 建立 SSH 网格

Every machine must be able to SSH into every other machine (full mesh).
每台机器必须能 SSH 到其他所有机器（全网格）。

```bash
# Example: Allow workstation-b -> workstation-a
# 示例：让 workstation-b 能连 workstation-a

# Read workstation-b's public key and install it on workstation-a
# 读取 workstation-b 的公钥并安装到 workstation-a
ssh bob@workstation-b "cat ~/.ssh/id_ed25519.pub" | \
  ssh alice@workstation-a "cat >> ~/.ssh/authorized_keys"

# Accept the host key for the first connection
# 接受首次连接的 host key
ssh bob@workstation-b "ssh -o StrictHostKeyChecking=accept-new alice@workstation-a 'echo ok'"
```

Repeat for all machine pairs. The setup script's `build_ssh_mesh()` function can automate this.
对所有机器对重复此操作。setup 脚本的 `build_ssh_mesh()` 函数可自动化此过程。

### 3.4 Generate hosts.conf for each machine / 为每台机器生成 hosts.conf

Remember: each machine lists only the **other** machines. Generate the appropriate config and deploy it:
记住：每台机器只列出**其他**机器。生成相应配置并部署：

```bash
# Example: hosts.conf for workstation-a
# 示例：workstation-a 的 hosts.conf
cat > /tmp/hosts.conf << 'EOF'
HOSTS_mac="alice@macbook-alice:22"
HOSTS_workstation-b="bob@workstation-b:22"
EOF

ssh alice@workstation-a "mkdir -p ~/.config/remote-collab && chmod 700 ~/.config/remote-collab"
scp /tmp/hosts.conf alice@workstation-a:~/.config/remote-collab/hosts.conf
ssh alice@workstation-a "chmod 0600 ~/.config/remote-collab/hosts.conf"
rm /tmp/hosts.conf
```

### 3.5 Configure Syncthing for the new machine / 为新机器配置 Syncthing

1. On **every existing machine's** Syncthing UI, add the new device with its **Tailscale IP**.
   在**每台已有机器**的 Syncthing UI 中，用**Tailscale IP** 添加新设备。

2. Share the `MacShare` folder with the new device.
   将 `MacShare` 文件夹共享给新设备。

3. On the **new machine**, accept the folder invitation and set the local path.
   在**新机器**上接受文件夹邀请并设置本地路径。

---

## 4. Common Issues and Solutions / 常见问题与解决方案

### 4.1 SSH first connection requires manual intervention / SSH 首次连接需要人工介入

**Symptom / 现象**: `ssh-copy-id` prompts for a password; first connection asks to confirm the host key.

**Solution / 解决**:
- Run `ssh-copy-id -p 22 user@host` manually the first time and enter the password.
  首次手动执行 `ssh-copy-id -p 22 user@host` 并输入密码。
- Or pre-import host keys: `ssh-keyscan -H <hostname> >> ~/.ssh/known_hosts`
  或预导入 host key：`ssh-keyscan -H <hostname> >> ~/.ssh/known_hosts`
- The setup script uses `StrictHostKeyChecking=accept-new` to auto-accept new host keys.
  setup 脚本使用 `StrictHostKeyChecking=accept-new` 自动接受新 host key。

### 4.2 Remote machine has no SSH server / 远程机器没有 SSH 服务

**Symptom / 现象**: Connection refused when trying to SSH into a machine. Some machines may also lack `ssh-keygen` or `ssh-copy-id`.

**Solution / 解决**:
```bash
# Install sshd / 安装 sshd
sudo apt install openssh-server

# If the remote lacks ssh-keygen, generate a key remotely
# 如果远程缺少 ssh-keygen，从另一台机器远程生成
ssh user@machine "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''"

# If ssh-copy-id is missing, install the public key manually
# 如果缺少 ssh-copy-id，手动安装公钥
ssh A "cat ~/.ssh/id_ed25519.pub" | \
  ssh B "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### 4.3 Usernames differ across machines / 不同机器用户名不同

**Symptom / 现象**: `$(whoami)` guesses the wrong remote username. For example, workstation-b uses `bob` while others use `alice`.

**Solution / 解决**:
- Always specify the correct username in `hosts.conf`:
  在 `hosts.conf` 中务必写对用户名：
  ```
  HOSTS_workstation-b="bob@workstation-b:22"
  ```
- Each machine's `hosts.conf` has different content — generate them separately.
  每台机器的 `hosts.conf` 内容不同，需分别生成。

### 4.4 authorized_keys format corruption / authorized_keys 格式损坏

**Symptom / 现象**: SSH key is a single long line; copy-pasting via terminal can introduce line breaks, causing authentication failure.

**Solution / 解决**:
- Never copy-paste public keys manually. Use `ssh-copy-id` or pipe transfer instead.
  不要手动复制粘贴公钥，使用 `ssh-copy-id` 或管道传输。
- If you must do it manually, verify each key is on a **single line**:
  如果必须手动操作，确保每个 key 是**单行**：
  ```bash
  ssh user@host "wc -l ~/.ssh/authorized_keys"
  # Line count should equal key count / 行数应等于 key 数量
  ```

### 4.5 Syncthing must use Tailscale IPs / Syncthing 必须使用 Tailscale IP

**Symptom / 现象**: Syncthing cannot connect when using hostnames or `dynamic` as device addresses.

**Solution / 解决**:
- Always use Tailscale IPs for device addresses: `tcp://100.64.0.1:22000`
  设备地址始终使用 Tailscale IP：`tcp://100.64.0.1:22000`
- Check Tailscale IPs with: `tailscale status`
  用 `tailscale status` 查看各机器的 Tailscale IP。

### 4.6 Syncthing shared folder confusion / Syncthing 共享文件夹混乱

**Symptom / 现象**: Multiple shared folders created per machine, causing sync confusion.

**Solution / 解决**:
- Use **one** shared folder (`MacShare`) across all machines with the same folder ID.
  所有机器使用**一个**共享文件夹（`MacShare`），folder ID 相同。
- Local paths can differ per machine (see the table in Section 2, Step 6).
  各机器的本地路径可以不同（见第 2 节第 6 步的表格）。

### 4.7 macOS bash 3.2 compatibility / macOS bash 3.2 兼容性

**Symptom / 现象**: Scripts fail on macOS due to missing bash 4+ features (`mapfile`, `declare -g`, `grep -oP`, `flock`).

**Solution / 解决**: These are already handled in the scripts. If you encounter issues:
这些已在脚本中处理。如仍遇到问题：

| Feature / 特性 | Workaround / 替代方案 |
|---|---|
| `mapfile` | Use `while IFS= read -r` loop / 用 `while IFS= read -r` 循环 |
| `declare -g` | Use `printf -v` instead / 用 `printf -v` 替代 |
| `grep -oP` | Use `grep \| sed \| sed` / 用 `grep \| sed \| sed` 替代 |
| `flock` | Conditional check with `command -v flock`; skip if unavailable / 条件检测，不可用时跳过 |
| `setsid` | Conditional: fall back to `bash &` if unavailable / 不可用时回退到 `bash &` |
| `/proc` | PID validation via `ps` / 通过 `ps` 验证 PID |
| `stat` syntax | `stat -f '%Lp'` (Mac) vs `stat -c '%a'` (GNU) |

### 4.8 Tailscale relay vs direct connection / Tailscale 中继与直连

**Symptom / 现象**: `tailscale ping` shows relay connection with high latency (~1200ms) instead of direct (~2.5ms).

**Explanation / 说明**:
- **Relay**: Data goes through Tailscale relay servers. Higher latency but functional.
  数据经过 Tailscale 中继服务器，延迟较高但可用。
- **Direct**: Peer-to-peer connection. Low latency.
  点对点直连，低延迟。
- Persistent relay is usually caused by NAT restrictions. It does not break functionality, only affects speed.
  持续中继通常因 NAT 类型限制，不影响功能，只影响速度。

```bash
# Check connection type / 查看连接类型
tailscale ping -c 3 <host>
```

---

## 5. Verification Checklist / 验证清单

Run through this checklist after setting up or adding a machine. All items should pass.
配置完成或新机器加入后，逐项检查。所有项目应通过。

### Tailscale

- [ ] `tailscale status` — all machines visible / 所有机器可见
- [ ] `tailscale ping -c 3 <each-peer>` — connectivity confirmed / 连通性已确认

### SSH

- [ ] SSH from this machine to every other machine (passwordless) / 从本机到每台其他机器 SSH 免密登录
- [ ] SSH from every other machine to this machine (full mesh) / 从每台其他机器到本机 SSH 免密登录

```bash
# Quick test from macbook-alice / 从 macbook-alice 快速测试
ssh alice@workstation-a "echo ok"
ssh bob@workstation-b "echo ok"
```

### Configuration / 配置

- [ ] `~/.config/remote-collab/hosts.conf` exists with permission `0600` / 文件存在且权限为 0600
- [ ] Config lists only **other** machines (not self) / 配置只列出其他机器（不包含自己）
- [ ] Usernames are correct for each remote machine / 每台远程机器的用户名正确

### Scripts / 脚本

- [ ] All 6 scripts deployed to `~/.claude/skills/remote-collab/scripts/` / 全部 6 个脚本已部署
- [ ] CLI symlinks exist in `~/.local/bin/` (`remote-exec`, `remote-sync`, `remote-collab-doctor`) / CLI 符号链接存在
- [ ] `~/.local/bin` is in `PATH` / 在 PATH 中

### Syncthing

- [ ] Syncthing is running / Syncthing 正在运行
- [ ] All peer devices added with **Tailscale IPs** (not hostnames) / 所有对等设备使用 Tailscale IP 添加
- [ ] `MacShare` folder shared with all devices / MacShare 文件夹已共享给所有设备
- [ ] Local folder path is correct for this machine / 本机的本地文件夹路径正确

### Doctor / 诊断

- [ ] `remote-collab-doctor` — all checks PASS / 所有检查通过

```bash
# Run the full diagnostic / 运行完整诊断
remote-collab-doctor
```

Expected result: all checks pass (e.g., Mac 16/16, Ubuntu 17/17).
预期结果：所有检查通过（如 Mac 16/16、Ubuntu 17/17）。

---

## Quick Reference: hosts.conf per Machine / 快速参考：各机器 hosts.conf

```bash
# macbook-alice
HOSTS_workstation_a="alice@workstation-a:22"
HOSTS_workstation-b="bob@workstation-b:22"

# workstation-a
HOSTS_mac="alice@macbook-alice:22"
HOSTS_workstation-b="bob@workstation-b:22"

# workstation-b
HOSTS_mac="alice@macbook-alice:22"
HOSTS_workstation_a="alice@workstation-a:22"
```

## Quick Reference: Syncthing Config Paths / 快速参考：Syncthing 配置路径

```bash
# Ubuntu
grep -A3 '<folder' ~/.local/state/syncthing/config.xml

# macOS
grep -A3 '<folder' ~/Library/Application\ Support/Syncthing/config.xml
```
