# Remote Collaboration — 运维参考

## 网络拓扑

| 主机 | Tailscale IP | OS | 用户 | 角色 |
|------|-------------|-----|------|------|
| workstation-a | 100.64.0.1 | Ubuntu 24.04 (RT kernel) | alice | 主工作站 / skill 源开发机 |
| macbook-alice | 100.64.0.2 | macOS | alice | 辅助 / 摄像头节点 |
| workstation-b | 100.64.0.3 | Ubuntu 22.04 (6-core CPU, 16G RAM) | bob | 远程工作站 |

**重要**: workstation-a 是 skill 源开发机器。如果 workstation-a 上有更新版本的脚本，应优先采用。

## 配置

- **配置文件**: `~/.config/remote-collab/hosts.conf`（权限 0600，各机器内容不同）
- **每台机器只列出其他机器**，不列出自己
- **用户名注意**: workstation-b 的用户名是 `bob`（不是 `alice`）
- **CLI 入口**: `~/.local/bin/remote-exec`, `remote-sync`, `remote-collab-doctor`（符号链接→ scripts/）
- **远程部署**: 所有机器均部署全部 6 个脚本到 `~/.claude/skills/remote-collab/scripts/`

## Syncthing 共享文件夹

| 项目 | Mac | workstation-a | workstation-b |
|------|-----|-----------|-----|
| 文件夹 ID | `xxxxx-xxxxx` | 同 | 同 |
| 标签 | `MacShare` | `MacShare` | `MacShare` |
| 路径 | `/Users/alice/Desktop/MacShare` | `/home/alice/Desktop/WorkstationA-Share` | `/home/bob/Desktop/MacShare` |

**重要**: Syncthing 设备地址必须使用 **Tailscale IP**（如 `tcp://100.64.0.1:22000`），不能用主机名。详见"部署关键问题"。

### 读取 Syncthing 配置的方法

```bash
# Ubuntu
grep -A3 '<folder' ~/.local/state/syncthing/config.xml

# Mac
grep -A3 '<folder' ~/Library/Application\ Support/Syncthing/config.xml
```

## Mac 环境兼容性

| 问题 | 已修复方案 |
|------|-----------|
| bash 3.2 — 无 `mapfile` | 用 `while IFS= read -r` 循环替代 |
| bash 3.2 — 无 `declare -g` | 已移除，用 `printf -v` 替代 |
| bash 3.2 — 无 `grep -oP` | 用 `grep \| sed \| sed` 替代 |
| 无 `flock` | 条件检测 `command -v flock`，无 flock 时跳过锁定（接受并发风险） |
| 无 `setsid` | wrapper 已做条件判断，无 setsid 时直接 `bash &` |
| 无 `/proc` | PID 验证走 `ps` 路径 |
| `stat` 语法不同 | `stat -f '%Lp'`（Mac）vs `stat -c '%a'`（GNU） |

## 安全机制

