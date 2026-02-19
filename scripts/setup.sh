#!/usr/bin/env bash
# ==============================================================================
# setup.sh - One-Click Deployment for Claude Code Sync System
# ==============================================================================
# Usage: Clone this repo then run:
#   git clone https://github.com/YOUR_GITHUB_USER/openclaw-sync-toolkit.git ~/openclaw-sync-toolkit
#   cd ~/openclaw-sync-toolkit
#   bash scripts/setup.sh
#
# This script will automatically:
#   1. Install dependencies (fswatch, jq, syncthing)
#   2. Clone your config sync repository
#   3. Deploy sync scripts to ~/.claude-sync/
#   4. Generate machine-specific config
#   5. Perform initial pull (sync skills/settings/commands)
#   6. Install launchd background services
#   7. Start Syncthing (optional)
#   8. Output verification info and Syncthing device ID
# ==============================================================================
set -euo pipefail

# ========================= Configuration =========================

MACHINE_NAME=""
CONFIG_REPO=""
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-$HOME/claudecode_workspace}"
SYNC_HOME="${HOME}/.claude-sync"
SETUP_SYNCTHING=true
PARTNER_DEVICE_ID=""

# Get script directory (the cloned project root)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ========================= Color Output =========================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*" >&2; }
section() { echo -e "\n${BLUE}--- $* ---${NC}\n"; }

# ========================= Help =========================

usage() {
    cat <<'USAGE'
Usage: setup.sh [options]

One-click deployment for Claude Code Sync.

Options:
  --name <name>             Machine name (e.g., macbook-pro, mac-mini)
  --remote <url>            Git remote URL for config sync repo
  --workspace <dir>         Workspace directory (default: ~/claudecode_workspace)
  --partner-device <id>     Syncthing device ID of the partner machine
  --no-syncthing            Skip Syncthing setup
  --help                    Show this help

Examples:
  setup.sh --name macbook-pro --remote git@github.com:user/claude-config.git
  setup.sh --name mac-mini --remote https://github.com/user/repo.git --no-syncthing
USAGE
    exit 0
}

# ========================= Argument Parsing =========================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            MACHINE_NAME="$2"
            shift 2
            ;;
        --remote)
            CONFIG_REPO="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        --partner-device)
            PARTNER_DEVICE_ID="$2"
            shift 2
            ;;
        --no-syncthing)
            SETUP_SYNCTHING=false
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

# ========================= Interactive Prompts =========================

prompt_params() {
    if [[ -z "$MACHINE_NAME" ]]; then
        local default_name
        default_name="$(hostname -s 2>/dev/null || hostname)"
        read -rp "Enter machine name [${default_name}]: " MACHINE_NAME
        MACHINE_NAME="${MACHINE_NAME:-$default_name}"
    fi

    if [[ -z "$CONFIG_REPO" ]]; then
        echo ""
        read -rp "Enter Git remote URL for config sync: " CONFIG_REPO
        if [[ -z "$CONFIG_REPO" ]]; then
            error "Git remote URL cannot be empty"
            exit 1
        fi
    fi
}

# ========================= Phase 1: Install Dependencies =========================

install_dependencies() {
    section "Phase 1/6: Check and Install Dependencies"

    # Check Homebrew
    if ! command -v brew &>/dev/null; then
        error "Homebrew not installed. Please install first: https://brew.sh"
        exit 1
    fi
    ok "Homebrew installed"

    # Check git
    if ! command -v git &>/dev/null; then
        error "Git not installed"
        exit 1
    fi
    ok "Git installed"

    # Install fswatch
    if ! command -v fswatch &>/dev/null; then
        info "Installing fswatch..."
        brew install fswatch
    fi
    ok "fswatch installed"

    # Install jq
    if ! command -v jq &>/dev/null; then
        info "Installing jq..."
        brew install jq
    fi
    ok "jq installed"

    # Install syncthing (if enabled)
    if [[ "$SETUP_SYNCTHING" == true ]]; then
        if ! command -v syncthing &>/dev/null; then
            info "Installing Syncthing..."
            brew install syncthing
        fi
        ok "Syncthing installed"
    fi
}

# ========================= Phase 2: Clone Repository =========================

clone_repos() {
    section "Phase 2/6: Clone Repositories"

    # Clone config repository
    if [[ -d "${SYNC_HOME}/repo/.git" ]]; then
        info "Config repo exists, pulling updates..."
        git -C "${SYNC_HOME}/repo" pull --rebase 2>&1 || true
    else
        info "Cloning config repo: ${CONFIG_REPO}"
        mkdir -p "${SYNC_HOME}"
        git clone "${CONFIG_REPO}" "${SYNC_HOME}/repo"
    fi
    ok "Config repo ready: ${SYNC_HOME}/repo/"

    # Create workspace directory
    mkdir -p "${WORKSPACE_DIR}"
    ok "Workspace directory ready: ${WORKSPACE_DIR}/"
}

# ========================= Phase 3: Deploy Scripts =========================

