#!/usr/bin/env bash
# monitor.sh - File Change Monitor
# Watch file changes via fswatch and auto-trigger sync and deploy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_HOME="$HOME/.claude-sync"
CONFIG_FILE="$SYNC_HOME/sync-config.json"
LOG_FILE="$SYNC_HOME/sync.log"
PID_DIR="$SYNC_HOME/pids"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-$HOME/claudecode_workspace}"

# fswatch debounce time (seconds)
DEBOUNCE_SECONDS=5

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

# ====== Logging ======
log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [monitor] $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ====== Help ======
usage() {
    cat <<'USAGE'
Usage: monitor.sh <mode>

File change monitor that watches for changes and auto-syncs via fswatch.

Modes:
  watch       Watch local config files for changes, auto-push to Git
              Watched dirs: ~/.claude/skills, ~/.claude/commands, etc.
              Debounces 5 seconds after change detection, then runs sync.sh push

  pull        Execute a one-time periodic pull check
              Pulls remote updates and checks if deployed projects need updating
              Typically called by launchd every 5 minutes

  workspace   Watch workspace directory, auto-trigger deploy updates
              Watches projects with .deploy-state.json under workspace dir
              Auto-redeploys based on auto_restart setting

Options:
  --help      Show this help

Examples:
  monitor.sh watch          # Foreground, watch config file changes
  monitor.sh pull           # One-time pull check
  monitor.sh workspace      # Foreground, watch workspace changes
USAGE
    exit 0
}

# ====== PID File Management ======

# Get PID file path
pid_file() {
    local mode="$1"
    echo "$PID_DIR/monitor-${mode}.pid"
}

# Check for duplicate instances
check_duplicate() {
    local mode="$1"
    local pf
    pf="$(pid_file "$mode")"

    if [[ -f "$pf" ]]; then
        local existing_pid
        existing_pid="$(cat "$pf" 2>/dev/null || echo "")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            error "monitor.sh $mode is already running (PID: $existing_pid)"
            error "To restart, first kill it: kill $existing_pid"
            exit 1
        else
            # PID file exists but process is gone, clean up
            rm -f "$pf"
        fi
    fi
}

# Write PID file
write_pid() {
    local mode="$1"
    mkdir -p "$PID_DIR"
    echo $$ > "$(pid_file "$mode")"
}

# Clean up PID file
cleanup_pid() {
    local mode="$1"
    rm -f "$(pid_file "$mode")" 2>/dev/null || true
}

# ====== Signal Handling (graceful exit) ======

# Global: fswatch subprocess PID
FSWATCH_PID=""
CURRENT_MODE=""

cleanup_and_exit() {
    log_msg "Received termination signal, cleaning up..."
    info "Received termination signal, exiting..."

    # Terminate fswatch subprocess
    if [[ -n "$FSWATCH_PID" ]] && kill -0 "$FSWATCH_PID" 2>/dev/null; then
        kill "$FSWATCH_PID" 2>/dev/null || true
        wait "$FSWATCH_PID" 2>/dev/null || true
    fi

    # Clean up PID file
    if [[ -n "$CURRENT_MODE" ]]; then
        cleanup_pid "$CURRENT_MODE"
    fi

    log_msg "monitor.sh ${CURRENT_MODE} exited"
    exit 0
}

# Trap SIGTERM and SIGINT
trap cleanup_and_exit SIGTERM SIGINT

# ====== Utility Functions ======

# Read sync source directory list (from config file)
get_watch_paths() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Read sync source paths from config
        jq -r '.sync_sources | to_entries[] | .value' "$CONFIG_FILE" 2>/dev/null | while read -r path; do
            # Expand ~ to actual path
            echo "${path/#\~/$HOME}"
        done
    else
        # Default watch paths
        echo "$HOME/.claude/skills"
        echo "$HOME/.claude/settings.json"
        echo "$HOME/.claude/commands"
        echo "$HOME/.claude/agents"
        echo "$HOME/.claude/plugins"
        echo "$HOME/.agents/skills"
    fi
}

