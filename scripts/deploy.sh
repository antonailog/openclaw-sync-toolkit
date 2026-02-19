#!/usr/bin/env bash
# deploy.sh - Project Deployment Manager
# Manage deployment state of projects in the workspace (start/stop/update/status)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_HOME="$HOME/.claude-sync"
CONFIG_FILE="$SYNC_HOME/sync-config.json"
LOG_FILE="$SYNC_HOME/sync.log"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-$HOME/claudecode_workspace}"

# ====== Color Output ======
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ====== Logging ======
log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [deploy] $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ====== Help ======
usage() {
    cat <<'USAGE'
Usage: deploy.sh <command> [args]

Project deployment manager for workspace projects.

Commands:
  start <project_dir> [options]    Mark project as deployed
    --auto-restart                 Enable auto-restart on code update
    --cmd <start_command>          Specify start command (default: npm start)

  stop <project_dir>               Stop a deployed project

  status [project_dir]             View deployment status
    No project: view all projects
    With project: view specific project

  update <project_dir>             Deploy new code
    Running: stop -> update -> restart
    Stopped: update state only

  check <project_dir>              Check if updates are available
    Returns 0: up to date
    Returns 1: updates available

  --help                           Show this help

Examples:
  deploy.sh start ./my-bot --auto-restart --cmd "node index.js"
  deploy.sh stop ./my-bot
  deploy.sh status
  deploy.sh update ./my-bot
  deploy.sh check ./my-bot
USAGE
    exit 0
}

# ====== Utility Functions ======

