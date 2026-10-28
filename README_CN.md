# openclaw-sync-toolkit

**在多台 Mac + iPhone 之间自动同步 Claude Code / OpenClaw 的 Skills、设置、命令和工作区文件。**

一套经过实战验证的开源工具集，基于 **Git + Syncthing 双通道架构**，实现三端（MacBook Pro + Mac Mini + iPhone）全自动同步。部署一次，后台运行，无需手动操作。

---

## 目录

- [解决什么问题](#解决什么问题)
- [架构概览](#架构概览)
- [功能特性](#功能特性)
- [前置准备](#前置准备)
- [第一步：部署 MacBook Pro](#第一步部署-macbook-pro)
- [第二步：部署 Mac Mini](#第二步部署-mac-mini)
- [第三步：两台 Mac 互相配对](#第三步两台-mac-互相配对)
- [第四步：部署 iPhone](#第四步部署-iphone)
- [验证同步是否正常](#验证同步是否正常)
- [日常使用](#日常使用)
- [命令参考](#命令参考)
- [配置说明](#配置说明)
- [冲突处理](#冲突处理)
- [Telegram 通知配置](#telegram-通知配置)
- [项目结构](#项目结构)
- [常见问题](#常见问题)
- [卸载](#卸载)
- [许可证](#许可证)

---

## 解决什么问题

如果你在多台设备上使用 Claude Code 或 OpenClaw，你可能遇到过这些问题：

| 痛点 | 具体表现 |
|------|---------|
| Skills 不互通 | 在 Mac Mini 上通过 Telegram 让 Agent 学了新 Skill，MacBook Pro 上用不了 |
| 设置漂移 | 两台机器的 Claude Code 设置越用越不一样 |
| 文档不共享 | MacBook Pro 上做的调研报告，Mac Mini 上的 Agent 看不到 |
| 手机是信息孤岛 | 出门在外无法查阅之前的文档和笔记 |
| 手动 Git 靠不住 | 忙着写代码时不会想着 push，Agent 自动生成文件时更不会 |

本工具通过双通道自动同步彻底解决以上所有问题。

---

## 架构概览

```
MacBook Pro                        Mac Mini                         iPhone
+-----------------------+         +-----------------------+         +------------------+
|                       |         |                       |         |                  |
|  ~/.claude/           | Git同步 |  ~/.claude/           |         |                  |
|   ├── skills/        <--------->   ├── skills/          |         |                  |
|   ├── settings.json   | (自动)  |   ├── settings.json   |         |                  |
|   ├── commands/       |         |   ├── commands/       |         |                  |
|   ├── agents/         |         |   ├── agents/         |         |                  |
|   └── plugins/        |         |   └── plugins/        |         |                  |
|                       |         |                       |         |                  |
|  ~/claudecode_        |Syncthing|  ~/claudecode_        |Syncthing|  Obsidian Vault/ |
|    workspace/        <--------->    workspace/         <--------->   (只读同步)      |
|   ├── 项目代码/       | (实时)  |   ├── 项目代码/       | (实时)  |   ├── 项目代码/  |
|   ├── 文档/           |         |   ├── 文档/           |         |   ├── 文档/      |
|   └── 笔记/           |         |   └── 笔记/           |         |   └── 笔记/      |
|                       |         |                       |         |                  |
|  后台服务:            |         |  后台服务:            |         |  App:            |
|   • launchd x3       |         |   • launchd x3       |         |   • Mobius Sync  |
|   • syncthing         |         |   • syncthing         |         |   • Obsidian     |
+-----------------------+         +-----------------------+         +------------------+
```

**双通道分工：**

| 通道 | 同步内容 | 技术方案 | 特点 |
|------|---------|---------|------|
| Git 通道 | Claude Code 配置（Skills、Settings、Commands、Agents、Plugins） | Git push/pull + launchd 定时 + fswatch 实时监控 | 有完整版本历史，可回滚 |
| Syncthing 通道 | 工作区文件（项目代码、文档、笔记） | Syncthing P2P 双向同步 | 亚秒级实时同步，增量传输 |

---

## 功能特性

- **Git 配置同步** — Skills、Settings、Commands、Agents、Plugins 通过 Git 同步，保留完整版本历史
- **实时文件监控** — fswatch 检测配置变更后数秒内自动 push
- **Syncthing P2P 同步** — 工作区文件亚秒级双向同步，P2P 加密，不经第三方服务器
- **iPhone 只读同步** — 通过 Mobius Sync + Obsidian 在手机上随时查阅所有文档
- **冲突解决** — Keep-Local / Keep-Remote / Manual 三种策略，冲突自动备份为 `.conflict` 文件
- **版本回滚** — 一条命令将任何配置回滚到任意历史版本
- **部署管理** — 跟踪长期运行服务的状态，代码更新时可选自动重启
- **Telegram 通知** — push / pull / 冲突 / 错误时通过 Telegram 实时通知
- **launchd 后台服务** — 三个常驻服务，开机自启动，崩溃自恢复
- **日志轮转** — 10MB 自动轮转，保留 10 个归档

---

## 前置准备

在开始之前，请确保以下条件满足：

### 所有 Mac 上都需要

- [x] macOS 12 Monterey 或更高版本
- [x] [Homebrew](https://brew.sh) 已安装
- [x] Git 已安装（macOS 自带或通过 Homebrew 安装）
- [x] Claude Code 已安装并正常使用

### GitHub 上需要创建

- [x] **一个私有仓库**用于存储 Claude Code 配置（如 `claude-config-sync`）
- [x] 两台 Mac 都能通过 SSH 访问该仓库

### iPhone 上需要（如需手机同步）

- [x] [Mobius Sync](https://apps.apple.com/app/mobius-sync/id1539203216)（App Store，Syncthing 的 iOS 客户端）
- [x] [Obsidian](https://apps.apple.com/app/obsidian-connected-notes/id1557175442)（App Store，Markdown 阅读器）

### 创建 GitHub 私有仓库

如果还没有配置同步仓库，先创建一个：

```bash
# 方式一：命令行创建（需要安装 gh）
gh repo create claude-config-sync --private

# 方式二：在 GitHub 网页上创建
# 访问 https://github.com/new
# Repository name: claude-config-sync
# Visibility: Private
# 点击 Create repository
```

### 确认 SSH 访问

两台 Mac 都需要能通过 SSH 访问 GitHub：

```bash
# 测试 SSH 连接
ssh -T git@github.com

# 如果提示 "Hi xxx! You've successfully authenticated" 就没问题
# 如果失败，需要先配置 SSH key:
# https://docs.github.com/en/authentication/connecting-to-github-with-ssh
```

---

## 第一步：部署 MacBook Pro

> 以 MacBook Pro 为例作为第一台机器。如果你的主力机不是 MacBook Pro，操作完全一样，只需改 `--name` 参数。

### 1.1 克隆本工具

```bash
git clone https://github.com/antonailog/openclaw-sync-toolkit.git ~/openclaw-sync-toolkit
```

### 1.2 运行部署脚本

```bash
bash ~/openclaw-sync-toolkit/scripts/setup.sh \
  --name macbook-pro \
  --remote git@github.com:你的用户名/claude-config-sync.git
```

> 如果不想安装 Syncthing（只需要配置同步，不需要工作区同步），加 `--no-syncthing` 参数。

脚本会自动完成 6 个步骤：

```
Phase 1/6: 检查并安装依赖（fswatch、jq、syncthing）
Phase 2/6: 克隆配置仓库到 ~/.claude-sync/repo/
Phase 3/6: 部署同步脚本到 ~/.claude-sync/scripts/
Phase 4/6: 首次拉取远程配置到 ~/.claude/
Phase 5/6: 安装 3 个 launchd 后台服务
Phase 6/6: 启动 Syncthing 并输出设备 ID
```

### 1.3 记录 Syncthing 设备 ID

脚本结束时会输出类似这样的内容：

```
================================================
This machine's Syncthing Device ID:
XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX
================================================

Share this device ID with your partner machine to complete pairing.
```

**请复制并保存这个设备 ID**，下一步在 Mac Mini 上需要用到。

如果错过了，随时可以通过以下命令重新获取：

```bash
syncthing --device-id
```

---

## 第二步：部署 Mac Mini

### 2.1 在 Mac Mini 上克隆工具

```bash
git clone https://github.com/antonailog/openclaw-sync-toolkit.git ~/openclaw-sync-toolkit
```

### 2.2 运行部署脚本（带 MacBook Pro 的设备 ID）

```bash
bash ~/openclaw-sync-toolkit/scripts/setup.sh \
  --name mac-mini \
  --remote git@github.com:你的用户名/claude-config-sync.git \
  --partner-device "MacBookPro的Syncthing设备ID"
```

> `--partner-device` 参数会自动在 Syncthing 中添加 MacBook Pro 作为配对设备，并创建 `claudecode-workspace` 共享文件夹。

### 2.3 记录 Mac Mini 的设备 ID

同样，脚本结束时会输出 Mac Mini 的 Syncthing 设备 ID，保存下来。

---

## 第三步：两台 Mac 互相配对

Syncthing 需要**双向确认**才能建立连接。第二步已经让 Mac Mini 认识了 MacBook Pro，现在需要反过来。

### 3.1 在 MacBook Pro 上添加 Mac Mini

打开 Syncthing Web UI：

```bash
open http://127.0.0.1:8384
```

1. 点击右下角 **"+ Add Remote Device"**
2. 粘贴 Mac Mini 的设备 ID
3. 设备名称填 `mac-mini`（方便识别）
4. 点击 **Save**

### 3.2 共享工作区文件夹

在 Syncthing Web UI 中：

1. 点击 **"+ Add Folder"**
2. 填写以下信息：
   - **Folder Label**: `Claude Code Workspace`
   - **Folder ID**: `claudecode-workspace`（必须和 Mac Mini 端一致）
   - **Folder Path**: `~/claudecode_workspace`（你的工作区目录）
3. 切换到 **Sharing** 标签页，勾选 `mac-mini`
4. 点击 **Save**

### 3.3 等待同步完成

两台设备配对后，Syncthing 会自动开始同步。首次同步可能需要几分钟（取决于文件数量和大小）。

在 Syncthing Web UI 中看到文件夹状态变为 **"Up to Date"** 表示同步完成。

---

## 第四步：部署 iPhone

iOS 上没有官方 Syncthing 客户端，但 **Mobius Sync** 完全兼容 Syncthing 协议。搭配 Obsidian 阅读 Markdown 文件，形成完整的移动端方案。

### 4.1 安装 App

在 App Store 安装两个应用：

- **Mobius Sync**（免费版有限制，完整版需付费，建议购买）
- **Obsidian**（免费）

### 4.2 配置 Obsidian

1. 打开 Obsidian，选择 **"Create new vault"**
2. Vault 名称随意（如 `Workspace`）
3. 存储位置选择 **"On My iPhone"**（重要：不要选 iCloud）
4. 创建完成后先退出 Obsidian

### 4.3 配置 Mobius Sync

1. 打开 Mobius Sync

2. **添加 Mac Mini 设备**：
   - 点击 **"Devices"** → **"+"**
   - 粘贴 Mac Mini 的 Syncthing 设备 ID
   - 设备名称填 `mac-mini`
   - 点击 **Save**

3. **创建共享文件夹**（重要：从 iPhone 端创建，不要等 Mac 端推送邀请）：
   - 点击 **"Folders"** → **"+"**
   - **Folder ID** 填 `claudecode-workspace`（必须和 Mac 端完全一致）
   - **Folder Label** 填 `Claude Code Workspace`
   - 点击 **"Pick External Folder"**，选择 Obsidian Vault 目录（通常在 `On My iPhone` → `Obsidian` → `Workspace`）
   - 在 **Sharing** 中勾选 `mac-mini`
   - 点击 **Save**

> **踩坑提醒**：最开始我试着从 Mac Mini 端发共享邀请给 iPhone，结果 Mobius Sync 死活收不到推送通知。最后改为从 iPhone 端主动创建文件夹（填入相同的 Folder ID），立刻就能连上了。**建议一律从 iPhone 端主动创建。**

### 4.4 在 Mac Mini 端确认 iPhone 设备

回到 Mac Mini 的 Syncthing Web UI（`http://127.0.0.1:8384`）：

1. 应该能看到 iPhone 发来的连接请求，点击 **Accept**
2. 同时会收到共享文件夹的请求，点击 **Accept**，确认 Folder Path 指向 `~/claudecode_workspace`

### 4.5 等待首次同步

Mobius Sync 会开始同步文件。首次同步取决于文件数量，进度可在 Mobius Sync 的 Folders 页面查看。

同步完成后：

1. 打开 Obsidian
2. 选择之前创建的 Vault
3. 你应该能看到和电脑上完全一致的目录结构和文件

### 4.6 可选：添加 MacBook Pro 作为直连设备

为了在两台 Mac 和 iPhone 之间形成完整的 P2P 网络（任意两台设备都能直接同步），可以在 Mobius Sync 中也添加 MacBook Pro 的设备 ID。步骤同 4.3，换成 MacBook Pro 的设备 ID 即可。

---

## 验证同步是否正常

完成以上所有步骤后，建议做以下验证：

### 验证 Git 配置同步

```bash
# 在 MacBook Pro 上检查同步状态
~/.claude-sync/scripts/sync.sh status

# 手动触发一次 push
~/.claude-sync/scripts/sync.sh push

# 在 Mac Mini 上手动触发一次 pull
~/.claude-sync/scripts/sync.sh pull

# 确认两台机器的 skills 目录内容一致
ls ~/.claude/skills/
```

### 验证 Syncthing 工作区同步

```bash
# 在 MacBook Pro 上创建一个测试文件
echo "sync test $(date)" > ~/claudecode_workspace/sync-test.txt

# 等待几秒后，在 Mac Mini 上检查
cat ~/claudecode_workspace/sync-test.txt

# 测试完成后删除
rm ~/claudecode_workspace/sync-test.txt
```

### 验证 iPhone 同步

1. 在 MacBook Pro 上创建 `~/claudecode_workspace/phone-test.md`，内容随意
2. 打开 iPhone 的 Obsidian，等待 Mobius Sync 同步（可能需要打开 Mobius Sync App 触发一下）
3. 在 Obsidian 中搜索 `phone-test`，应该能看到文件
4. 测试完成后删除

### 验证 launchd 后台服务

```bash
# 查看三个后台服务是否正在运行
launchctl list | grep claude-sync

# 应该看到三行，退出码为 0 表示正常：
# -   0   com.claude-sync.pull
# PID 0   com.claude-sync.watch
# PID 0   com.claude-sync.workspace
```

---

## 日常使用

部署完成后，**日常不需要任何手动操作**。以下是自动运行的机制：

| 场景 | 发生了什么 | 你需要做什么 |
|------|-----------|-------------|
| 在 MacBook Pro 上新建 Skill | fswatch 检测到变更 → 5 秒防抖 → 自动 git push → Mac Mini 5 分钟内 pull | 什么都不用做 |
| 在 Mac Mini 上通过 Telegram 让 Agent 生成文件 | Syncthing 自动同步到 MacBook Pro | 什么都不用做 |
| 在 MacBook Pro 上修改工作区文件 | Syncthing 亚秒级同步到 Mac Mini | 什么都不用做 |
| 出门在外想看文档 | 打开 iPhone Obsidian | 如果文件没出现，打开一下 Mobius Sync 触发同步 |
| 两台机器同时改了同一个配置文件 | 自动保留本地版本，远程版本备份为 .conflict | 收到通知后手动 resolve（极少发生） |

### 常用操作命令

```bash
# 查看同步状态
~/.claude-sync/scripts/sync.sh status

# 手动推送（通常不需要，自动会做）
~/.claude-sync/scripts/sync.sh push

# 手动拉取
~/.claude-sync/scripts/sync.sh pull

# 查看同步日志
~/.claude-sync/scripts/sync.sh log

# 查看某个 Skill 的变更历史
~/.claude-sync/scripts/sync.sh log skills/my-skill.md

# 暂停自动同步
launchctl unload ~/Library/LaunchAgents/com.claude-sync.*.plist

# 恢复自动同步
launchctl load ~/Library/LaunchAgents/com.claude-sync.*.plist
```

---

## 命令参考

### sync.sh — 核心同步

```bash
sync.sh init                     # 初始化同步系统
sync.sh push                     # 推送本地配置到远程
sync.sh pull                     # 拉取远程配置到本地
sync.sh status                   # 查看同步状态
sync.sh log [文件名]              # 查看同步日志或指定文件的变更历史
sync.sh rollback <文件> <commit>  # 回滚文件到指定版本
sync.sh resolve <文件> [策略]     # 解决冲突（--keep-local / --keep-remote / --manual）
```

### deploy.sh — 部署管理

```bash
deploy.sh start <目录> [选项]     # 启动并跟踪一个长期运行的项目
deploy.sh stop <目录>             # 停止项目
deploy.sh status [目录]           # 查看部署状态
deploy.sh update <目录>           # 更新已部署的项目（拉取最新代码并重启）
deploy.sh check <目录>            # 检查是否有可用更新
```

### monitor.sh — 文件监控

```bash
monitor.sh watch                 # 监控 ~/.claude/ 配置变更，自动 push
monitor.sh pull                  # 一次性 pull 检查
monitor.sh workspace             # 监控工作区部署状态
```

### notify.sh — Telegram 通知

```bash
notify.sh sync_push "消息"        # 发送推送通知
notify.sh conflict "消息"         # 发送冲突告警
notify.sh error "消息"            # 发送错误告警
```

---

## 配置说明

### sync-config.json

部署后生成在 `~/.claude-sync/sync-config.json`，每台机器独立：

```json
{
  "machine_name": "macbook-pro",
  "git": {
    "remote": "git@github.com:user/claude-config-sync.git"
  },
  "sync_sources": {
    "skills": "~/.claude/skills",
    "settings": "~/.claude/settings.json",
    "commands": "~/.claude/commands",
    "agents": "~/.claude/agents",
    "plugins": "~/.claude/plugins"
  },
  "log": {
    "max_size_mb": 10,
    "max_archives": 10
  },
  "telegram": {
    "enabled": false,
    "bot_token": "",
    "chat_id": ""
  },
  "auto_sync": {
    "pull_interval_minutes": 5,
    "watch_enabled": true
  }
}
```

### .syncignore

控制哪些文件不参与配置同步（glob 语法），位于 `~/.claude-sync/.syncignore`：

```
# 机器专属设置，不同步
settings.local.json

# 敏感文件
.env
.env.*
*.key
*.pem
credentials.json

# Claude Code 运行时数据
cache/
debug/
history.jsonl
todos/
transcripts/
plans/
tasks/
teams/

# 构建产物
node_modules/
__pycache__/

# 编辑器临时文件
*.swp
*.swo
.DS_Store
```

### Syncthing .stignore

工作区同步时排除的文件，在 Syncthing Web UI 或直接编辑 `~/claudecode_workspace/.stignore`：

```
// 版本控制
.git

// 构建产物
node_modules
__pycache__
.venv
dist
build

// 运行时数据
*.log
*.pid

// macOS 系统文件
.DS_Store
.Spotlight-V100
.Trashes
```

---

## 冲突处理

当两台机器同时修改了同一个配置文件时：

1. **检测**：`sync.sh pull` 时 Git 检测到合并冲突
2. **自动处理**：保留本地版本，远程版本保存为 `<文件名>.conflict`
3. **通知**：通过 Telegram（如已配置）发送告警
4. **手动解决**：

```bash
# 查看有哪些冲突文件
ls ~/.claude/skills/*.conflict

# 保留本地版本（删除 .conflict 文件）
~/.claude-sync/scripts/sync.sh resolve skills/my-skill.md --keep-local

# 使用远程版本（用 .conflict 覆盖本地）
~/.claude-sync/scripts/sync.sh resolve skills/my-skill.md --keep-remote

# 手动对比合并
~/.claude-sync/scripts/sync.sh resolve skills/my-skill.md --manual
```

> 实际使用中冲突极少发生。两台机器通常各有分工（一台开发，一台跑 Agent），很少同时改同一个文件。

---

## Telegram 通知配置

通过 Telegram Bot 接收同步状态通知（可选）。

### 创建 Bot

1. 在 Telegram 中搜索 **@BotFather**
2. 发送 `/newbot`，按提示设置名称
3. 获得 **Bot Token**（格式类似 `123456:ABC-DEF...`）

### 获取 Chat ID

1. 向你的新 Bot 发送一条消息
2. 访问 `https://api.telegram.org/bot<你的Token>/getUpdates`
3. 在返回的 JSON 中找到 `chat.id`

### 配置

编辑每台机器上的 `~/.claude-sync/sync-config.json`：

```json
{
  "telegram": {
    "enabled": true,
    "bot_token": "123456:ABC-DEF...",
    "chat_id": "你的Chat ID"
  }
}
```

配置后会收到以下通知：

| 类型 | 场景 | 消息格式 |
|------|------|---------|
| `sync_push` | 推送完成 | `[PUSH] [macbook-pro] Pushed 3 files` |
| `sync_pull` | 拉取完成 | `[PULL] [mac-mini] Pulled 2 files` |
| `conflict` | 检测到冲突 | `[CONFLICT] [mac-mini] skills/xxx.md needs review` |
| `error` | 同步失败 | `[ERROR] [macbook-pro] Remote repository unreachable` |
| `deploy` | 部署相关 | `[DEPLOY] [mac-mini] Project my-bot has new code` |

---

## 项目结构

```
openclaw-sync-toolkit/
├── README.md                  # English README
├── README_CN.md               # 本文件
├── LICENSE                    # MIT
├── .gitignore
├── scripts/
│   ├── sync.sh                # 核心同步引擎（push/pull/status/rollback/resolve）
│   ├── setup.sh               # 一键部署脚本（6 步自动化）
│   ├── deploy.sh              # 部署管理（服务启停、更新、状态跟踪）
│   ├── monitor.sh             # 文件变更监控（watch/pull/workspace 三模式）
│   ├── install.sh             # 依赖安装
│   └── notify.sh              # Telegram 通知
├── config/
│   ├── sync-config.template.json   # 配置文件模板
│   ├── .syncignore                 # 同步忽略规则
│   └── launchd/                    # macOS 后台服务模板
│       ├── com.claude-sync.pull.plist       # 定时拉取（每 5 分钟）
│       ├── com.claude-sync.watch.plist      # 实时监控（常驻）
│       └── com.claude-sync.workspace.plist  # 工作区监控（常驻）
└── docs/
    └── ARCHITECTURE.md        # 详细架构设计文档
```

### 部署后的本地目录结构

```
~/.claude-sync/                # 同步系统根目录
├── repo/                      # 配置同步的 Git 本地仓库
├── scripts/                   # 部署后的脚本副本
│   ├── sync.sh
│   ├── deploy.sh
│   ├── monitor.sh
│   └── notify.sh
├── config/                    # 配置和模板
├── sync-config.json           # 本机配置
├── .syncignore                # 忽略规则
├── sync.log                   # 同步日志
├── conflict.log               # 冲突日志
├── pids/                      # 进程 PID 文件
└── logs/                      # launchd 输出日志

~/Library/LaunchAgents/        # macOS 后台服务
├── com.claude-sync.pull.plist
├── com.claude-sync.watch.plist
└── com.claude-sync.workspace.plist
```

---

## 常见问题

**Q: 部署后 skills 没有同步过来？**

首先确认配置仓库中有内容：

```bash
cd ~/.claude-sync/repo && git log --oneline -5
```

如果仓库是空的，说明还没有任何一台机器 push 过。在有 skills 的机器上手动 push 一次：

```bash
~/.claude-sync/scripts/sync.sh push
```

---

**Q: Syncthing 两台设备一直显示 "Disconnected"？**

检查要点：
1. 两台设备是否在同一局域网（或者能互相访问）
2. 是否双向添加了设备 ID（A 添加了 B，B 也添加了 A）
3. macOS 防火墙是否阻止了 Syncthing（系统偏好设置 → 安全性与隐私 → 防火墙）
4. 尝试重启 Syncthing：`brew services restart syncthing`

---

**Q: iPhone 上 Mobius Sync 不同步？**

常见原因：
1. **后台被杀**：iOS 会积极终止后台应用。打开 Mobius Sync 让它在前台运行一会儿
2. **Folder ID 不一致**：确认 iPhone 上的 Folder ID 和 Mac 端完全一致（`claudecode-workspace`）
3. **Mac 端未接受**：检查 Mac 的 Syncthing Web UI 是否有待确认的设备或文件夹请求

---

**Q: `settings.local.json` 是什么？**

机器专属设置，永远不会被同步。适合存放：
- MCP 服务器路径（每台机器路径不同）
- 本地环境变量
- 硬件相关配置

`settings.local.json` 中的配置会覆盖 `settings.json` 中的同名项。

---

**Q: 如何回滚一个错误的 Skill？**

```bash
# 查看这个 skill 的变更历史
~/.claude-sync/scripts/sync.sh log skills/my-skill.md

# 回滚到指定版本
~/.claude-sync/scripts/sync.sh rollback skills/my-skill.md abc1234
```

---

**Q: sync.sh push 很慢？**

已内置性能优化。如果遇到超过 5 秒的情况，检查：
1. 是否有大量文件需要同步（正常 960 个文件约 2 秒）
2. 网络连接是否正常（push 需要访问 GitHub）
3. `.syncignore` 是否正确配置（避免同步 node_modules 等大目录）

---

**Q: 两台 Mac 可以改为其他设备吗？**

本工具针对 macOS 优化（launchd、brew、fswatch）。理论上 Linux 也能跑（需要将 launchd 替换为 systemd），但未经测试。

---

## 卸载

如果需要完全卸载同步系统：

```bash
# 1. 停止并移除 launchd 服务
launchctl unload ~/Library/LaunchAgents/com.claude-sync.*.plist
rm ~/Library/LaunchAgents/com.claude-sync.*.plist

# 2. 停止 Syncthing（如果不再需要）
brew services stop syncthing

# 3. 删除同步系统目录
rm -rf ~/.claude-sync

# 4. 删除工具仓库（可选）
rm -rf ~/openclaw-sync-toolkit
```

> 卸载不会影响 `~/.claude/` 中已同步的文件，它们会保留在原位。

---

## 贡献

欢迎贡献！请随时提交 Issue 和 Pull Request。

如果你有任何问题或建议，欢迎在 [Issues](https://github.com/antonailog/openclaw-sync-toolkit/issues) 中讨论。

## 许可证

[MIT](LICENSE)