deploy_scripts() {
    section "Phase 3/6: Deploy Sync Scripts"

    # Create directory structure
    mkdir -p "${SYNC_HOME}"/{logs,scripts,pids}
    ok "Directory structure created"

    # Copy scripts from project
    cp "${PROJECT_DIR}/scripts/"*.sh "${SYNC_HOME}/scripts/"
    chmod +x "${SYNC_HOME}/scripts/"*.sh
    ok "Sync scripts deployed to ${SYNC_HOME}/scripts/"

    # Copy .syncignore
    if [[ -f "${PROJECT_DIR}/config/.syncignore" ]]; then
        cp "${PROJECT_DIR}/config/.syncignore" "${SYNC_HOME}/.syncignore"
        ok ".syncignore copied"
    fi

    # Copy config templates
    if [[ -d "${PROJECT_DIR}/config" ]]; then
        cp -r "${PROJECT_DIR}/config" "${SYNC_HOME}/"
        ok "Config templates copied"
    fi

    # Generate sync-config.json
    cat > "${SYNC_HOME}/sync-config.json" << CONFIGEOF
{
  "machine_name": "${MACHINE_NAME}",
  "git_remote": "${CONFIG_REPO}",
  "git": {
    "remote": "${CONFIG_REPO}"
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
CONFIGEOF
    ok "sync-config.json generated (machine_name: ${MACHINE_NAME})"
}

# ========================= Phase 4: Initial Sync =========================

first_sync() {
    section "Phase 4/6: Initial Configuration Sync"

    info "Running sync.sh pull (syncing remote config to local ~/.claude/)..."
    "${SYNC_HOME}/scripts/sync.sh" pull 2>&1 || {
        warn "Initial pull returned non-zero (may have no remote commits), continuing..."
    }
    ok "Configuration sync complete"

    # Show synced skill count
    local skill_count=0
    if [[ -d "${HOME}/.claude/skills" ]]; then
        skill_count=$(find "${HOME}/.claude/skills" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        skill_count=$((skill_count - 1))  # Subtract skills/ directory itself
    fi
    info "Synced ${skill_count} skill directories to ~/.claude/skills/"
}

# ========================= Phase 5: Install launchd =========================

install_launchd() {
    section "Phase 5/6: Install launchd Background Services"

    local launch_agents_dir="${HOME}/Library/LaunchAgents"
    mkdir -p "${launch_agents_dir}"

    local plists=("com.claude-sync.pull.plist" "com.claude-sync.watch.plist" "com.claude-sync.workspace.plist")

    for plist in "${plists[@]}"; do
        local src="${SYNC_HOME}/config/launchd/${plist}"
        local dest="${launch_agents_dir}/${plist}"

        if [[ ! -f "${src}" ]]; then
            warn "plist template not found: ${src}, skipping"
            continue
        fi

        # Unload existing (if any)
        launchctl unload "${dest}" 2>/dev/null || true

        # Copy with placeholder replacement
        sed "s|__HOME__|${HOME}|g" "${src}" > "${dest}"

        # Load
        launchctl load "${dest}"
        ok "${plist} installed and loaded"
    done

    echo ""
    info "Installed services:"
    launchctl list 2>/dev/null | grep claude-sync || warn "No claude-sync services detected"
}

# ========================= Phase 6: Syncthing (Optional) =========================

setup_syncthing() {
    if [[ "$SETUP_SYNCTHING" != true ]]; then
        section "Phase 6/6: Syncthing (Skipped)"
        info "Syncthing setup skipped (--no-syncthing)"
        return
    fi

    section "Phase 6/6: Start Syncthing"

    # Start Syncthing service
    if brew services list 2>/dev/null | grep syncthing | grep -q started; then
        ok "Syncthing already running"
    else
        info "Starting Syncthing..."
        brew services start syncthing
        sleep 5  # Wait for startup and config generation
    fi

    # Get local device ID
    local my_device_id=""
    local syncthing_config="${HOME}/Library/Application Support/Syncthing/config.xml"

    # Wait for config file (first launch may need a few seconds)
    local wait_count=0
    while [[ ! -f "${syncthing_config}" ]] && (( wait_count < 15 )); do
        sleep 2
        (( wait_count++ ))
    done

    if [[ -f "${syncthing_config}" ]]; then
        # Extract device ID from config
        my_device_id=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('${syncthing_config}')
root = tree.getroot()
for device in root.findall('device'):
    did = device.get('id', '')
    if did:
        print(did)
        break
" 2>/dev/null || true)

        ok "Syncthing running"

        # If partner device ID provided, configure via API
        if [[ -n "${PARTNER_DEVICE_ID}" ]]; then
            local gui_address
            gui_address=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('${syncthing_config}')
root = tree.getroot()
gui = root.find('gui')
addr = gui.find('address')
print(addr.text if addr is not None else '127.0.0.1:8384')
" 2>/dev/null || echo "127.0.0.1:8384")

            local api_key
            api_key=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('${syncthing_config}')
root = tree.getroot()
gui = root.find('gui')
apikey = gui.find('apikey')
print(apikey.text if apikey is not None else '')
" 2>/dev/null || true)

            if [[ -n "${api_key}" ]]; then
                local base_url="http://${gui_address}"

                # Add partner device
                info "Adding partner device..."
                curl -s -X POST \
                    -H "X-API-Key: ${api_key}" \
                    -H "Content-Type: application/json" \
                    "${base_url}/rest/config/devices" \
                    -d "{
                        \"deviceID\": \"${PARTNER_DEVICE_ID}\",
                        \"name\": \"Partner\",
                        \"addresses\": [\"dynamic\"],
                        \"autoAcceptFolders\": true
                    }" 2>/dev/null && ok "Partner device added" || warn "Add device failed (may already exist)"

                # Add workspace shared folder
                info "Adding workspace shared folder..."
                curl -s -X POST \
                    -H "X-API-Key: ${api_key}" \
                    -H "Content-Type: application/json" \
                    "${base_url}/rest/config/folders" \
                    -d "{
                        \"id\": \"claudecode-workspace\",
                        \"label\": \"Claude Code Workspace\",
                        \"path\": \"${WORKSPACE_DIR}\",
                        \"type\": \"sendreceive\",
                        \"rescanIntervalS\": 60,
                        \"fsWatcherEnabled\": true,
                        \"fsWatcherDelayS\": 10,
                        \"autoNormalize\": true,
                        \"devices\": [{\"deviceID\": \"${PARTNER_DEVICE_ID}\"}],
                        \"versioning\": {
                            \"type\": \"simple\",
                            \"params\": {\"keep\": \"5\"}
                        }
                    }" 2>/dev/null && ok "Workspace shared folder added" || warn "Add folder failed (may already exist)"
            fi
        fi
    else
        warn "Syncthing config file not found, please configure manually"
    fi

    echo ""
    echo "================================================"
    if [[ -n "${my_device_id}" ]]; then
        echo -e "${GREEN}This machine's Syncthing Device ID:${NC}"
        echo "${my_device_id}"
    else
        echo -e "${YELLOW}Could not auto-detect device ID, run:${NC}"
        echo "  syncthing --device-id"
    fi
    echo "================================================"
    echo ""
    echo -e "${YELLOW}Share this device ID with your partner machine to complete pairing.${NC}"
}