# Resolve project directory to absolute path
resolve_project_dir() {
    local dir="$1"
    # If not absolute, try under workspace
    if [[ "$dir" != /* ]]; then
        if [[ -d "$WORKSPACE_DIR/$dir" ]]; then
            dir="$WORKSPACE_DIR/$dir"
        elif [[ -d "./$dir" ]]; then
            dir="$(cd "./$dir" && pwd)"
        fi
    fi
    # Ensure directory exists
    if [[ ! -d "$dir" ]]; then
        error "Project directory does not exist: $dir"
        exit 1
    fi
    echo "$(cd "$dir" && pwd)"
}

# Get deploy-state.json path
state_file() {
    echo "$1/.deploy-state.json"
}

# Read deployment state
read_state() {
    local sf
    sf="$(state_file "$1")"
    if [[ -f "$sf" ]]; then
        cat "$sf"
    else
        echo "{}"
    fi
}

# Write deployment state
write_state() {
    local project_dir="$1"
    local json="$2"
    echo "$json" | jq '.' > "$(state_file "$project_dir")"
}

# Get current git commit hash (short format)
get_current_commit() {
    local dir="$1"
    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get project name (directory name)
get_project_name() {
    basename "$1"
}

# Check if process is alive
is_pid_alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# Get ISO 8601 timestamp
iso_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ====== Command Implementations ======

# start - Mark project as deployed
cmd_start() {
    local project_dir=""
    local auto_restart=false
    local start_cmd="npm start"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-restart)
                auto_restart=true
                shift
                ;;
            --cmd)
                start_cmd="$2"
                shift 2
                ;;
            *)
                if [[ -z "$project_dir" ]]; then
                    project_dir="$1"
                else
                    error "Unknown argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$project_dir" ]]; then
        error "Please specify a project directory"
        echo "Usage: deploy.sh start <project_dir> [--auto-restart] [--cmd <command>]"
        exit 1
    fi

    project_dir="$(resolve_project_dir "$project_dir")"
    local name
    name="$(get_project_name "$project_dir")"
    local commit
    commit="$(get_current_commit "$project_dir")"
    local now
    now="$(iso_timestamp)"

    # Check for existing running deployment
    local existing_state
    existing_state="$(read_state "$project_dir")"
    if [[ "$existing_state" != "{}" ]]; then
        local existing_status
        existing_status="$(echo "$existing_state" | jq -r '.status // ""')"
        if [[ "$existing_status" == "running" ]]; then
            local existing_pid
            existing_pid="$(echo "$existing_state" | jq -r '.pid // 0')"
            if is_pid_alive "$existing_pid"; then
                warn "Project $name is already running (PID: $existing_pid)"
                echo "To redeploy, first run: deploy.sh stop $project_dir"
                exit 1
            fi
        fi
    fi

    # Start service in project directory
    info "Starting project: $name"
    info "Start command: $start_cmd"

    cd "$project_dir"
    # Background start with output redirected to log
    local pid_val
    nohup bash -c "$start_cmd" > "$project_dir/.deploy.log" 2>&1 &
    pid_val=$!

    # Wait briefly to confirm process started
    sleep 1
    if ! is_pid_alive "$pid_val"; then
        error "Process failed to start, check log: $project_dir/.deploy.log"
        exit 1
    fi

    # Write deployment state
    local state
    state="$(jq -n \
        --arg service "$name" \
        --arg status "running" \
        --argjson pid "$pid_val" \
        --arg start_command "$start_cmd" \
        --arg deployed_commit "$commit" \
        --arg deployed_at "$now" \
        --argjson auto_restart "$auto_restart" \
        '{
            service: $service,
            status: $status,
            pid: $pid,
            start_command: $start_command,
            deployed_commit: $deployed_commit,
            deployed_at: $deployed_at,
            auto_restart: $auto_restart,
            staging_commit: null
        }'
    )"
    write_state "$project_dir" "$state"

    log_msg "START $name (PID: $pid_val, commit: $commit)"
    ok "Project $name started (PID: $pid_val)"
}

# stop - Stop a deployed project
cmd_stop() {
    if [[ $# -lt 1 ]]; then
        error "Please specify a project directory"
        echo "Usage: deploy.sh stop <project_dir>"
        exit 1
    fi

    local project_dir
    project_dir="$(resolve_project_dir "$1")"
    local name
    name="$(get_project_name "$project_dir")"

    local state
    state="$(read_state "$project_dir")"
    if [[ "$state" == "{}" ]]; then
        error "Project $name has no deployment state"
        exit 1
    fi

    local pid_val
    pid_val="$(echo "$state" | jq -r '.pid // 0')"
    local status
    status="$(echo "$state" | jq -r '.status // "unknown"')"

    if [[ "$status" == "stopped" ]]; then
        warn "Project $name is already stopped"
        return
    fi

    # Terminate process
    if [[ "$pid_val" -gt 0 ]] && is_pid_alive "$pid_val"; then
        info "Stopping process (PID: $pid_val)..."
        kill "$pid_val" 2>/dev/null || true
        # Wait for process to exit
        local wait_count=0
        while is_pid_alive "$pid_val" && [[ $wait_count -lt 10 ]]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        # Force kill if still alive
        if is_pid_alive "$pid_val"; then
            warn "Process not responding to SIGTERM, sending SIGKILL..."
            kill -9 "$pid_val" 2>/dev/null || true
        fi
    fi

    # Update deployment state
    local updated
    updated="$(echo "$state" | jq '.status = "stopped" | .pid = 0')"
    write_state "$project_dir" "$updated"

    log_msg "STOP $name (was PID: $pid_val)"
    ok "Project $name stopped"
}

# status - View deployment status
cmd_status() {
    if [[ $# -gt 0 ]]; then
        # View specific project
        local project_dir
        project_dir="$(resolve_project_dir "$1")"
        show_project_status "$project_dir"
    else
        # View all projects
        info "Scanning workspace: $WORKSPACE_DIR"
        echo ""

        local found=false
        for sf in "$WORKSPACE_DIR"/*/.deploy-state.json; do
            [[ -f "$sf" ]] || continue
            found=true
            local dir
            dir="$(dirname "$sf")"
            show_project_status "$dir"
            echo ""
        done

        if [[ "$found" == false ]]; then
            echo "  No deployed projects found"
        fi
    fi
}

# Show single project status
show_project_status() {
    local project_dir="$1"
    local name
    name="$(get_project_name "$project_dir")"
    local state
    state="$(read_state "$project_dir")"

    if [[ "$state" == "{}" ]]; then
        echo -e "  ${CYAN}$name${NC}: no deployment record"
        return
    fi

    local status pid_val deployed_commit deployed_at auto_restart start_cmd
    status="$(echo "$state" | jq -r '.status // "unknown"')"
    pid_val="$(echo "$state" | jq -r '.pid // 0')"
    deployed_commit="$(echo "$state" | jq -r '.deployed_commit // "unknown"')"
    deployed_at="$(echo "$state" | jq -r '.deployed_at // "unknown"')"
    auto_restart="$(echo "$state" | jq -r '.auto_restart // false')"
    start_cmd="$(echo "$state" | jq -r '.start_command // ""')"

    # Check if process is actually alive
    local actual_status="$status"
    if [[ "$status" == "running" ]] && [[ "$pid_val" -gt 0 ]]; then
        if ! is_pid_alive "$pid_val"; then
            actual_status="dead"
        fi
    fi

    # Status color
    local status_color
    case "$actual_status" in
        running) status_color="$GREEN" ;;
        stopped) status_color="$YELLOW" ;;
        dead)    status_color="$RED" ;;
        *)       status_color="$NC" ;;
    esac

    # Check for code updates
    local current_commit
    current_commit="$(get_current_commit "$project_dir")"
    local code_changed=""
    if [[ "$current_commit" != "$deployed_commit" ]] && [[ "$current_commit" != "unknown" ]]; then
        code_changed=" ${YELLOW}(new code: $current_commit)${NC}"
    fi

    echo -e "  ${CYAN}$name${NC}"
    echo -e "    Status:       ${status_color}${actual_status}${NC}${code_changed}"
    echo -e "    PID:          $pid_val"
    echo -e "    Commit:       $deployed_commit"
    echo -e "    Deployed at:  $deployed_at"
    echo -e "    Auto-restart: $auto_restart"
    echo -e "    Start cmd:    $start_cmd"
}