# Filter to only existing paths
filter_existing_paths() {
    while read -r path; do
        if [[ -e "$path" ]]; then
            echo "$path"
        fi
    done
}

# ====== Mode 1: watch - Watch config file changes ======
mode_watch() {
    CURRENT_MODE="watch"
    check_duplicate "watch"
    write_pid "watch"

    info "Starting file watch mode"
    log_msg "Starting watch mode"

    # Get watch paths
    local paths=()
    while IFS= read -r p; do
        paths+=("$p")
    done < <(get_watch_paths | filter_existing_paths)

    if [[ ${#paths[@]} -eq 0 ]]; then
        error "No paths to watch"
        cleanup_pid "watch"
        exit 1
    fi

    info "Watching directories:"
    for p in "${paths[@]}"; do
        echo "  - $p"
    done
    echo ""

    # Use fswatch to watch for changes
    # --latency: debounce delay (seconds)
    # --recursive: recursively watch subdirectories
    fswatch --latency "$DEBOUNCE_SECONDS" --recursive "${paths[@]}" | while read -r changed_file; do
        # Filter out common temp files
        local basename_file
        basename_file="$(basename "$changed_file")"

        case "$basename_file" in
            .DS_Store|*.swp|*.swo|*~) continue ;;
        esac

        log_msg "File change detected: $changed_file"
        info "File change detected: $changed_file"

        # Execute sync push
        info "Executing sync push..."
        if "$SCRIPT_DIR/sync.sh" push 2>&1 | tee -a "$LOG_FILE"; then
            ok "Sync push successful"
            log_msg "Sync push successful"
            # Send notification
            "$SCRIPT_DIR/notify.sh" sync_push "File change detected, auto-pushed" || true
        else
            error "Sync push failed"
            log_msg "Sync push failed"
            "$SCRIPT_DIR/notify.sh" error "Auto-push failed, check logs" || true
        fi
    done &
    FSWATCH_PID=$!

    # Wait for fswatch process
    wait "$FSWATCH_PID" || true
    cleanup_pid "watch"
}

# ====== Mode 2: pull - Periodic pull check ======
mode_pull() {
    CURRENT_MODE="pull"
    log_msg "Executing periodic pull check"

    # Execute pull
    local pull_output
    if pull_output="$("$SCRIPT_DIR/sync.sh" pull 2>&1)"; then
        log_msg "Pull complete"

        # Check for new changes
        if echo "$pull_output" | grep -qi "updated\|changed\|new"; then
            info "Remote updates detected"
            log_msg "Remote updates detected"

            # Check all deployed projects
            check_deployed_projects

            # Send pull notification
            "$SCRIPT_DIR/notify.sh" sync_pull "Remote updates detected, synced to local" || true
        fi
    else
        log_msg "Pull failed: $pull_output"
        "$SCRIPT_DIR/notify.sh" error "Periodic pull failed: $pull_output" || true
    fi
}

# Check deployed projects for needed updates
check_deployed_projects() {
    for state_file in "$WORKSPACE_DIR"/*/.deploy-state.json; do
        [[ -f "$state_file" ]] || continue

        local project_dir
        project_dir="$(dirname "$state_file")"
        local name
        name="$(basename "$project_dir")"

        local state
        state="$(cat "$state_file")"
        local status
        status="$(echo "$state" | jq -r '.status // ""')"
        local auto_restart
        auto_restart="$(echo "$state" | jq -r '.auto_restart // false')"
        local deployed_commit
        deployed_commit="$(echo "$state" | jq -r '.deployed_commit // ""')"

        # Only check running projects
        if [[ "$status" != "running" ]]; then
            continue
        fi

        # Get current commit
        local current_commit=""
        if [[ -d "$project_dir/.git" ]]; then
            current_commit="$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || echo "")"
        fi

        # Compare commits
        if [[ -n "$current_commit" ]] && [[ "$current_commit" != "$deployed_commit" ]]; then
            log_msg "Project $name has code updates ($deployed_commit -> $current_commit)"

            if [[ "$auto_restart" == "true" ]]; then
                info "Auto-redeploying project: $name"
                log_msg "Auto-redeploy: $name"
                "$SCRIPT_DIR/deploy.sh" update "$project_dir" || {
                    log_msg "Auto-redeploy failed: $name"
                    "$SCRIPT_DIR/notify.sh" error "Auto-redeploy failed: $name" || true
                }
            else
                info "Project $name has updates available (auto-restart disabled)"
                "$SCRIPT_DIR/notify.sh" deploy_update "Project $name has new code ($deployed_commit -> $current_commit)" || true
            fi
        fi
    done
}

# ====== Mode 3: workspace - Watch workspace changes ======
mode_workspace() {
    CURRENT_MODE="workspace"
    check_duplicate "workspace"
    write_pid "workspace"

    info "Starting workspace watch mode"
    log_msg "Starting workspace mode"

    # Collect project directories to watch
    local watch_dirs=()
    for state_file in "$WORKSPACE_DIR"/*/.deploy-state.json; do
        [[ -f "$state_file" ]] || continue
        local dir
        dir="$(dirname "$state_file")"
        watch_dirs+=("$dir")
        info "Watching project: $(basename "$dir")"
    done

    if [[ ${#watch_dirs[@]} -eq 0 ]]; then
        warn "No deployed projects found in workspace"
        warn "Waiting for project deployments..."
        # Watch entire workspace for new .deploy-state.json files
        watch_dirs=("$WORKSPACE_DIR")
    fi

    # Use fswatch to watch
    fswatch --latency "$DEBOUNCE_SECONDS" --recursive "${watch_dirs[@]}" | while read -r changed_file; do
        # Skip temp files and deploy state file itself
        local basename_file
        basename_file="$(basename "$changed_file")"
        case "$basename_file" in
            .DS_Store|*.swp|*.swo|*~|.deploy.log) continue ;;
        esac

        # If new deploy-state.json, reload watch (via restart)
        if [[ "$basename_file" == ".deploy-state.json" ]]; then
            log_msg "Deploy state change detected: $changed_file"
            continue
        fi

        # Determine which project the changed file belongs to
        local project_dir=""
        for dir in "${watch_dirs[@]}"; do
            if [[ "$changed_file" == "$dir"* ]]; then
                project_dir="$dir"
                break
            fi
        done

        if [[ -z "$project_dir" ]] || [[ ! -f "$project_dir/.deploy-state.json" ]]; then
            continue
        fi

        local name
        name="$(basename "$project_dir")"
        log_msg "Workspace file change: $changed_file (project: $name)"

        # Read deployment state
        local state
        state="$(cat "$project_dir/.deploy-state.json" 2>/dev/null || echo "{}")"
        local status
        status="$(echo "$state" | jq -r '.status // ""')"
        local auto_restart
        auto_restart="$(echo "$state" | jq -r '.auto_restart // false')"

        if [[ "$status" != "running" ]]; then
            continue
        fi

        if [[ "$auto_restart" == "true" ]]; then
            info "Workspace change triggered auto-redeploy: $name"
            log_msg "Workspace triggered auto-redeploy: $name"
            "$SCRIPT_DIR/deploy.sh" update "$project_dir" || {
                log_msg "Workspace auto-redeploy failed: $name"
                "$SCRIPT_DIR/notify.sh" error "Workspace auto-redeploy failed: $name" || true
            }
        else
            "$SCRIPT_DIR/notify.sh" deploy_update "Project $name workspace files changed" || true
        fi
    done &
    FSWATCH_PID=$!

    wait "$FSWATCH_PID" || true
    cleanup_pid "workspace"
}

# ====== Main Entry ======
if [[ $# -lt 1 ]]; then
    usage
fi

MODE="$1"

case "$MODE" in
    watch)     mode_watch ;;
    pull)      mode_pull ;;
    workspace) mode_workspace ;;
    --help|-h) usage ;;
    *)
        error "Unknown mode: $MODE"
        usage
        ;;
esac
