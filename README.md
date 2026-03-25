# Remote Collab Agents

**Distributed AI Agent Collaboration Framework**
**分布式 AI 智能体协作框架**

> An exploration of multi-human, multi-agent collaborative paradigms — where AI agents are not just tools, but evolving nodes in a distributed collaboration network.
>
> 探索多人多智能体协作范式 —— AI Agent 不只是工具，而是分布式协作网络中协同进化的节点。

---

## Vision / 愿景

When you have multiple machines (workstations, laptops, servers) and multiple AI coding agents (Claude Code, Codex, etc.), how should they collaborate?

当你有多台机器（工作站、笔记本、服务器）和多个 AI 编程智能体（Claude Code、Codex 等）时，它们应该如何协作？

This project explores a practical answer: **a mesh of machines and agents that can see, reach, and help each other** — with humans remaining in the loop for trust-critical decisions.

本项目探索一个实践路径：**构建机器与智能体互相可见、可达、可协助的网格** —— 人类在信任关键决策中始终保持在环。

### What This Is / 这是什么

A set of CLI tools and Claude Code skills that enable:

一套 CLI 工具和 Claude Code 技能，实现：

- **Cross-machine command execution** — an agent on machine A can run commands on machine B
- **Bidirectional file sync** — rsync for on-demand transfer, Syncthing for continuous sync
- **Background task management** — long-running jobs survive SSH disconnects, with PID-safe monitoring
- **Distributed diagnostics** — health checks across the entire machine mesh
- **Automated setup** — SSH key distribution, config generation, full mesh establishment

- **跨机器命令执行** — 机器 A 上的智能体可以在机器 B 上运行命令
- **双向文件同步** — rsync 按需传输，Syncthing 持续同步
- **后台任务管理** — 长时间任务在 SSH 断开后存活，带 PID 安全监控
- **分布式诊断** — 跨整个机器网格的健康检查
- **自动化部署** — SSH 密钥分发、配置生成、全网格建立

## The Collaborative Paradigm / 协作范式

### Agents as Network Nodes / 智能体即网络节点

```
┌──────────────────────┐     Tailscale VPN     ┌──────────────────────┐
│   Workstation A      │◄────────────────────►│   Workstation B      │
│   ┌──────────────┐   │     SSH + rsync       │   ┌──────────────┐   │
│   │ Claude Code  │   │                       │   │ Claude Code  │   │
│   │   Agent      │───┼── remote-exec ───────►│   │   Agent      │   │
│   └──────────────┘   │                       │   └──────────────┘   │
│   ┌──────────────┐   │                       │                      │
│   │ Human (SSH)  │   │                       │                      │
│   └──────────────┘   │                       │                      │
└──────────────────────┘                       └──────────────────────┘
          ▲                                              ▲
          │              Syncthing (continuous)           │
          ▼                                              ▼
┌──────────────────────┐                                 │
│   MacBook            │◄────────────────────────────────┘
│   ┌──────────────┐   │
│   │ Claude Code  │   │
│   │   Agent      │   │
│   └──────────────┘   │
└──────────────────────┘
```

In this paradigm, each machine runs its own AI agent. Agents can:

在这种范式下，每台机器运行自己的 AI 智能体。智能体可以：

1. **Delegate tasks across machines** — "Run this training job on the GPU workstation"
2. **Share files seamlessly** — Push data to shared folders, pull results back
3. **Monitor each other** — Health checks, background task status, sync state
4. **Evolve together** — When one agent improves a skill, it can deploy updates to others

1. **跨机器委托任务** — "在 GPU 工作站上运行这个训练任务"
2. **无缝共享文件** — 推送数据到共享文件夹，拉取结果
3. **互相监控** — 健康检查、后台任务状态、同步状态
4. **协同进化** — 当一个智能体改进了技能，可以部署更新到其他智能体

### Human-in-the-Loop Trust Model / 人在环信任模型

Not all actions are equal. The system implements a **three-tier trust model**:

并非所有操作都是等价的。系统实现了**三级信任模型**：

| Tier / 层级 | Examples / 示例 | Behavior / 行为 |
|:---|:---|:---|
| **Safe** / 安全 | `ls`, `hostname`, `df` | Execute directly / 直接执行 |
| **Needs Confirmation** / 需确认 | `python3 train.py`, `pip install` | Ask human first / 先询问人类 |
| **Dangerous** / 危险 | `rm -rf`, `sudo`, `reboot` | Explicit warning + confirmation / 明确警告 + 确认 |

Shell metacharacters (`;`, `&&`, `|`, `$()`) **always** require confirmation, preventing injection attacks like `echo $(rm -rf /)` from being classified as "safe".

Shell 元字符（`;`、`&&`、`|`、`$()`）**始终**需要确认，防止 `echo $(rm -rf /)` 之类的注入攻击被归类为"安全"。

## Architecture / 架构

### Technology Stack / 技术栈

| Layer / 层 | Technology / 技术 | Role / 角色 |
|:---|:---|:---|
| Network / 网络 | Tailscale | Mesh VPN, NAT traversal, encryption / 网格 VPN、NAT 穿透、加密 |
| Transport / 传输 | SSH | Authenticated command execution / 认证命令执行 |
| File Sync / 文件同步 | rsync + Syncthing | On-demand + continuous sync / 按需 + 持续同步 |
| Agent / 智能体 | Claude Code | AI coding assistant with skill system / AI 编程助手及技能系统 |
| Config / 配置 | Bash (restricted parser) | Simple, no YAML deps / 简单，无 YAML 依赖 |

### File Structure / 文件结构