1. **三级命令分类**: SAFE_COMMANDS 白名单 → DANGEROUS_PATTERNS 黑名单 → 默认需确认
2. **Shell 元字符检测**: `[;|&$\`]|\$\(|<<`
3. **配置解析器**: 拒绝 `$()`, `` ` ``, `${}` 等命令替换
4. **task_id 校验**: `^[a-zA-Z0-9._-]+$`（防路径穿越）
5. **参数传递**: Python 通过 `sys.argv`（不做 shell 变量插值）
6. **JSON 构建**: `python3 json.dumps()`（不做字符串拼接）
7. **rsync 命令**: 数组构建（不用 eval），`--` 分隔选项与路径
8. **SSH 命令**: `build_ssh_array()` 数组（不做字符串分割）
9. **共享文件夹边界**: `SYNC_PATHS_*` 约束 rsync 目标必须在共享文件夹内（`--force` 覆盖）
10. **路径穿越防护**: 相对路径先 resolve 为绝对路径再检查
11. **Syncthing overlap**: 路径边界用 trailing `/` 匹配，避免 `/data` 误匹配 `/data2`

## 脚本清单

| 脚本 | 运行位置 | 用途 |
|------|---------|------|
| common.sh | 所有机器 | 共享库：配置解析、主机解析、安全检查、日志、PID 验证 |
| remote-exec.sh | 所有机器 | 远程命令执行（前台/后台/广播） |
| remote-sync.sh | 所有机器 | rsync 传输 + Syncthing 管理 |
| remote-wrapper.sh | 所有机器 | 远程后台任务生命周期管理 |
| doctor.sh | 所有机器 | 综合诊断（配置/Tailscale/SSH/Syncthing/PATH） |
| setup-ssh-keys.sh | 所有机器 | 首次配置向导（11步，含跨机器 SSH 网格） |

## 部署关键问题排查（实战经验）

以下是实际部署三台机器时遇到的关键问题及解决方法，新机器加入时请对照排查。

### 1. SSH 首次连接 — 需要人工介入

**现象**: `ssh-copy-id` 需要输入密码，首次连接需要确认 host key。

**解决**:
- 首次连接由用户手动执行一次 `ssh-copy-id -p 22 user@host`，输入密码
- 或者 setup 脚本使用 `StrictHostKeyChecking=accept-new` 自动接受新 host key
- Host key 也可预先导入: `ssh-keyscan -H <hostname> >> ~/.ssh/known_hosts`

### 2. 远程机器没有 SSH 工具

**现象**: workstation-b 机器没有安装 `openssh-server`，连接被拒绝 (Connection refused)。
部分机器可能缺少 `ssh-keygen` 或 `ssh-copy-id`。

**解决**:
- 安装 sshd: `sudo apt install openssh-server`
- 如果缺少 ssh-keygen，可从另一台机器远程生成:
  ```bash
  ssh user@machine "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''"
  ```
- 如果缺少 ssh-copy-id，可手动安装公钥:
  ```bash
  # 从 A 读取公钥，写入 B 的 authorized_keys
  ssh A "cat ~/.ssh/id_ed25519.pub" | ssh B "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
  ```

### 3. 用户名不一致

**现象**: 不同机器的登录用户名不同（如 workstation-b 是 `bob`，其他是 `alice`）。
`generate_config_template` 用 `$(whoami)` 探测会猜错远程用户名。

**解决**:
- hosts.conf 中必须明确写对每台机器的用户名: `HOSTS_workstation-b="bob@workstation-b:22"`
- setup 脚本已改进: 从本机 hosts.conf 读取正确用户名
- 每台机器的 hosts.conf 内容不同，需分别生成

### 4. authorized_keys 格式损坏

**现象**: SSH 公钥是一整行很长的字符串，通过终端复制粘贴时容易被换行截断，
导致 `authorized_keys` 变成多行，认证失败。

**解决**:
- 不要手动复制粘贴公钥，使用 `ssh-copy-id` 或管道传输
- 如果必须手动，确保公钥是**单行**（`wc -l ~/.ssh/authorized_keys` 每个 key 只占一行）
- 检查: `ssh user@host "wc -l ~/.ssh/authorized_keys"` 行数应等于 key 数量

### 5. 跨机器 SSH 全网格

**现象**: setup 脚本只从本机向远程分发密钥，但远程机器之间（如 workstation-a ↔ workstation-b）无法互联。

**解决**:
- setup 脚本新增 `build_ssh_mesh()` 步骤，自动从每台远程读取公钥并安装到其他远程
- 如果自动化失败（远程无 ssh-keygen），需要人工介入:
  ```bash
  # 从 Mac 控制: 在 workstation-b 上生成密钥
  ssh bob@workstation-b "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''"
  # 读取 workstation-b 公钥，安装到 workstation-a
  ssh bob@workstation-b "cat ~/.ssh/id_ed25519.pub" | \
    ssh alice@workstation-a "cat >> ~/.ssh/authorized_keys"
  # 首次连接确认 host key
  ssh bob@workstation-b "ssh -o StrictHostKeyChecking=accept-new alice@workstation-a 'echo ok'"
  ```

### 6. Syncthing 必须使用 Tailscale IP

**现象**: Syncthing 添加设备时，如果使用主机名作为设备地址，可能无法连接
（Syncthing 会尝试 local discovery 或 global discovery，延迟高或不稳定）。

**解决**:
- 添加设备时，地址栏必须填写 Tailscale IP: `tcp://100.64.0.1:22000`
- 不要用 `dynamic` 或主机名
- 通过 Syncthing REST API 添加设备时，JSON 中 `addresses` 字段:
  ```json
  {"addresses": ["tcp://100.64.0.1:22000"]}
  ```
