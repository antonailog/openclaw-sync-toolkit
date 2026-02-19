# Architecture Design Document

This document describes the technical architecture, design decisions, and implementation details of openclaw-sync-toolkit.

## Table of Contents

- [System Overview](#system-overview)
- [Layer 1: Claude Code Config Sync (Git)](#layer-1-claude-code-config-sync-git)
- [Layer 2: Workspace File Sync (Syncthing)](#layer-2-workspace-file-sync-syncthing)
- [Layer 3: Deployment State Management](#layer-3-deployment-state-management)
- [Layer 4: Monitoring & Notifications](#layer-4-monitoring--notifications)
- [Layer 5: Logging System](#layer-5-logging-system)
- [Skill Dependency Management](#skill-dependency-management)
- [Rollback Mechanism](#rollback-mechanism)
- [Security Considerations](#security-considerations)
- [Edge Cases & Failure Handling](#edge-cases--failure-handling)

---

## System Overview

### Problem Domain

Two (or more) Mac machines running Claude Code simultaneously:

| Machine | Role | Usage |
|---|---|---|
| MacBook Pro | Primary dev machine | Direct terminal access to Claude Code |
| Mac Mini | Remote/cloud machine | Access via Telegram/Discord gateway |

Core problems to solve:

1. How to keep Claude Code capability configs (skills, settings, commands, agents, plugins) consistent
2. How to sync workspace project files in real-time
3. How to detect and monitor sync changes
4. How to safely update code for running services

### Layered Architecture

```
+--------------------------------------------------------------+
|                    Layer 5: Logging System                    |
|             sync.log | conflict.log | deploy.log             |
|                 10MB rotation / retain 10                    |
+--------------------------------------------------------------+
|                 Layer 4: Monitoring & Notifications           |
|          fswatch file monitor | launchd scheduler | Telegram |
+--------------------------------------------------------------+
|                 Layer 3: Deployment State Management          |
|         .deploy-state.json | staging dir | service lifecycle |
+----------------------------+---------------------------------+
|  Layer 1: Config Sync      |    Layer 2: Workspace Sync      |
|  Git push/pull             |    Syncthing bidirectional       |
|  ~/.claude/ config files   |    ~/workspace/ project files    |
+----------------------------+---------------------------------+
```

### Data Flow

```
Machine A                        Git Remote                      Machine B
---------                        ----------                      ---------

[Edit skill]
     |
     v
[fswatch detects change]
     |
     v
[sync.sh push]
     |
     +---> [commit + push] -------> [remote repo] <------ [periodic pull] <-- [launchd]
     |                                                          |
     v                                                          v
[notify.sh]                                              [sync.sh pull]
     |                                                          |
     v                                                          +---> [check deps]
[Telegram: "pushed                                              +---> [detect conflicts]
 2 files"]                                                      +---> [apply changes]
                                                                |
                                                                v
                                                         [notify.sh]
                                                                |
                                                                v
                                                         [Telegram: "pulled
                                                          2 files"]
```

---

## Layer 1: Claude Code Config Sync (Git)

### Sync Scope

**Synced content:**

| Path | Description | Sync Method |
|---|---|---|
| `~/.claude/skills/` | Custom skills (Markdown files) | Entire directory |
| `~/.claude/settings.json` | Global settings (common portion) | Single file |
| `~/.claude/commands/` | Custom commands | Entire directory |
| `~/.claude/agents/` | Agent configurations | Entire directory |
| `~/.claude/plugins/` | Plugins | Entire directory |

**Excluded from sync:**

| Path/Pattern | Reason |
|---|---|
| `settings.local.json` | Machine-specific settings (MCP paths, local env) |
| `.env` / `*.key` / `*.pem` | Sensitive credentials |
| `mcp-servers.local.json` | MCP server paths differ per machine |
| `node_modules/` / `__pycache__/` | Build artifacts |
| `.DS_Store` | macOS system files |

### Git Repository Structure

Sync uses a dedicated Git repository (at `~/.claude-sync/repo/`), mirroring `~/.claude/`:

```
~/.claude-sync/repo/
├── .git/
├── .gitignore
├── skills/
│   ├── api-helper.md
│   ├── code-review.md
│   └── deps.json
├── settings.json
├── commands/
│   ├── deploy.md
│   └── review.md
├── agents/
│   └── researcher.json
└── plugins/
    └── my-plugin/
```

### Sync Flow

**Push flow:**

```
1. Read files under ~/.claude/ that need syncing
2. Resolve symlinks -> convert to actual file content
3. Copy to ~/.claude-sync/repo/ at corresponding paths
4. Filter by .syncignore rules
5. git add -A
6. git commit -m "<message>"
7. git push origin main
8. Log to sync.log
9. Send Telegram notification
```

**Pull flow:**

```
1. git fetch origin
2. Check for new commits (compare HEAD vs origin/main)
3. git merge origin/main (enter conflict handling if conflicts arise)
4. Copy files from repo/ back to ~/.claude/
5. Skip files in .syncignore
6. Check skills/deps.json dependencies
7. Log to sync.log
8. Send Telegram notification (with changed file list)
```

### Symlink Handling

**Design decision**: All symlinks are converted to real files during sync.

Reasons:
- Symlink targets typically differ across machines (e.g., `/Users/alice/` vs `/Users/bob/`)
- Git's symlink behavior is inconsistent across environments
- Real files ensure content is available after sync

### Conflict Handling

**Strategy: Keep Local + Conflict Backup + Notification**

When `git merge` produces conflicts:

```
1. Keep local version as the active file
2. Save remote version as <file>.conflict
3. Write conflict info to conflict.log
4. Send Telegram notification with:
   - Conflict filename
   - Conflict backup path
   - Suggested action (review .conflict file)
```

**Manual resolution:**

```bash
# View conflict backups
ls ~/.claude/skills/*.conflict

# Keep local version
sync.sh resolve skills/api-helper.md --keep-local

# Accept remote version
sync.sh resolve skills/api-helper.md --keep-remote
```

---

## Layer 2: Workspace File Sync (Syncthing)

### Why Syncthing

| Solution | Pros | Cons | Decision |
|---|---|---|---|
| rsync + cron | Simple, one-way | Not real-time, bidirectional is complex | No |
| Syncthing | Real-time bidirectional, P2P, open source | Requires installation | **Selected** |
| Unison | Mature bidirectional sync | Complex config, slow | No |
| Git | Existing infrastructure | Not suitable for frequent binary changes | Config only |

### Recommended Syncthing Configuration

**Shared folder settings:**

- Folder path: `~/workspace/`
- Sync type: Send & Receive (bidirectional)
- File versioning: Simple File Versioning (keep 5 history versions)
- Scan interval: 60 seconds (combined with fswatch for real-time notification)

### Boundary with Config Sync

```
Sync method selection:

~/.claude/           --> Git (config files, infrequent changes, needs version history + rollback)
~/workspace/         --> Syncthing (project files, frequent changes, needs real-time sync)
.deploy-state.json   --> Not synced (maintained independently per machine)
```

---

## Layer 3: Deployment State Management

### Problem

Running long-lived services (e.g., a Telegram Bot) on a remote machine. When workspace code syncs via Syncthing:

- Restarting directly may cause service interruption
- Not restarting means running stale code
- Need a mechanism to handle this safely

### .deploy-state.json Structure

```json
{
  "service": "my-bot",
  "status": "running",
  "pid": 12345,
  "start_command": "node src/index.js",
  "deployed_commit": "abc1234",
  "deployed_at": "2026-02-19T10:00:00Z",
  "auto_restart": false,
  "staging_commit": null
}
```

### Update Flow

```
Code synced (via Syncthing)
         |
         v
  Check .deploy-state.json
         |
         +-- No related service running --> No action
         |
         +-- auto_restart: true
         |       |
         |       v
         |   Stop service (graceful shutdown)
         |       |
         |       v
         |   Wait for process exit (30s timeout)
         |       |
         |       v
         |   Start service
         |       |
         |       +-- Success --> status -> "running", notify
         |       +-- Failure --> status -> "error", alert
         |
         +-- auto_restart: false (default)
                 |
                 v
         Send Telegram notification:
         "Project my-bot has new code available.
          Run deploy.sh update my-bot to update."
```

---

## Layer 4: Monitoring & Notifications

### fswatch File Monitor

Watches `~/.claude/` for file changes and auto-triggers `sync.sh push`.

**Debounce design**: Wait 5 seconds after last change before triggering push, to avoid frequent commits during editing.

```
[File change event] --> [Wait 5s with no new events] --> [sync.sh push] --> [notify.sh]
     |
     +-- [New change within 5s] --> [Reset timer]
```

### launchd Configuration

Three launchd plist files installed in `~/Library/LaunchAgents/`:

| Service | Purpose | Schedule |
|---|---|---|
| `com.claude-sync.pull` | Periodic remote pull | Every 5 minutes |
| `com.claude-sync.watch` | File change monitor | Always running (KeepAlive) |
| `com.claude-sync.workspace` | Workspace deploy monitor | Always running (KeepAlive) |

### Telegram Notifications

| Level | Scenario | Format |
|---|---|---|
| `sync_push` | Normal push complete | `[PUSH] [machine] Pushed 3 files` |
| `conflict` | Conflict detected | `[CONFLICT] [machine] skills/api-helper.md needs review` |
| `error` | Sync failure | `[ERROR] [machine] Remote repository unreachable` |
| `deploy_update` | Deploy-related | `[DEPLOY] [machine] Project my-bot has new code` |

---

## Layer 5: Logging System

### Log Files

| File | Path | Writer |
|---|---|---|
| `sync.log` | `~/.claude-sync/sync.log` | sync.sh |
| `conflict.log` | `~/.claude-sync/conflict.log` | sync.sh (conflict handling) |

### Log Format

```
[timestamp] [OPERATION] [machine_name]
  changed: file1
  changed: file2
  status:  SUCCESS
```

### Log Rotation

**Strategy**: Rotate when log exceeds 10MB, keep up to 10 archives.

```
sync.log         (current)
sync.log.1       (previous rotation)
sync.log.2       (older)
...
sync.log.10      (oldest, deleted on next rotation)
```

---

## Skill Dependency Management

### deps.json Format

Each skill directory can have a `deps.json` file declaring external dependencies:

```json
{
  "dependencies": [
    {"name": "jq", "check": "which jq"},
    {"name": "ripgrep", "check": "which rg"}
  ]
}
```

### Dependency Check Flow

After `sync.sh pull` completes:

1. Scan all `deps.json` files under `skills/`
2. Run each dependency check command
3. Collect missing dependencies
4. If missing: log + send Telegram notification
5. Dependencies are never auto-installed (to avoid unintended system changes)

---

## Rollback Mechanism

### Git-Based Rollback

All config changes are managed via Git, providing natural version history.

```bash
# View history
sync.sh log

# Rollback a specific file
sync.sh rollback skills/my-skill/skill.md a3f8c2d
```

Rollback steps:
1. Validate commit hash exists
2. Checkout file content from specified commit
3. Deploy rolled-back file to `~/.claude/`
4. Commit and push the rollback
5. Log and notify

---

## Security Considerations

### Sensitive File Protection

The following files/patterns are never synced:

```
settings.local.json    # Machine-specific settings
.env                   # Environment variables
*.key                  # Key files
*.pem                  # Certificate files
*credentials*          # Credential files
```

### Git Repository Security

- Use a private Git repository
- Authenticate via SSH key (never store passwords in config)
- `.syncignore` itself is synced, ensuring consistent rules across machines

### Process Safety

- deploy.sh tracks processes via PID files
- Graceful shutdown (SIGTERM) with SIGKILL fallback after timeout
- State file updated only after confirmed process start/stop

---

## Edge Cases & Failure Handling

### Network Failures

| Scenario | Behavior |
|---|---|
| Push with no network | Local commit succeeds, push fails. Logged. Next push includes pending changes. |
| Pull with no network | Fetch fails, skip this pull. launchd retries next cycle. |
| Telegram unreachable | Notification silently fails (10s curl timeout). Sync unaffected. |
| Syncthing disconnected | Syncthing handles reconnection. Changes sync after reconnection. |

### Concurrency Conflicts

| Scenario | Behavior |
|---|---|
| Simultaneous push from 2 machines | Second push fails (non-fast-forward). Auto pull + merge then retry. |
| File modified during push | Current push completes. fswatch detects new change, triggers next push. |
| Local file modified during pull | May produce conflict, handled by conflict strategy. |

### Process Anomalies

| Scenario | Behavior |
|---|---|
| fswatch crashes | launchd `KeepAlive=true` auto-restarts |
| sync.sh interrupted | Git operations are atomic. Next run works normally. |
| Deployed service crashes | Status updated to reflect reality on next health check. |
| Disk full | Git operations fail, error logged. Log rotation helps control log size. |