```
remote-collab-agents/
├── scripts/
│   ├── common.sh              # Shared library: config parser, host resolver, safety checks
│   ├── remote-exec.sh         # Remote command execution (foreground/background/broadcast)
│   ├── remote-sync.sh         # rsync transfers + Syncthing management
│   ├── remote-wrapper.sh      # Background task lifecycle (deployed to all machines)
│   ├── doctor.sh              # Distributed health diagnostics
│   └── setup-ssh-keys.sh      # First-time setup wizard (11 steps)
├── skills/
│   ├── remote-exec.md         # Claude Code skill trigger: remote execution
│   └── remote-sync.md         # Claude Code skill trigger: file sync
├── docs/
│   ├── design.md              # Architecture design document
│   ├── reference.md           # Operations reference + troubleshooting
│   └── deployment-guide.md    # Step-by-step deployment guide
└── config/
    └── hosts.conf.example     # Configuration template
```

## Quick Start / 快速开始

### Prerequisites / 前提条件

- 2+ machines with [Tailscale](https://tailscale.com/) installed
- SSH server enabled on each machine
- Bash 3.2+ (macOS compatible)
- [Syncthing](https://syncthing.net/) (optional, for continuous sync)

### Setup / 安装

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/remote-collab-agents.git
cd remote-collab-agents

# Copy skills to Claude Code (on each machine)
mkdir -p ~/.claude/skills/remote-collab/scripts
cp scripts/* ~/.claude/skills/remote-collab/scripts/
cp skills/* ~/.claude/skills/remote-collab/

# Run setup wizard
bash scripts/setup-ssh-keys.sh
```

The setup wizard handles:
1. SSH key generation and distribution
2. Config file creation with auto-detected Tailscale peers
3. Full script deployment to all remote machines
4. Cross-machine SSH mesh establishment
5. Syncthing API key discovery
6. Symlink creation for CLI access
7. Health diagnostics

### Usage / 使用

```bash
# Execute command on remote machine
remote-exec workstation-a "nvidia-smi"

# Background task
remote-exec workstation-a --bg "python3 train.py --epochs 100"
remote-exec workstation-a --bg-list
remote-exec workstation-a --bg-log <task_id>

# Broadcast to all machines
remote-exec all "uptime"

# File transfer
remote-sync push workstation-a ./data/model.pt /home/alice/Desktop/Share/model.pt

# Syncthing status
remote-sync st-status

# Health check
remote-collab-doctor
```

## Deployment Lessons / 部署经验

Real-world deployment across 3 machines revealed key challenges that require **human-agent collaboration**:

在三台机器上的实际部署揭示了需要**人机协作**的关键挑战：

| Challenge / 挑战 | Solution / 解决方案 |
|:---|:---|
| First SSH auth needs password | Human runs `ssh-copy-id` once / 人类执行一次 `ssh-copy-id` |
| Missing `openssh-server` | Human installs: `sudo apt install openssh-server` |
| Different usernames per machine | Config explicitly specifies each: `HOSTS_x="bob@host:22"` |
| `authorized_keys` corruption | Use `ssh-copy-id`, never manual paste / 使用工具，不手动粘贴 |
| Syncthing needs Tailscale IPs | Address must be `tcp://100.64.x.x:22000`, not hostname |
| macOS bash 3.2 limitations | Scripts handle: no `mapfile`, no `flock`, no `grep -oP` |
| Cross-machine SSH mesh | Setup script auto-generates keys and distributes / 自动生成并分发密钥 |

See [docs/reference.md](docs/reference.md) for the complete troubleshooting guide (10 documented issues with solutions).

详见 [docs/reference.md](docs/reference.md) 获取完整的问题排查指南（10个已记录的问题及解决方案）。

## Design Philosophy / 设计哲学

### Security First / 安全优先
- Three-tier command classification prevents accidental destruction
- Config parser rejects `$()`, backticks, `${}` — no code injection
- SSH commands built as arrays (no `eval`)
- JSON constructed via `python3 json.dumps()` (no string interpolation)
- Task IDs validated against path traversal: `^[a-zA-Z0-9._-]+$`

### Platform Agnostic / 平台无关
- Works on macOS (bash 3.2) and Linux (bash 4+)
- Handles GNU vs BSD differences (`stat`, `date`, `md5`)
- No `setsid` on macOS? Falls back to `bash &`
- No `flock` on macOS? Skips locking (accepts concurrency risk)
- No `/proc` on macOS? Uses `ps` for PID verification

### Progressive Trust / 渐进式信任
- Safe commands execute immediately — no friction for routine operations
- Dangerous commands require explicit human confirmation
- Shell metacharacters always trigger review — even in "safe" commands
- Background tasks use PID identity verification to prevent false positives from PID recycling

### Agent Evolution / 智能体进化
- One machine can be designated as the "skill source of truth"
- Updated scripts can be deployed to all machines via `setup-ssh-keys.sh`
- Each machine maintains its own config (different hosts, users, paths)
- Doctor diagnostics ensure consistent deployment across the mesh

## Related Work / 相关工作

This project draws inspiration from:
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — AI coding agent with extensible skill system
- [Tailscale](https://tailscale.com/) — Zero-config mesh VPN
- [Syncthing](https://syncthing.net/) — Continuous peer-to-peer file synchronization
- Multi-agent systems research — distributed problem solving and cooperative AI

## License / 许可证

[MIT](LICENSE)

---

*This project emerged from real deployment experience — every design decision and troubleshooting entry reflects an actual challenge encountered during multi-machine, multi-agent collaboration.*

*本项目源于真实部署经验 —— 每个设计决策和故障排查条目都反映了多机器、多智能体协作中实际遇到的挑战。*
