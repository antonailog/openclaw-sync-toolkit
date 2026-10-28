# openclaw-sync-toolkit

**Sync your Claude Code / OpenClaw skills, settings, commands, and workspace files across multiple Macs + iPhone — automatically.**

A battle-tested, open-source toolkit using a **Git + Syncthing dual-channel architecture** to keep three devices (MacBook Pro + Mac Mini + iPhone) in perfect sync. Deploy once, runs in the background, zero manual effort.

[中文文档](README_CN.md)

---

## Table of Contents

- [What Problem Does This Solve](#what-problem-does-this-solve)
- [Architecture](#architecture)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Step 1: Deploy MacBook Pro](#step-1-deploy-macbook-pro)
- [Step 2: Deploy Mac Mini](#step-2-deploy-mac-mini)
- [Step 3: Pair the Two Macs](#step-3-pair-the-two-macs)
- [Step 4: Deploy iPhone](#step-4-deploy-iphone)
- [Verify Everything Works](#verify-everything-works)
- [Daily Usage](#daily-usage)
- [Command Reference](#command-reference)
- [Configuration](#configuration)
- [Conflict Handling](#conflict-handling)
- [Telegram Notifications](#telegram-notifications)
- [Project Structure](#project-structure)
- [FAQ](#faq)
- [Uninstall](#uninstall)
- [License](#license)

---

## What Problem Does This Solve

If you use Claude Code or OpenClaw on multiple devices, you've probably hit these problems:

| Pain Point | What Happens |
|-----------|-------------|
| Skills don't transfer | A Skill learned on Mac Mini via Telegram isn't available on MacBook Pro |
| Settings drift | Claude Code configs diverge across machines over time |
| Docs aren't shared | Research reports on MacBook Pro are invisible to Mac Mini's Agent |
| Phone is an island | Can't check any docs or notes when you're away from your computer |
| Manual Git is unreliable | You won't remember to push when you're busy coding; Agents never will |

This toolkit solves all of the above with automatic dual-channel sync.

---

## Architecture

```
MacBook Pro                        Mac Mini                         iPhone
+-----------------------+         +-----------------------+         +------------------+
|                       |         |                       |         |                  |
|  ~/.claude/           | Git     |  ~/.claude/           |         |                  |
|   ├── skills/        <--------->   ├── skills/          |         |                  |
|   ├── settings.json   | (auto)  |   ├── settings.json   |         |                  |
|   ├── commands/       |         |   ├── commands/       |         |                  |
|   ├── agents/         |         |   ├── agents/         |         |                  |
|   └── plugins/        |         |   └── plugins/        |         |                  |
|                       |         |                       |         |                  |
|  ~/claudecode_        |Syncthing|  ~/claudecode_        |Syncthing|  Obsidian Vault/ |
|    workspace/        <--------->    workspace/         <--------->   (read-only)     |
|   ├── projects/       | (live)  |   ├── projects/       | (live)  |   ├── projects/  |
|   ├── docs/           |         |   ├── docs/           |         |   ├── docs/      |
|   └── notes/          |         |   └── notes/          |         |   └── notes/     |
|                       |         |                       |         |                  |
|  Background:          |         |  Background:          |         |  Apps:           |
|   • launchd x3       |         |   • launchd x3       |         |   • Mobius Sync  |
|   • syncthing         |         |   • syncthing         |         |   • Obsidian     |
+-----------------------+         +-----------------------+         +------------------+
```

**Dual-channel design:**

| Channel | What It Syncs | Technology | Strengths |
|---------|--------------|-----------|-----------|
| Git channel | Claude Code configs (Skills, Settings, Commands, Agents, Plugins) | Git push/pull + launchd timer + fswatch realtime | Full version history, rollback support |
| Syncthing channel | Workspace files (code, docs, notes) | Syncthing P2P bidirectional | Sub-second realtime sync, incremental transfer |

---

## Features

- **Git config sync** — Skills, Settings, Commands, Agents, Plugins synced via Git with full version history
- **Real-time file watching** — fswatch detects config changes, auto-pushes within seconds
- **Syncthing P2P sync** — Workspace files sync in real-time, peer-to-peer encrypted, no third-party servers
- **iPhone read-only sync** — Browse all docs on your phone via Mobius Sync + Obsidian
- **Conflict resolution** — Keep-Local / Keep-Remote / Manual strategies with `.conflict` backup files
- **Version rollback** — Roll back any config file to any previous version with one command
- **Deployment manager** — Track long-running services, optionally auto-restart on code changes
- **Telegram notifications** — Get notified on push, pull, conflicts, and errors
- **launchd background services** — Three persistent services that auto-start on boot and self-heal on crash
- **Log rotation** — 10MB rotation with 10 archive retention

---

## Prerequisites

### On Every Mac

- [x] macOS 12 Monterey or later
- [x] [Homebrew](https://brew.sh) installed
- [x] Git installed (comes with macOS or via Homebrew)
- [x] Claude Code installed and working

### On GitHub

- [x] A **private repository** for storing Claude Code configs (e.g., `claude-config-sync`)
- [x] Both Macs can access it via SSH

### On iPhone (if you want mobile sync)

- [x] [Mobius Sync](https://apps.apple.com/app/mobius-sync/id1539203216) (Syncthing iOS client)
- [x] [Obsidian](https://apps.apple.com/app/obsidian-connected-notes/id1557175442) (Markdown reader)

### Create the GitHub Repo

```bash
# Option A: CLI (requires gh)
gh repo create claude-config-sync --private

# Option B: Create at https://github.com/new
# Name: claude-config-sync, Visibility: Private
```

### Verify SSH Access

```bash
ssh -T git@github.com
# Should print: "Hi xxx! You've successfully authenticated"
```

---

## Step 1: Deploy MacBook Pro

### 1.1 Clone This Toolkit

```bash
git clone https://github.com/antonailog/openclaw-sync-toolkit.git ~/openclaw-sync-toolkit
```

### 1.2 Run Setup

```bash
bash ~/openclaw-sync-toolkit/scripts/setup.sh \
  --name macbook-pro \
  --remote git@github.com:YOUR_USER/claude-config-sync.git
```

The script runs 6 phases automatically:

```
Phase 1/6: Install dependencies (fswatch, jq, syncthing)
Phase 2/6: Clone config repo to ~/.claude-sync/repo/
Phase 3/6: Deploy sync scripts to ~/.claude-sync/scripts/
Phase 4/6: Initial pull of remote config to ~/.claude/
Phase 5/6: Install 3 launchd background services
Phase 6/6: Start Syncthing and print device ID
```

### 1.3 Save the Syncthing Device ID

The script prints your device ID at the end — **copy and save it** for the next step.

```bash
# To retrieve it later:
syncthing --device-id
```

---

## Step 2: Deploy Mac Mini

### 2.1 Clone on Mac Mini

```bash
git clone https://github.com/antonailog/openclaw-sync-toolkit.git ~/openclaw-sync-toolkit
```

### 2.2 Run Setup with Partner Device ID

```bash
bash ~/openclaw-sync-toolkit/scripts/setup.sh \
  --name mac-mini \
  --remote git@github.com:YOUR_USER/claude-config-sync.git \
  --partner-device "MACBOOK_PRO_SYNCTHING_DEVICE_ID"
```

### 2.3 Save Mac Mini's Device ID

The script prints Mac Mini's device ID — save it too.

---

## Step 3: Pair the Two Macs

Syncthing requires **bidirectional confirmation**. Step 2 made Mac Mini aware of MacBook Pro. Now do the reverse.

### 3.1 Add Mac Mini on MacBook Pro

Open Syncthing Web UI:

```bash
open http://127.0.0.1:8384
```

1. Click **"+ Add Remote Device"** (bottom right)
2. Paste Mac Mini's device ID
3. Name: `mac-mini`
4. Click **Save**

### 3.2 Share the Workspace Folder

In the Syncthing Web UI:

1. Click **"+ Add Folder"**
2. Fill in:
   - **Folder Label**: `Claude Code Workspace`
   - **Folder ID**: `claudecode-workspace` (must match Mac Mini)
   - **Folder Path**: `~/claudecode_workspace`
3. Go to **Sharing** tab, check `mac-mini`
4. Click **Save**

### 3.3 Wait for Sync

When the folder status shows **"Up to Date"** in the Web UI, sync is complete.

---

## Step 4: Deploy iPhone

### 4.1 Install Apps

From the App Store:
- **Mobius Sync** (Syncthing iOS client)
- **Obsidian** (Markdown reader)

### 4.2 Set Up Obsidian

1. Open Obsidian → **"Create new vault"**
2. Name it anything (e.g., `Workspace`)
3. Storage: **"On My iPhone"** (important: NOT iCloud)
4. Exit Obsidian for now

### 4.3 Set Up Mobius Sync

1. Open Mobius Sync

2. **Add Mac Mini as a device:**
   - Devices → **"+"**
   - Paste Mac Mini's Syncthing device ID
   - Name: `mac-mini`
   - Save

3. **Create the shared folder** (important: create FROM iPhone, don't wait for Mac's invitation):
   - Folders → **"+"**
   - **Folder ID**: `claudecode-workspace` (must match exactly)
   - **Folder Label**: `Claude Code Workspace`
   - Tap **"Pick External Folder"** → navigate to `On My iPhone` → `Obsidian` → `Workspace`
   - In **Sharing**, check `mac-mini`
   - Save

> **Tip:** Don't try to send a share invitation from Mac to iPhone — Mobius Sync's iOS push notifications are unreliable. Always create the folder from the iPhone side with the matching Folder ID. It connects instantly.

### 4.4 Accept on Mac Mini

In Mac Mini's Syncthing Web UI (`http://127.0.0.1:8384`):
1. Accept the incoming device request from iPhone
2. Accept the shared folder request, confirm path is `~/claudecode_workspace`

### 4.5 Wait for Initial Sync

Once complete, open Obsidian on iPhone — you should see the full directory structure matching your Mac.

### 4.6 Optional: Add MacBook Pro as Direct Peer

For a complete P2P mesh (any two devices can sync directly), also add MacBook Pro's device ID in Mobius Sync.

---

## Verify Everything Works

### Git Config Sync

```bash
# Check status on MacBook Pro
~/.claude-sync/scripts/sync.sh status

# Manual push
~/.claude-sync/scripts/sync.sh push

# Manual pull on Mac Mini
~/.claude-sync/scripts/sync.sh pull

# Confirm skills match
ls ~/.claude/skills/
```

### Syncthing Workspace Sync

```bash
# Create test file on MacBook Pro
echo "sync test $(date)" > ~/claudecode_workspace/sync-test.txt

# Check on Mac Mini after a few seconds
cat ~/claudecode_workspace/sync-test.txt

# Clean up
rm ~/claudecode_workspace/sync-test.txt
```

### iPhone Sync

1. Create a test `.md` file in `~/claudecode_workspace/`
2. Open Mobius Sync on iPhone to trigger sync
3. Open Obsidian and search for the file
4. Clean up after verification

### launchd Services

```bash
launchctl list | grep claude-sync
# Expect 3 entries with exit code 0
```

---

## Daily Usage

After deployment, **no manual action is needed**. Everything runs automatically:

| Scenario | What Happens | Your Action |
|----------|-------------|-------------|
| Create a new Skill on MacBook Pro | fswatch detects → 5s debounce → auto git push → Mac Mini pulls within 5 min | Nothing |
| Agent generates files on Mac Mini | Syncthing syncs to MacBook Pro in sub-seconds | Nothing |
| Edit workspace files | Syncthing syncs across all devices | Nothing |
| Want to read docs on phone | Open Obsidian on iPhone | Open Mobius Sync briefly if files don't appear |
| Both machines edit same config | Local kept, remote saved as `.conflict` | Resolve when notified (rare) |

---

## Command Reference

### sync.sh

```bash
sync.sh init                     # Initialize sync system
sync.sh push                     # Push local config to remote
sync.sh pull                     # Pull remote config to local
sync.sh status                   # View sync status
sync.sh log [filename]           # View sync log or file history
sync.sh rollback <file> <commit> # Rollback file to specific version
sync.sh resolve <file> [strategy] # Resolve conflict
```

### deploy.sh

```bash
deploy.sh start <dir> [options]  # Start and track a project
deploy.sh stop <dir>             # Stop a project
deploy.sh status [dir]           # View deployment status
deploy.sh update <dir>           # Update deployed project
deploy.sh check <dir>            # Check for available updates
```

### monitor.sh

```bash
monitor.sh watch                 # Watch config changes, auto-push
monitor.sh pull                  # One-time pull check
monitor.sh workspace             # Watch workspace, auto-deploy
```

### notify.sh

```bash
notify.sh sync_push "message"    # Push notification
notify.sh conflict "message"     # Conflict alert
notify.sh error "message"        # Error alert
```

---

## Configuration

### sync-config.json

Generated per machine at `~/.claude-sync/sync-config.json`:

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

Controls which files are excluded from config sync (glob syntax). Located at `~/.claude-sync/.syncignore`.

### Syncthing .stignore

Controls workspace sync exclusions. Edit via Syncthing Web UI or directly at `~/claudecode_workspace/.stignore`.

---

## Conflict Handling

When two machines modify the same config file:

1. **Detection**: Git detects merge conflict during pull
2. **Auto-handling**: Local version kept, remote saved as `<file>.conflict`
3. **Notification**: Telegram alert (if configured)
4. **Resolution**:

```bash
# Keep local version
sync.sh resolve skills/my-skill.md --keep-local

# Accept remote version
sync.sh resolve skills/my-skill.md --keep-remote

# Manual merge
sync.sh resolve skills/my-skill.md --manual
```

---

## Telegram Notifications

### Create a Bot

1. Message **@BotFather** on Telegram
2. Send `/newbot`, follow prompts
3. Save the **Bot Token**

### Get Your Chat ID

1. Send a message to your bot
2. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates`
3. Find `chat.id` in the response

### Configure

Edit `~/.claude-sync/sync-config.json`:

```json
{
  "telegram": {
    "enabled": true,
    "bot_token": "123456:ABC-DEF...",
    "chat_id": "YOUR_CHAT_ID"
  }
}
```

---

## Project Structure

```
openclaw-sync-toolkit/
├── README.md                  # This file
├── README_CN.md               # Chinese README
├── LICENSE                    # MIT
├── scripts/
│   ├── sync.sh                # Core sync engine
│   ├── setup.sh               # One-click deployment (6 phases)
│   ├── deploy.sh              # Deployment manager
│   ├── monitor.sh             # File change watcher
│   ├── install.sh             # Dependency installer
│   └── notify.sh              # Telegram notifications
├── config/
│   ├── sync-config.template.json
│   ├── .syncignore
│   └── launchd/
│       ├── com.claude-sync.pull.plist       # Periodic pull (every 5 min)
│       ├── com.claude-sync.watch.plist      # Realtime config watcher
│       └── com.claude-sync.workspace.plist  # Workspace monitor
└── docs/
    └── ARCHITECTURE.md        # Detailed architecture document
```

---

## FAQ

**Q: Skills didn't sync after deployment?**

Check if the config repo has any commits: `cd ~/.claude-sync/repo && git log --oneline -5`. If empty, manually push from the machine that has skills: `~/.claude-sync/scripts/sync.sh push`.

**Q: Syncthing devices show "Disconnected"?**

Check: (1) Both on same network or reachable, (2) device IDs added bidirectionally, (3) macOS firewall isn't blocking Syncthing, (4) try `brew services restart syncthing`.

**Q: iPhone Mobius Sync isn't syncing?**

Common causes: (1) iOS killed background app — open Mobius Sync to foreground, (2) Folder ID mismatch — must be exactly `claudecode-workspace`, (3) Mac hasn't accepted the device/folder request.

**Q: What is `settings.local.json`?**

Machine-specific settings that are never synced. Use for MCP server paths, local env configs, hardware-specific settings. Values override `settings.json`.

**Q: How to rollback a bad Skill change?**

```bash
~/.claude-sync/scripts/sync.sh log skills/my-skill.md  # Find commit
~/.claude-sync/scripts/sync.sh rollback skills/my-skill.md abc1234
```

**Q: Can I use this on Linux?**

The toolkit is macOS-optimized (launchd, brew, fswatch). Linux would need launchd replaced with systemd — not tested but theoretically possible.

---

## Uninstall

```bash
# 1. Remove launchd services
launchctl unload ~/Library/LaunchAgents/com.claude-sync.*.plist
rm ~/Library/LaunchAgents/com.claude-sync.*.plist

# 2. Stop Syncthing (if no longer needed)
brew services stop syncthing

# 3. Remove sync system
rm -rf ~/.claude-sync

# 4. Remove toolkit (optional)
rm -rf ~/openclaw-sync-toolkit
```

> Uninstalling does not affect files already synced to `~/.claude/` — they remain in place.

---

## Contributing

Contributions welcome! Feel free to submit Issues and Pull Requests.

## License

[MIT](LICENSE)
