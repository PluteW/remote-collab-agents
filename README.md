# Remote Collab Agents

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-lightgrey.svg)]()
[![Shell](https://img.shields.io/badge/Shell-Bash%203.2%2B-green.svg)]()
[![Claude Code](https://img.shields.io/badge/Agent-Claude%20Code-blueviolet.svg)](https://docs.anthropic.com/en/docs/claude-code)

**You have 3 machines and Claude Code on each. How do they work together?**

This project gives AI coding agents the ability to **reach across machines** — executing commands, syncing files, and monitoring each other — while humans stay in control of trust-critical decisions.

> Born from real deployment across 3 machines (macOS + Ubuntu). Every design decision and troubleshooting entry reflects an actual challenge encountered.

## Demo

```bash
# Agent on your MacBook delegates a GPU task to a remote workstation
$ remote-exec workstation-a "nvidia-smi"
[remote] workstation-a (alice@100.64.0.1:22) $ nvidia-smi
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 550.54    Driver Version: 550.54    CUDA Version: 12.4           |
| GPU  Name        Persistence-M | Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp  Perf  Pwr:Usage/Cap |         Memory-Usage | GPU-Util  Compute M. |
|   0  GeForce RTX 3060   Off    | 00000000:01:00.0  On |                  N/A |
| 30%   45C    P8    15W / 170W  |    512MiB / 12288MiB |      0%      Default |
+-----------------------------------------------------------------------------+

# Launch a training job in the background — survives SSH disconnects
$ remote-exec workstation-a --bg "python3 train.py --epochs 100"
[bg] Started task train_20260325_143022 on workstation-a (PID: 48291)

# Check all machines at once
$ remote-exec all "uptime"
[remote] workstation-a: 14:30:22 up 12 days, load average: 0.15, 0.10, 0.08
[remote] workstation-b: 14:30:23 up 3 days,  load average: 0.42, 0.38, 0.35
[remote] macbook:       14:30:22 up 1 day,   load average: 1.20, 1.15, 1.10

# Sync files between machines
$ remote-sync push workstation-a ./model.pt /home/alice/Desktop/Share/
[rsync] Transferred model.pt → workstation-a (256.3 MB, 12.8 MB/s)

# Full health diagnostics across the mesh
$ remote-collab-doctor
[doctor] Checking 17 items across 3 machines...
  ✓ SSH connectivity      3/3
  ✓ Tailscale mesh        3/3
  ✓ Scripts deployed      3/3
  ✓ Syncthing sync        3/3
  Result: 17/17 PASS
```

## Why This Exists

Most multi-agent frameworks focus on **orchestrating LLM calls**. This one focuses on something different: **giving agents physical reach across your machines**.

| What others do | What this does |
|:---|:---|
| Agent A calls Agent B's API | Agent A runs commands on Machine B |
| Shared memory / message passing | Shared filesystem via rsync + Syncthing |
| Central orchestrator | Peer-to-peer mesh — every machine is equal |
| Simulated environments | Real SSH on real machines |

## How It Works

```
┌──────────────────────┐     Tailscale VPN      ┌──────────────────────┐
│   Workstation A       │◄─────────────────────►│   Workstation B       │
│   ┌──────────────┐   │      SSH + rsync       │   ┌──────────────┐   │
│   │ Claude Code  │   │                        │   │ Claude Code  │   │
│   │   Agent      │───┼── remote-exec ────────►│   │   Agent      │   │
│   └──────────────┘   │                        │   └──────────────┘   │
│   ┌──────────────┐   │                        │                      │
│   │ Human (SSH)  │   │                        │                      │
│   └──────────────┘   │                        │                      │
└──────────────────────┘                        └──────────────────────┘
          ▲                                               ▲
          │              Syncthing (continuous)            │
          ▼                                               ▼
┌──────────────────────┐                                  │
│   MacBook             │◄────────────────────────────────┘
│   ┌──────────────┐   │
│   │ Claude Code  │   │
│   │   Agent      │   │
│   └──────────────┘   │
└──────────────────────┘
```

Each machine runs its own AI agent. Agents can:

- **Delegate tasks** — "Run this training on the GPU workstation"
- **Share files** — Push data to shared folders, pull results back
- **Monitor each other** — Health checks, background task status, sync state
- **Evolve together** — One agent improves a skill, deploys updates to all others

## Features

- **Cross-machine command execution** — foreground, background, or broadcast to all
- **Background task management** — PID-verified, survives SSH disconnects, with log tailing
- **Bidirectional file sync** — rsync for on-demand, Syncthing for continuous
- **Three-tier safety model** — safe / needs-confirmation / dangerous command classification
- **Shell injection prevention** — metacharacters always trigger human review
- **Distributed diagnostics** — `doctor` checks SSH, Tailscale, Syncthing, scripts, PATH across all machines
- **Automated setup wizard** — 11-step process: key generation, config, deployment, mesh establishment
- **macOS + Linux** — works on bash 3.2 (macOS) and 4+ (Linux), handles GNU/BSD differences

## Quick Start

### Prerequisites

- 2+ machines with [Tailscale](https://tailscale.com/) installed
- SSH server enabled on each machine
- Bash 3.2+ (macOS compatible)
- [Syncthing](https://syncthing.net/) (optional, for continuous sync)

### Install

```bash
git clone https://github.com/PluteW/remote-collab-agents.git
cd remote-collab-agents

# Deploy skills to Claude Code (on each machine)
mkdir -p ~/.claude/skills/remote-collab/scripts
cp scripts/* ~/.claude/skills/remote-collab/scripts/
cp skills/* ~/.claude/skills/remote-collab/

# Run the setup wizard
bash scripts/setup-ssh-keys.sh
```

The wizard handles SSH keys, config files, script deployment, cross-machine mesh, Syncthing discovery, symlinks, and health checks — all in one run.

See [docs/deployment-guide.md](docs/deployment-guide.md) for the full step-by-step guide.

## Safety Model

Not all commands are equal. The system classifies every command before execution:

| Tier | Examples | Behavior |
|:---|:---|:---|
| **Safe** | `ls`, `hostname`, `df`, `nvidia-smi` | Execute directly |
| **Needs Confirmation** | `python3 train.py`, `pip install` | Ask human first |
| **Dangerous** | `rm -rf`, `sudo`, `reboot` | Explicit warning + confirmation |

Shell metacharacters (`;`, `&&`, `|`, `$()`) **always** require confirmation — preventing injection attacks like `echo $(rm -rf /)` from sneaking through as "safe".

## Technology Stack

| Layer | Technology | Role |
|:---|:---|:---|
| Network | [Tailscale](https://tailscale.com/) | Mesh VPN, NAT traversal, encryption |
| Transport | SSH | Authenticated command execution |
| File Sync | rsync + [Syncthing](https://syncthing.net/) | On-demand + continuous sync |
| Agent | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | AI coding assistant with skill system |
| Config | Bash (restricted parser) | Simple, no YAML deps |

## Lessons from Real Deployment

Deploying across 3 machines revealed challenges that require **human-agent collaboration**:

| Challenge | Solution |
|:---|:---|
| First SSH auth needs password | Human runs `ssh-copy-id` once |
| Missing `openssh-server` | Human installs: `sudo apt install openssh-server` |
| Different usernames per machine | Config explicitly specifies each: `HOSTS_x="bob@host:22"` |
| `authorized_keys` corruption | Use `ssh-copy-id`, never manual paste |
| Syncthing needs Tailscale IPs | Address must be `tcp://100.64.x.x:22000`, not hostname |
| macOS bash 3.2 limitations | Scripts handle: no `mapfile`, no `flock`, no `grep -oP` |
| Cross-machine SSH mesh | Setup script auto-generates keys and distributes |

See [docs/reference.md](docs/reference.md) for 10 documented issues with solutions.

## Project Structure

```
remote-collab-agents/
├── scripts/
│   ├── common.sh              # Shared library: config, safety, host resolution
│   ├── remote-exec.sh         # Remote execution (fg/bg/broadcast)
│   ├── remote-sync.sh         # rsync + Syncthing management
│   ├── remote-wrapper.sh      # Background task lifecycle
│   ├── doctor.sh              # Distributed health diagnostics
│   └── setup-ssh-keys.sh      # Setup wizard (11 steps)
├── skills/
│   ├── remote-exec.md         # Claude Code skill: remote execution
│   └── remote-sync.md         # Claude Code skill: file sync
├── docs/
│   ├── design.md              # Architecture design
│   ├── reference.md           # Operations reference + troubleshooting
│   └── deployment-guide.md    # Step-by-step deployment guide
└── config/
    └── hosts.conf.example     # Configuration template
```

## Contributing

This project emerged from hands-on deployment experience. Contributions welcome:

- **New machine types** — tested on macOS + Ubuntu; Windows WSL, Raspberry Pi, cloud VMs untested
- **New agents** — currently built for Claude Code; adapting for Codex, Gemini Code Assist, etc.
- **Security hardening** — the trust model can always be improved
- **Documentation** — deployment guides for different environments

Open an [issue](https://github.com/PluteW/remote-collab-agents/issues) or submit a PR.

## License

[MIT](LICENSE)

---

<details>
<summary><b>🇨🇳 中文版 / Chinese Version</b></summary>

## Remote Collab Agents — 分布式 AI 智能体协作框架

**你有 3 台机器，每台都跑着 Claude Code。它们怎么协作？**

本项目让 AI 编程智能体能够**跨机器协作** —— 执行命令、同步文件、互相监控 —— 同时人类在信任关键决策中保持控制。

> 源于 3 台机器（macOS + Ubuntu）的真实部署经验。每个设计决策和故障排查条目都反映了实际遇到的挑战。

### 核心能力

- **跨机器命令执行** — 前台、后台、广播到所有机器
- **后台任务管理** — PID 验证、SSH 断开后存活、日志追踪
- **双向文件同步** — rsync 按需传输、Syncthing 持续同步
- **三级安全模型** — 安全 / 需确认 / 危险的命令分级
- **Shell 注入防护** — 元字符始终触发人工审查
- **分布式诊断** — doctor 检查所有机器的 SSH、Tailscale、Syncthing、脚本、PATH
- **自动化安装向导** — 11 步流程：密钥生成、配置、部署、网格建立
- **macOS + Linux** — bash 3.2（macOS）和 4+（Linux）兼容，处理 GNU/BSD 差异

### 协作范式

在这种范式下，每台机器运行自己的 AI 智能体。智能体可以：

1. **跨机器委托任务** — "在 GPU 工作站上运行这个训练任务"
2. **无缝共享文件** — 推送数据到共享文件夹，拉取结果
3. **互相监控** — 健康检查、后台任务状态、同步状态
4. **协同进化** — 一个智能体改进了技能，部署更新到其他所有智能体

### 安全模型

| 层级 | 示例 | 行为 |
|:---|:---|:---|
| **安全** | `ls`, `hostname`, `df` | 直接执行 |
| **需确认** | `python3 train.py`, `pip install` | 先询问人类 |
| **危险** | `rm -rf`, `sudo`, `reboot` | 明确警告 + 确认 |

Shell 元字符（`;`、`&&`、`|`、`$()`）**始终**需要确认，防止注入攻击。

### 快速开始

```bash
git clone https://github.com/PluteW/remote-collab-agents.git
cd remote-collab-agents

mkdir -p ~/.claude/skills/remote-collab/scripts
cp scripts/* ~/.claude/skills/remote-collab/scripts/
cp skills/* ~/.claude/skills/remote-collab/

bash scripts/setup-ssh-keys.sh
```

### 部署经验

在三台机器上的实际部署揭示了需要**人机协作**的关键挑战：

| 挑战 | 解决方案 |
|:---|:---|
| 首次 SSH 需要密码 | 人类执行一次 `ssh-copy-id` |
| 缺少 `openssh-server` | 人类安装：`sudo apt install openssh-server` |
| 不同机器用户名不同 | 配置明确指定：`HOSTS_x="bob@host:22"` |
| `authorized_keys` 损坏 | 使用 `ssh-copy-id`，不手动粘贴 |
| Syncthing 需要 Tailscale IP | 地址必须是 `tcp://100.64.x.x:22000` |
| macOS bash 3.2 限制 | 脚本已处理：无 `mapfile`、`flock`、`grep -oP` |
| 跨机器 SSH 全网格 | 安装脚本自动生成密钥并分发 |

详见 [docs/reference.md](docs/reference.md) 获取完整问题排查指南。

</details>