# update - Deploy new code
cmd_update() {
    if [[ $# -lt 1 ]]; then
        error "Please specify a project directory"
        echo "Usage: deploy.sh update <project_dir>"
        exit 1
    fi

    local project_dir
    project_dir="$(resolve_project_dir "$1")"
    local name
    name="$(get_project_name "$project_dir")"

    local state
    state="$(read_state "$project_dir")"
    if [[ "$state" == "{}" ]]; then
        error "Project $name has no deployment state, run deploy.sh start first"
        exit 1
    fi

    local status start_cmd
    status="$(echo "$state" | jq -r '.status // "unknown"')"
    start_cmd="$(echo "$state" | jq -r '.start_command // "npm start"')"

    local current_commit
    current_commit="$(get_current_commit "$project_dir")"
    local now
    now="$(iso_timestamp)"

    if [[ "$status" == "running" ]]; then
        info "Project is running, stopping first..."
        cmd_stop "$project_dir"

        info "Updating deployment..."
        # Restart
        info "Restarting project: $name"
        cd "$project_dir"
        local pid_val
        nohup bash -c "$start_cmd" > "$project_dir/.deploy.log" 2>&1 &
        pid_val=$!

        sleep 1
        if ! is_pid_alive "$pid_val"; then
            error "Restart failed, check log: $project_dir/.deploy.log"
            # Update state to stopped
            local fail_state
            fail_state="$(echo "$state" | jq \
                --arg commit "$current_commit" \
                --arg time "$now" \
                '.status = "stopped" | .pid = 0 | .deployed_commit = $commit | .deployed_at = $time'
            )"
            write_state "$project_dir" "$fail_state"
            exit 1
        fi

        # Update state
        local new_state
        new_state="$(echo "$state" | jq \
            --arg commit "$current_commit" \
            --arg time "$now" \
            --argjson pid "$pid_val" \
            '.status = "running" | .pid = $pid | .deployed_commit = $commit | .deployed_at = $time | .staging_commit = null'
        )"
        write_state "$project_dir" "$new_state"

        log_msg "UPDATE $name (PID: $pid_val, commit: $current_commit)"
        ok "Project $name updated and restarted (PID: $pid_val)"

        # Send notification
        if [[ -x "$SCRIPT_DIR/notify.sh" ]]; then
            "$SCRIPT_DIR/notify.sh" deploy_done "Project $name deployed (commit: $current_commit)" || true
        fi
    else
        info "Project is stopped, updating state only..."
        local new_state
        new_state="$(echo "$state" | jq \
            --arg commit "$current_commit" \
            --arg time "$now" \
            '.deployed_commit = $commit | .deployed_at = $time | .staging_commit = null'
        )"
        write_state "$project_dir" "$new_state"

        log_msg "UPDATE(state-only) $name (commit: $current_commit)"
        ok "Deployment state updated (commit: $current_commit)"
    fi
}

# check - Check for available updates
cmd_check() {
    if [[ $# -lt 1 ]]; then
        error "Please specify a project directory"
        echo "Usage: deploy.sh check <project_dir>"
        exit 1
    fi

    local project_dir
    project_dir="$(resolve_project_dir "$1")"
    local name
    name="$(get_project_name "$project_dir")"

    local state
    state="$(read_state "$project_dir")"
    if [[ "$state" == "{}" ]]; then
        error "Project $name has no deployment state"
        exit 1
    fi

    local deployed_commit
    deployed_commit="$(echo "$state" | jq -r '.deployed_commit // "unknown"')"
    local current_commit
    current_commit="$(get_current_commit "$project_dir")"

    if [[ "$deployed_commit" == "$current_commit" ]]; then
        ok "Project $name is up to date (commit: $deployed_commit)"
        exit 0
    else
        warn "Project $name has available updates"
        echo "  Deployed: $deployed_commit"
        echo "  Latest:   $current_commit"
        exit 1
    fi
}

# ====== Main Entry ======
if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"
shift

case "$COMMAND" in
    start)   cmd_start "$@" ;;
    stop)    cmd_stop "$@" ;;
    status)  cmd_status "$@" ;;
    update)  cmd_update "$@" ;;
    check)   cmd_check "$@" ;;
    --help|-h) usage ;;
    *)
        error "Unknown command: $COMMAND"
        usage
        ;;
esac