# ========================= Final Verification =========================

final_verification() {
    echo ""
    section "Deployment Complete - Verification"

    # Check sync script
    if [[ -x "${SYNC_HOME}/scripts/sync.sh" ]]; then
        ok "Sync script: ${SYNC_HOME}/scripts/sync.sh"
    else
        error "Sync script not found"
    fi

    # Check config file
    if [[ -f "${SYNC_HOME}/sync-config.json" ]]; then
        local mn
        mn=$(python3 -c "import json; print(json.load(open('${SYNC_HOME}/sync-config.json'))['machine_name'])" 2>/dev/null || echo "?")
        ok "Config file: machine_name=${mn}"
    else
        error "Config file not found"
    fi

    # Check config repo
    if [[ -d "${SYNC_HOME}/repo/.git" ]]; then
        local commit_count
        commit_count=$(git -C "${SYNC_HOME}/repo" rev-list --count HEAD 2>/dev/null || echo "?")
        ok "Config repo: ${commit_count} commits"
    else
        error "Config repo not cloned"
    fi

    # Check launchd services
    local service_count
    service_count=$(launchctl list 2>/dev/null | grep -c claude-sync || echo "0")
    if (( service_count >= 3 )); then
        ok "launchd services: ${service_count} running"
    else
        warn "launchd services: only ${service_count} (expected 3)"
    fi

    # Check synced skills
    local skill_dirs=0
    if [[ -d "${HOME}/.claude/skills" ]]; then
        skill_dirs=$(find "${HOME}/.claude/skills" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        skill_dirs=$((skill_dirs - 1))
    fi
    ok "Synced skills: ${skill_dirs}"

    echo ""
    echo "================================================"
    echo -e "${GREEN}Deployment Complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Share the Syncthing device ID with your partner machine"
    echo "  2. (Optional) Configure Telegram notifications:"
    echo "     Edit ${SYNC_HOME}/sync-config.json"
    echo "     Set telegram.enabled=true, bot_token, chat_id"
    echo ""
    echo "Common commands:"
    echo "  ${SYNC_HOME}/scripts/sync.sh status    # View sync status"
    echo "  ${SYNC_HOME}/scripts/sync.sh push      # Push local changes"
    echo "  ${SYNC_HOME}/scripts/sync.sh pull      # Pull remote changes"
    echo "  ${SYNC_HOME}/scripts/sync.sh log       # View sync log"
    echo "================================================"
}

# ========================= Main Entry =========================

main() {
    echo ""
    echo "========================================================"
    echo "  openclaw-sync-toolkit - One-Click Setup"
    echo "========================================================"
    echo ""
    echo "This script deploys the complete Claude Code sync system."
    echo "After setup, this machine will auto-sync with your partner:"
    echo "  - Claude Code configs (skills/settings/commands/agents/plugins)"
    echo "  - Workspace files (via Syncthing + Git)"
    echo ""

    prompt_params
    install_dependencies
    clone_repos
    deploy_scripts
    first_sync
    install_launchd
    setup_syncthing
    final_verification
}

main "$@"
