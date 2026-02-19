#!/usr/bin/env bash
# install.sh - Claude Code Sync First-Time Installation Script
# Automates initial setup on a new machine
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC_HOME="$HOME/.claude-sync"
CONFIG_FILE="$SYNC_HOME/sync-config.json"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

# ====== Color Output ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ====== Help ======
usage() {
    cat <<'USAGE'
Usage: install.sh [options]

Claude Code Sync first-time installation script.

Options:
  --remote <url>        Git remote repository URL
  --name <name>         Machine name (defaults to hostname)
  --no-launchd          Skip launchd scheduled task installation
  --help                Show this help

Examples:
  install.sh --remote git@github.com:YOUR_GITHUB_USER/claude-code-sync.git
  install.sh --remote https://github.com/YOUR_GITHUB_USER/repo.git --name MacBook-Pro
  install.sh --no-launchd
USAGE
    exit 0
}

# ====== Argument Parsing ======
GIT_REMOTE=""
MACHINE_NAME=""
INSTALL_LAUNCHD=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)
            GIT_REMOTE="$2"
            shift 2
            ;;
        --name)
            MACHINE_NAME="$2"
            shift 2
            ;;
        --no-launchd)
            INSTALL_LAUNCHD=false
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            error "Unknown argument: $1"
            usage
            ;;
    esac
done

# ====== Check Prerequisites ======
check_prerequisites() {
    info "Checking prerequisites..."

    # Check git
    if ! command -v git &>/dev/null; then
        error "git not found, please install git first"
        exit 1
    fi
    ok "git installed: $(git --version)"

    # Check fswatch
    if ! command -v fswatch &>/dev/null; then
        warn "fswatch not found, attempting to install via Homebrew..."
        if command -v brew &>/dev/null; then
            brew install fswatch
            ok "fswatch installed"
        else
            error "Homebrew not found, please install fswatch manually: brew install fswatch"
            exit 1
        fi
    else
        ok "fswatch installed"
    fi

    # Check jq (JSON processing)
    if ! command -v jq &>/dev/null; then
        warn "jq not found, attempting to install via Homebrew..."
        if command -v brew &>/dev/null; then
            brew install jq
            ok "jq installed"
        else
            error "Homebrew not found, please install jq manually: brew install jq"
            exit 1
        fi
    else
        ok "jq installed"
    fi
}

# ====== Interactive Parameter Collection ======
prompt_params() {
    # Git remote URL
    if [[ -z "$GIT_REMOTE" ]]; then
        echo ""
        read -rp "Enter Git remote repository URL: " GIT_REMOTE
        if [[ -z "$GIT_REMOTE" ]]; then
            error "Git remote URL cannot be empty"
            exit 1
        fi
    fi

    # Machine name
    if [[ -z "$MACHINE_NAME" ]]; then
        local default_name
        default_name="$(hostname -s 2>/dev/null || hostname)"
        read -rp "Enter machine name [${default_name}]: " MACHINE_NAME
        MACHINE_NAME="${MACHINE_NAME:-$default_name}"
    fi
}

# ====== Create Directory Structure ======
create_directories() {
    info "Creating directory structure..."

    mkdir -p "$SYNC_HOME/repo"
    mkdir -p "$SYNC_HOME/pids"

    # Create log files
    touch "$SYNC_HOME/sync.log"
    touch "$SYNC_HOME/conflict.log"

    ok "Directory structure created: $SYNC_HOME"
}

# ====== Clone Repository ======
clone_repo() {
    info "Cloning Git repository..."

    if [[ -d "$SYNC_HOME/repo/.git" ]]; then
        warn "Repository exists, running git pull to update..."
        cd "$SYNC_HOME/repo"
        git pull --rebase 2>/dev/null || true
    else
        # Clear repo dir and clone
        rm -rf "$SYNC_HOME/repo"
        git clone "$GIT_REMOTE" "$SYNC_HOME/repo"
    fi

    ok "Repository clone complete"
}

# ====== Install Scripts ======
install_scripts() {
    info "Installing script files..."

    # Copy scripts and configs to ~/.claude-sync/
    cp -r "$PROJECT_DIR/scripts" "$SYNC_HOME/"
    cp -r "$PROJECT_DIR/config" "$SYNC_HOME/"

    # Ensure scripts are executable
    chmod +x "$SYNC_HOME/scripts/"*.sh

    # Copy .syncignore to sync root
    if [[ -f "$SYNC_HOME/config/.syncignore" ]]; then
        cp "$SYNC_HOME/config/.syncignore" "$SYNC_HOME/.syncignore"
    fi

    ok "Scripts installed"
}