- 用 `tailscale status` 查看各机器的 Tailscale IP

### 7. Syncthing 共享文件夹 — 只需要一个

**现象**: 曾经创建了多个共享文件夹（MacShare + WorkstationB-Share），造成混乱。

**解决**:
- 三台机器统一使用一个共享文件夹 `MacShare`（ID: `xxxxx-xxxxx`）
- 各机器的本地路径不同（见上方表格），但 folder ID 和 label 相同
- 新机器加入时，只需要:
  1. 在新机器上安装 Syncthing
  2. 在所有现有机器的 Syncthing 中添加新设备（用 Tailscale IP）
  3. 在 MacShare 文件夹设置中勾选共享给新设备
  4. 在新机器的 Syncthing 中接受文件夹邀请，指定本地路径

### 8. macOS bash 3.2 兼容性

**现象**: macOS 自带 bash 3.2，不支持 `mapfile`、`declare -g`、`grep -oP`、`flock` 等。
脚本在 macOS 上运行时报错。

**已修复** (详见 Mac 环境兼容性表):
- `mapfile -t` → `while IFS= read -r` 循环
- `declare -g` → `printf -v`
- `grep -oP` → `grep | sed | sed`
- `flock` → `command -v flock` 条件判断，不可用时跳过

### 9. 每台机器的 hosts.conf 配置不同

**现象**: 每台机器只列出**其他机器**（不列自己），且用户名各不相同。

**各机器配置示例**:
```bash
# Mac 的 hosts.conf
HOSTS_workstation-b="bob@workstation-b:22"
HOSTS_workstation_a="alice@workstation-a:22"

# workstation-a 的 hosts.conf
HOSTS_mac="alice@macbook-alice:22"    # 别名根据 hostname 生成
HOSTS_workstation-b="bob@workstation-b:22"

# workstation-b 的 hosts.conf
HOSTS_mac="alice@macbook-alice:22"
HOSTS_workstation_a="alice@workstation-a:22"
```

### 10. Tailscale 连接类型影响延迟

**现象**: `tailscale ping` 显示 workstation-b 通过 relay 连接（~1200ms），workstation-a 为 direct（~2.5ms）。

**说明**:
- relay 连接: 数据经过 Tailscale 中继服务器，延迟较高但可用
- direct 连接: 点对点直连，低延迟
- `tailscale ping -c 3 <host>` 可查看连接类型
- 持续 relay 通常因 NAT 类型限制，一般不影响功能，只影响速度

## 新机器加入检查清单

1. [ ] 安装 Tailscale，加入网络
2. [ ] `tailscale status` 确认所有机器可见
3. [ ] `tailscale ping` 检查连通性和延迟
4. [ ] 安装 openssh-server（如果没有）
5. [ ] 确认本机用户名（可能与其他机器不同）
6. [ ] 从一台已有机器运行 `remote-collab-setup`
7. [ ] 或手动: ssh-copy-id 建立互信、部署脚本、生成 hosts.conf
8. [ ] 安装 Syncthing，使用 Tailscale IP 添加设备
9. [ ] 将新设备加入 MacShare 文件夹
10. [ ] 运行 `remote-collab-doctor` 验证全部通过

## 集成测试结果 (2026-03-25)

- 三机全网格 SSH 互通: 6/6 PASS (Mac↔workstation-a, Mac↔workstation-b, workstation-a↔workstation-b)
- doctor 诊断: Mac 16/16, workstation-a 17/17, workstation-b 17/17 全部 PASS
- 前台命令: PASS
- 后台任务 + bg-list: PASS
- rsync push: PASS
- Syncthing MacShare 三方同步: PASS
- 所有 6 脚本 `bash -n` 语法检查: PASS