# ====== Generate Config File ======
generate_config() {
    info "Generating config file..."

    if [[ -f "$CONFIG_FILE" ]]; then
        warn "Config file already exists, skipping (delete $CONFIG_FILE to regenerate)"
        return
    fi

    cat > "$CONFIG_FILE" <<CONF
{
  "machine_name": "${MACHINE_NAME}",
  "git_remote": "${GIT_REMOTE}",
  "git": {
    "remote": "${GIT_REMOTE}"
  },
  "sync_sources": {
    "skills": "~/.claude/skills",
    "settings": "~/.claude/settings.json",
    "commands": "~/.claude/commands",
    "agents": "~/.claude/agents",
    "plugins": "~/.claude/plugins",
    "agents_skills": "~/.agents/skills"
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
CONF

    ok "Config file generated: $CONFIG_FILE"
}

# ====== Initial Sync ======
initial_sync() {
    info "Performing initial sync..."

    if [[ -x "$SYNC_HOME/scripts/sync.sh" ]]; then
        "$SYNC_HOME/scripts/sync.sh" pull || warn "Initial sync failed, you can run sync.sh pull manually later"
    else
        warn "sync.sh not installed yet, skipping initial sync"
    fi
}

# ====== Install launchd Scheduled Tasks ======
install_launchd() {
    if [[ "$INSTALL_LAUNCHD" != true ]]; then
        info "Skipping launchd installation (--no-launchd)"
        return
    fi

    info "Installing launchd scheduled tasks..."

    mkdir -p "$LAUNCH_AGENTS_DIR"

    local plist_dir="$SYNC_HOME/config/launchd"
    if [[ ! -d "$plist_dir" ]]; then
        warn "launchd plist template directory not found, skipping"
        return
    fi

    for plist in "$plist_dir"/*.plist; do
        [[ -f "$plist" ]] || continue

        local basename
        basename="$(basename "$plist")"
        local target="$LAUNCH_AGENTS_DIR/$basename"
        local label="${basename%.plist}"

        # Replace __HOME__ placeholder with actual path
        sed "s|__HOME__|${HOME}|g" "$plist" > "$target"

        # Try to unload existing task first
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true

        # Load new task
        launchctl bootstrap "gui/$(id -u)" "$target" 2>/dev/null || \
            launchctl load "$target" 2>/dev/null || \
            warn "Failed to load $basename, please run manually: launchctl load $target"

        ok "Installed: $basename"
    done
}

# ====== Print Summary ======
print_summary() {
    echo ""
    echo "================================================"
    echo -e "${GREEN}  Claude Code Sync Installation Complete${NC}"
    echo "================================================"
    echo ""
    echo "  Machine name:  $MACHINE_NAME"
    echo "  Git remote:    $GIT_REMOTE"
    echo "  Sync dir:      $SYNC_HOME"
    echo "  Config file:   $CONFIG_FILE"
    echo "  Log file:      $SYNC_HOME/sync.log"
    echo ""
    if [[ "$INSTALL_LAUNCHD" == true ]]; then
        echo "  Installed scheduled tasks:"
        for plist in "$LAUNCH_AGENTS_DIR"/com.claude-sync.*.plist; do
            [[ -f "$plist" ]] && echo "    - $(basename "$plist")"
        done
        echo ""
    fi
    echo "  Common commands:"
    echo "    sync.sh push           Push local changes"
    echo "    sync.sh pull           Pull remote changes"
    echo "    deploy.sh status       View deployment status"
    echo "    monitor.sh watch       Start file watcher"
    echo ""
    echo "  To configure Telegram notifications, edit:"
    echo "    $CONFIG_FILE"
    echo ""
}

# ====== Main Flow ======
main() {
    echo ""
    echo "========================================="
    echo "  Claude Code Sync Installation Wizard"
    echo "========================================="
    echo ""

    check_prerequisites
    prompt_params
    create_directories
    clone_repo
    install_scripts
    generate_config
    initial_sync
    install_launchd
    print_summary
}

main
