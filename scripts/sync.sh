#!/usr/bin/env bash
# ==============================================================================
# sync.sh - Claude Code Configuration Sync Core Script
# ==============================================================================
# Purpose: Sync Claude Code configs, skills, and commands across multiple Macs
#          via Git
# Compat:  macOS (BSD commands), bash 3.2+
# Exit:    0=success, 1=error, 2=conflict
# ==============================================================================
set -euo pipefail

# ========================= Global Constants =========================

# Sync system root directory
SYNC_HOME="${HOME}/.claude-sync"
# Git repo local clone path
REPO_DIR="${SYNC_HOME}/repo"
# Sync operation log
SYNC_LOG="${SYNC_HOME}/sync.log"
# Conflict record log
CONFLICT_LOG="${SYNC_HOME}/conflict.log"
# Config file path
CONFIG_FILE="${SYNC_HOME}/sync-config.json"
# Ignore rules file
SYNCIGNORE_FILE="${SYNC_HOME}/.syncignore"
# Lock directory (macOS lacks flock, use mkdir for atomic locking)
LOCK_DIR="${SYNC_HOME}/.sync.lock"
# Max log size (10MB in bytes)
LOG_MAX_SIZE=10485760
# Log archive retention count
LOG_ARCHIVE_COUNT=10

# Claude Code source directories
CLAUDE_HOME="${HOME}/.claude"
AGENTS_HOME="${HOME}/.agents"

# Directory mappings for sync (source -> repo relative path)
# Format: "source_path:repo_path"
SYNC_DIRS=(
    "${CLAUDE_HOME}/skills:skills"
    "${CLAUDE_HOME}/commands:commands"
    "${CLAUDE_HOME}/agents:agents"
    "${CLAUDE_HOME}/plugins:plugins"
    "${AGENTS_HOME}/skills:agents-skills"
)

# Single file mappings for sync
SYNC_FILES=(
    "${CLAUDE_HOME}/settings.json:settings.json"
)

# ========================= Utility Functions =========================

# Get current machine name for log identification
get_machine_name() {
    # Prefer name from config file, fallback to hostname
    if [[ -f "${CONFIG_FILE}" ]] && command -v python3 &>/dev/null; then
        local name
        name=$(python3 -c "
import json, sys
try:
    with open('${CONFIG_FILE}') as f:
        cfg = json.load(f)
    print(cfg.get('machine_name', ''))
except:
    pass
" 2>/dev/null || true)
        if [[ -n "${name}" ]]; then
            echo "${name}"
            return
        fi
    fi
    hostname -s 2>/dev/null || echo "unknown"
}

# Get current timestamp
get_timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

# Read a field from config file
read_config() {
    local key="$1"
    local default="${2:-}"
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "${default}"
        return
    fi
    local value
    value=$(python3 -c "
import json, sys
try:
    with open('${CONFIG_FILE}') as f:
        cfg = json.load(f)
    keys = '${key}'.split('.')
    v = cfg
    for k in keys:
        v = v[k]
    print(v)
except:
    print('${default}')
" 2>/dev/null || echo "${default}")
    echo "${value}"
}

# Log rotation: archive sync.log when it exceeds 10MB
rotate_logs() {
    if [[ ! -f "${SYNC_LOG}" ]]; then
        return
    fi

    # macOS stat syntax: -f%z gets file size in bytes
    local file_size
    file_size=$(stat -f%z "${SYNC_LOG}" 2>/dev/null || echo 0)

    if (( file_size > LOG_MAX_SIZE )); then
        echo "[$(get_timestamp)] [SYSTEM] Log rotation: current size ${file_size} bytes" >> "${SYNC_LOG}"

        # Delete oldest archive
        if [[ -f "${SYNC_LOG}.${LOG_ARCHIVE_COUNT}" ]]; then
            rm -f "${SYNC_LOG}.${LOG_ARCHIVE_COUNT}"
        fi

        # Rename archive files (from high to low)
        local i
        for (( i = LOG_ARCHIVE_COUNT - 1; i >= 1; i-- )); do
            local next=$(( i + 1 ))
            if [[ -f "${SYNC_LOG}.${i}" ]]; then
                mv "${SYNC_LOG}.${i}" "${SYNC_LOG}.${next}"
            fi
        done

        # Current log becomes .1
        mv "${SYNC_LOG}" "${SYNC_LOG}.1"
        touch "${SYNC_LOG}"
    fi
}

# Write formatted operation log
# Args: $1=op_type(PUSH/PULL/ROLLBACK etc) $2=status(SUCCESS/FAILED/CONFLICT)
#       $3=details(multiline text, optional)
log_operation() {
    local op_type="$1"
    local status="$2"
    local details="${3:-}"
    local machine
    machine=$(get_machine_name)
    local timestamp
    timestamp=$(get_timestamp)

    # Check if rotation is needed
    rotate_logs

    {
        echo "[${timestamp}] [${op_type}] [${machine}]"
        if [[ -n "${details}" ]]; then
            # Indent each detail line with two spaces
            echo "${details}" | sed 's/^/  /'
        fi
        echo "  status:  ${status}"
        echo ""
    } >> "${SYNC_LOG}"
}

# Acquire lock (using mkdir atomic operation)
acquire_lock() {
    local max_wait=30
    local waited=0

    while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
        # Check if lock is stale (>5 minutes = deadlock)
        if [[ -f "${LOCK_DIR}/pid" ]]; then
            local lock_pid
            lock_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "")
            # Check if lock-holding process is still alive
            if [[ -n "${lock_pid}" ]] && ! kill -0 "${lock_pid}" 2>/dev/null; then
                echo "Detected dead lock (PID ${lock_pid} no longer exists), forcing release" >&2
                rm -rf "${LOCK_DIR}"
                continue
            fi

            # Check lock creation time
            local lock_time
            lock_time=$(stat -f%m "${LOCK_DIR}" 2>/dev/null || echo 0)
            local now
            now=$(date +%s)
            if (( now - lock_time > 300 )); then
                echo "Detected stale lock (>5 minutes), forcing release" >&2
                rm -rf "${LOCK_DIR}"
                continue
            fi
        fi

        if (( waited >= max_wait )); then
            echo "Error: Unable to acquire sync lock, timeout (${max_wait}s)" >&2
            return 1
        fi
        sleep 1
        (( waited++ ))
    done

    # Record current PID
    echo $$ > "${LOCK_DIR}/pid"
}

# Release lock
release_lock() {
    rm -rf "${LOCK_DIR}"
}

# Ensure lock is released on exit (trap mechanism)
cleanup_lock() {
    release_lock
}

# Resolve symlinks: copy actual file content instead of the link
# Args: $1=source_path $2=dest_path
resolve_symlinks() {
    local src="$1"
    local dest="$2"

    if [[ -L "${src}" ]]; then
        # Is a symlink, copy actual file content (not the link itself)
        local real_path
        # macOS readlink doesn't support -f, use python instead
        real_path=$(python3 -c "import os; print(os.path.realpath('${src}'))" 2>/dev/null)
        if [[ -f "${real_path}" ]]; then
            cp "${real_path}" "${dest}"
        elif [[ -d "${real_path}" ]]; then
            cp -R "${real_path}/" "${dest}/"
        fi
    elif [[ -f "${src}" ]]; then
        cp "${src}" "${dest}"
    elif [[ -d "${src}" ]]; then
        cp -R "${src}/" "${dest}/"
    fi
}

# Preload .syncignore patterns into array (read file only once)
IGNORE_PATTERNS=()
IGNORE_PATTERNS_LOADED=false

load_ignore_patterns() {
    if [[ "${IGNORE_PATTERNS_LOADED}" == "true" ]]; then
        return
    fi
    IGNORE_PATTERNS_LOADED=true

    if [[ ! -f "${SYNCIGNORE_FILE}" ]]; then
        return
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip empty lines and comments
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        # Trim whitespace (pure bash, no sed)
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue
        IGNORE_PATTERNS+=("${line}")
    done < "${SYNCIGNORE_FILE}"
}

# Check if a file is ignored by .syncignore
# Args: $1=relative_path
is_ignored() {
    local path="$1"

    # Ensure patterns are loaded
    load_ignore_patterns

    # Iterate preloaded patterns (pure memory operation, no subprocesses)
    local pattern
    for pattern in "${IGNORE_PATTERNS[@]}"; do
        # shellcheck disable=SC2254
        case "${path}" in
            ${pattern}) return 0 ;;
        esac
    done

    return 1
}

# Collect files to sync into the repo directory
# Returns changed file list (via global variable CHANGED_FILES)
collect_files() {
    CHANGED_FILES=()

    # Collect directories
    for mapping in "${SYNC_DIRS[@]}"; do
        local src_dir="${mapping%%:*}"
        local repo_subdir="${mapping##*:}"
        local repo_target="${REPO_DIR}/${repo_subdir}"

        if [[ ! -d "${src_dir}" ]]; then
            continue  # Source directory doesn't exist, skip
        fi

        # Ensure target directory exists in repo
        mkdir -p "${repo_target}"

        # Iterate files in source directory
        # macOS find compatible syntax, exclude large runtime directories
        while IFS= read -r -d '' src_file; do
            # Calculate relative path
            local rel_path="${src_file#${src_dir}/}"
            local full_rel="${repo_subdir}/${rel_path}"

            # Check if ignored
            if is_ignored "${full_rel}"; then
                continue
            fi

            local dest_file="${repo_target}/${rel_path}"
            local dest_dir
            dest_dir=$(dirname "${dest_file}")
            mkdir -p "${dest_dir}"

            # Resolve symlinks and copy
            resolve_symlinks "${src_file}" "${dest_file}"

            # Track changed files
            CHANGED_FILES+=("${full_rel}")
        done < <(find "${src_dir}" \
            -not -path "*/node_modules/*" \
            -not -path "*/.git/*" \
            -not -path "*/venv/*" \
            -not -path "*/.venv/*" \
            -not -path "*/__pycache__/*" \
            -not -path "*/cache/*" \
            -not -path "*/downloads/*" \
            -not -path "*/output/*" \
            -not -path "*/assets/*" \
            -not -path "*/dist/*" \
            -not -path "*/build/*" \
            -not -name ".DS_Store" \
            \( -type f -o -type l \) -print0 2>/dev/null)
    done

    # Collect individual files
    for mapping in "${SYNC_FILES[@]}"; do
        local src_file="${mapping%%:*}"
        local repo_file="${mapping##*:}"

        if [[ ! -f "${src_file}" ]] && [[ ! -L "${src_file}" ]]; then
            continue
        fi

        # Check if ignored
        if is_ignored "${repo_file}"; then
            continue
        fi

        local dest_file="${REPO_DIR}/${repo_file}"
        local dest_dir
        dest_dir=$(dirname "${dest_file}")
        mkdir -p "${dest_dir}"

        resolve_symlinks "${src_file}" "${dest_file}"
        CHANGED_FILES+=("${repo_file}")
    done
}

# Deploy files from repo to local target locations
deploy_files() {
    local deployed=()

    # Deploy directories
    for mapping in "${SYNC_DIRS[@]}"; do
        local target_dir="${mapping%%:*}"
        local repo_subdir="${mapping##*:}"
        local repo_source="${REPO_DIR}/${repo_subdir}"

        if [[ ! -d "${repo_source}" ]]; then
            continue
        fi

        mkdir -p "${target_dir}"

        # Iterate files in the repo subdirectory
        while IFS= read -r -d '' repo_file; do
            local rel_path="${repo_file#${repo_source}/}"
            local target_file="${target_dir}/${rel_path}"
            local target_file_dir
            target_file_dir=$(dirname "${target_file}")
            mkdir -p "${target_file_dir}"

            cp "${repo_file}" "${target_file}"
            deployed+=("${repo_subdir}/${rel_path}")
        done < <(find "${repo_source}" -type f -print0 2>/dev/null)
    done

    # Deploy individual files
    for mapping in "${SYNC_FILES[@]}"; do
        local target_file="${mapping%%:*}"
        local repo_file="${mapping##*:}"
        local source="${REPO_DIR}/${repo_file}"

        if [[ ! -f "${source}" ]]; then
            continue
        fi

        local target_dir
        target_dir=$(dirname "${target_file}")
        mkdir -p "${target_dir}"

        cp "${source}" "${target_file}"
        deployed+=("${repo_file}")
    done

    # Check skill dependencies
    check_deps

    echo "${deployed[*]:-}"
}

# Check skill dependencies (if deps.json exists)
check_deps() {
    local skills_dir="${REPO_DIR}/skills"
    if [[ ! -d "${skills_dir}" ]]; then
        return
    fi

    while IFS= read -r -d '' deps_file; do
        local skill_dir
        skill_dir=$(dirname "${deps_file}")
        local skill_name
        skill_name=$(basename "${skill_dir}")

        if ! python3 -c "
import json, sys, subprocess
try:
    with open('${deps_file}') as f:
        deps = json.load(f)
    missing = []
    for dep in deps.get('dependencies', []):
        name = dep.get('name', '')
        check = dep.get('check', '')
        if check:
            try:
                subprocess.run(check, shell=True, capture_output=True, check=True)
            except subprocess.CalledProcessError:
                missing.append(name)
    if missing:
        print(f'Warning: skill {skill_name} missing dependencies: {', '.join(missing)}', file=sys.stderr)
        sys.exit(1)
except json.JSONDecodeError:
    print(f'Warning: {deps_file} has invalid format', file=sys.stderr)
except Exception as e:
    pass
" 2>&1; then
            echo "  [Dep Check] Skill '${skill_name}' has unmet dependencies" >&2
        fi
    done < <(find "${skills_dir}" -name "deps.json" -print0 2>/dev/null)
}

# Send Telegram notification (calls notify.sh)
notify_telegram() {
    local message="$1"
    local enabled
    enabled=$(read_config "telegram.enabled" "false")

    if [[ "${enabled}" != "true" ]]; then
        return
    fi

    local notify_script
    notify_script="$(dirname "$0")/notify.sh"
    if [[ -x "${notify_script}" ]]; then
        "${notify_script}" "${message}" &>/dev/null &
    fi
}

# ========================= Command Implementations =========================

# -------- init: Initialize sync system --------
cmd_init() {
    echo "Initializing Claude Code sync system..."

    # Create directory structure
    mkdir -p "${SYNC_HOME}"
    mkdir -p "${REPO_DIR}"

    # Get Git remote URL
    local git_remote
    git_remote=$(read_config "git.remote" "")

    if [[ -z "${git_remote}" ]]; then
        echo "Error: Git remote URL not configured" >&2
        echo "Please set the git.remote field in ${CONFIG_FILE}" >&2
        echo "Example:" >&2
        echo '  {"git": {"remote": "git@github.com:YOUR_GITHUB_USER/claude-sync.git"}}' >&2
        return 1
    fi

    # Clone or update repo
    if [[ -d "${REPO_DIR}/.git" ]]; then
        echo "Repository exists, updating..."
        cd "${REPO_DIR}"
        git pull --rebase 2>&1 || true
    else
        echo "Cloning repository: ${git_remote}"
        # Clear REPO_DIR if non-empty
        rm -rf "${REPO_DIR}"
        git clone "${git_remote}" "${REPO_DIR}" 2>&1
    fi

    # Create log files
    touch "${SYNC_LOG}"
    touch "${CONFLICT_LOG}"

    # Copy .syncignore template (if provided in project)
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    local project_syncignore="${script_dir}/../templates/.syncignore"
    if [[ -f "${project_syncignore}" ]] && [[ ! -f "${SYNCIGNORE_FILE}" ]]; then
        cp "${project_syncignore}" "${SYNCIGNORE_FILE}"
        echo "Copied .syncignore template"
    elif [[ ! -f "${SYNCIGNORE_FILE}" ]]; then
        # Create default .syncignore
        cat > "${SYNCIGNORE_FILE}" << 'IGNORE_EOF'
# Claude Sync ignore rules
# One glob pattern per line

# Temporary files
*.tmp
*.swp
*.bak

# Machine-specific plugin configs
plugins/*.local.*

# macOS system files
.DS_Store
IGNORE_EOF
        echo "Created default .syncignore"
    fi

    # Ensure base directory structure in repo
    cd "${REPO_DIR}"
    mkdir -p skills commands agents plugins agents-skills
    if [[ ! -f "${REPO_DIR}/.gitkeep" ]]; then
        touch skills/.gitkeep commands/.gitkeep agents/.gitkeep plugins/.gitkeep agents-skills/.gitkeep
        git add -A 2>/dev/null || true
        git diff --cached --quiet 2>/dev/null || git commit -m "Initialize directory structure" 2>/dev/null || true
    fi

    local machine
    machine=$(get_machine_name)
    log_operation "INIT" "SUCCESS" "machine: ${machine}\nrepo:    ${git_remote}"

    echo ""
    echo "Initialization complete!"
    echo "  Sync dir:  ${SYNC_HOME}"
    echo "  Repo path: ${REPO_DIR}"
    echo "  Machine:   ${machine}"
    echo ""

    notify_telegram "Claude Sync initialized [${machine}]"
}

# -------- push: Push local changes to remote --------
cmd_push() {
    echo "Collecting local config files..."

    # Check if repo is initialized
    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        echo "Error: Sync system not initialized, run sync.sh init first" >&2
        return 1
    fi

    acquire_lock
    trap cleanup_lock EXIT

    # Collect files
    collect_files

    if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
        echo "No files found to sync"
        log_operation "PUSH" "SUCCESS" "changed: (no files)"
        release_lock
        trap - EXIT
        return 0
    fi

    # Enter repo directory for Git operations
    cd "${REPO_DIR}"

    # Clean nested .git directories (avoid submodule issues)
    find "${REPO_DIR}" -mindepth 2 -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true

    # Stage all changes
    git add -A

    # Check for actual changes
    if git diff --cached --quiet 2>/dev/null; then
        echo "All files are up to date, nothing to push"
        log_operation "PUSH" "SUCCESS" "changed: (no diff)"
        release_lock
        trap - EXIT
        return 0
    fi

    # Generate change details (limit to 20 files)
    local details=""
    local diff_names
    diff_names=$(git diff --cached --name-only 2>/dev/null || true)
    if [[ -n "${diff_names}" ]]; then
        local line_count=0
        while IFS= read -r fname; do
            [[ -z "${fname}" ]] && continue
            details="${details}changed: ${fname}\n"
            line_count=$((line_count + 1))
            if (( line_count >= 20 )); then
                details="${details}... (more files omitted)\n"
                break
            fi
        done <<< "${diff_names}"
    fi

    # Build commit message
    local machine
    machine=$(get_machine_name)
    local changed_summary
    local all_changed_files
    all_changed_files=$(git diff --cached --name-only 2>/dev/null || true)
    # Avoid pipe SIGPIPE: store in variable first
    local total_changed=0
    if [[ -n "${all_changed_files}" ]]; then
        total_changed=$(printf '%s\n' "${all_changed_files}" | wc -l | tr -d ' ')
        # Take first 5 filenames, comma-separated
        changed_summary=$(printf '%s\n' "${all_changed_files}" | awk 'NR<=5' | tr '\n' ',' | sed 's/,$//')
    else
        changed_summary="(none)"
    fi

    local commit_msg="[${machine}] sync ${total_changed} files: ${changed_summary}"

    # Commit
    if ! git commit -m "${commit_msg}" 2>&1; then
        log_operation "PUSH" "FAILED" "error: git commit failed"
        echo "Error: Commit failed" >&2
        release_lock
        trap - EXIT
        return 1
    fi

    local commit_hash
    commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # Push
    if ! git push 2>&1; then
        log_operation "PUSH" "FAILED" "${details}commit:  ${commit_hash}\nerror:   git push failed"
        echo "Error: Push failed, you may need to pull first" >&2
        release_lock
        trap - EXIT
        return 1
    fi

    # Log success
    log_operation "PUSH" "SUCCESS" "${details}commit:  ${commit_hash}"

    echo ""
    echo "Push successful!"
    echo "  Commit: ${commit_hash}"
    echo "  Files:  ${total_changed}"

    notify_telegram "PUSH success [${machine}] ${total_changed} files, commit: ${commit_hash}"

    release_lock
    trap - EXIT
}

# -------- pull: Pull remote changes and deploy locally --------
cmd_pull() {
    echo "Pulling remote changes..."

    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        echo "Error: Sync system not initialized, run sync.sh init first" >&2
        return 1
    fi

    acquire_lock
    trap cleanup_lock EXIT

    cd "${REPO_DIR}"

    # Stash local uncommitted changes if any
    local had_stash=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git stash push -m "sync-pull-autostash" 2>/dev/null || true
        had_stash=true
    fi

    # Pull remote changes
    local pull_output
    local pull_exit=0
    pull_output=$(git pull 2>&1) || pull_exit=$?

    # Check for conflicts
    if [[ ${pull_exit} -ne 0 ]]; then
        # Check if it's a merge conflict
        local conflict_files
        conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")

        if [[ -n "${conflict_files}" ]]; then
            echo "Merge conflict detected!" >&2
            echo ""

            local conflict_details=""
            while IFS= read -r cfile; do
                [[ -z "${cfile}" ]] && continue

                # Keep local version as the active version
                git checkout --ours -- "${cfile}" 2>/dev/null || true

                # Save remote version as .conflict file
                git show ":3:${cfile}" > "${REPO_DIR}/${cfile}.conflict" 2>/dev/null || true

                conflict_details="${conflict_details}conflict: ${cfile}\n"
                echo "  Conflict: ${cfile}"
                echo "    Local version:  ${cfile} (kept)"
                echo "    Remote version: ${cfile}.conflict"

                # Log to conflict log
                {
                    echo "[$(get_timestamp)] Conflict: ${cfile}"
                    echo "  Local version kept, remote saved as ${cfile}.conflict"
                    echo ""
                } >> "${CONFLICT_LOG}"
            done <<< "${conflict_files}"

            # Mark conflicts as resolved (using local version)
            git add -A 2>/dev/null || true
            git commit -m "Resolve conflict: keep local version" 2>/dev/null || true

            log_operation "PULL" "CONFLICT" "${conflict_details}"

            echo ""
            echo "Local version kept, remote versions saved as .conflict files"
            echo "Use 'sync.sh resolve <file>' to resolve conflicts"

            # Restore stash
            if [[ "${had_stash}" == "true" ]]; then
                git stash pop 2>/dev/null || true
            fi

            release_lock
            trap - EXIT
            return 2  # Conflict exit code
        else
            # Other errors
            log_operation "PULL" "FAILED" "error: ${pull_output}"
            echo "Error: Pull failed" >&2
            echo "${pull_output}" >&2

            if [[ "${had_stash}" == "true" ]]; then
                git stash pop 2>/dev/null || true
            fi

            release_lock
            trap - EXIT
            return 1
        fi
    fi

    # Restore stash
    if [[ "${had_stash}" == "true" ]]; then
        git stash pop 2>/dev/null || true
    fi

    # Deploy files locally
    echo "Deploying files to local..."
    local deployed
    deployed=$(deploy_files)

    # Get change details
    local details=""
    local recent_log
    recent_log=$(git log -1 --pretty=format:"%h %s" 2>/dev/null || echo "")
    if [[ -n "${recent_log}" ]]; then
        details="latest:  ${recent_log}\n"
    fi
    if [[ -n "${deployed}" ]]; then
        details="${details}deployed: ${deployed}\n"
    fi

    local commit_hash
    commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    details="${details}commit:  ${commit_hash}"

    log_operation "PULL" "SUCCESS" "${details}"

    echo ""
    echo "Pull and deploy successful!"
    echo "  Version: ${commit_hash}"

    local machine
    machine=$(get_machine_name)
    notify_telegram "PULL success [${machine}] version: ${commit_hash}"

    release_lock
    trap - EXIT
}

# -------- status: Show sync status --------
cmd_status() {
    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        echo "Sync system not initialized"
        echo "Run 'sync.sh init' to initialize"
        return 0
    fi

    local machine
    machine=$(get_machine_name)
    echo "Claude Code Sync Status"
    echo "======================="
    echo "Machine: ${machine}"
    echo ""

    # Recent push/pull records
    echo "--- Recent Operations ---"
    if [[ -f "${SYNC_LOG}" ]]; then
        # Show recent PUSH operation
        local last_push
        last_push=$(grep -A 3 "\[PUSH\]" "${SYNC_LOG}" 2>/dev/null | tail -8 || echo "(no records)")
        echo "Last push:"
        echo "${last_push}" | head -4

        echo ""

        # Show recent PULL operation
        local last_pull
        last_pull=$(grep -A 3 "\[PULL\]" "${SYNC_LOG}" 2>/dev/null | tail -8 || echo "(no records)")
        echo "Last pull:"
        echo "${last_pull}" | head -4
    else
        echo "(no operation log)"
    fi

    echo ""

    # Local pending changes
    echo "--- Local Changes ---"
    # Collect files to repo first
    collect_files 2>/dev/null

    cd "${REPO_DIR}"
    local local_diff
    local_diff=$(git diff --stat 2>/dev/null || echo "")
    local staged_diff
    staged_diff=$(git diff --cached --stat 2>/dev/null || echo "")

    if [[ -n "${local_diff}" ]] || [[ -n "${staged_diff}" ]]; then
        echo "Unpushed local changes:"
        [[ -n "${local_diff}" ]] && echo "${local_diff}"
        [[ -n "${staged_diff}" ]] && echo "${staged_diff}"
    else
        echo "(no local changes)"
    fi

    echo ""

    # Remote available changes
    echo "--- Remote Changes ---"
    git fetch --quiet 2>/dev/null || true
    local remote_diff
    remote_diff=$(git log HEAD..origin/HEAD --oneline 2>/dev/null || \
                  git log HEAD..origin/main --oneline 2>/dev/null || \
                  git log HEAD..origin/master --oneline 2>/dev/null || \
                  echo "")

    if [[ -n "${remote_diff}" ]]; then
        echo "Available remote changes:"
        echo "${remote_diff}"
    else
        echo "(no remote changes)"
    fi

    echo ""

    # Unresolved conflicts
    echo "--- Conflict Status ---"
    local conflict_count=0
    while IFS= read -r -d '' cfile; do
        if [[ "${cfile}" == *.conflict ]]; then
            echo "  Unresolved: ${cfile}"
            (( conflict_count++ ))
        fi
    done < <(find "${REPO_DIR}" -name "*.conflict" -print0 2>/dev/null)

    if (( conflict_count == 0 )); then
        echo "(no unresolved conflicts)"
    else
        echo ""
        echo "Total ${conflict_count} unresolved conflicts"
    fi
}

# -------- log: View change history --------
cmd_log() {
    local skill_name="${1:-}"

    if [[ -z "${skill_name}" ]]; then
        # No args: show recent 50 sync log entries
        echo "Recent sync log (up to 50 entries):"
        echo "===================================="
        if [[ -f "${SYNC_LOG}" ]]; then
            tail -n 200 "${SYNC_LOG}" | head -n 200
        else
            echo "(log file does not exist)"
        fi
    else
        # With args: show Git history for specified skill/file
        if [[ ! -d "${REPO_DIR}/.git" ]]; then
            echo "Error: Sync system not initialized" >&2
            return 1
        fi

        cd "${REPO_DIR}"

        # Try multiple possible paths
        local search_paths=(
            "skills/${skill_name}"
            "commands/${skill_name}"
            "agents/${skill_name}"
            "plugins/${skill_name}"
            "agents-skills/${skill_name}"
            "${skill_name}"
        )

        local found=false
        for search_path in "${search_paths[@]}"; do
            if [[ -e "${REPO_DIR}/${search_path}" ]]; then
                echo "Change history: ${search_path}"
                echo "===================================="
                git log --oneline --follow -20 -- "${search_path}" 2>/dev/null
                found=true
                break
            fi
        done

        if [[ "${found}" == "false" ]]; then
            echo "Not found: ${skill_name}" >&2
            echo "Searching..."
            # Try fuzzy search
            local matches
            matches=$(find "${REPO_DIR}" -name "*${skill_name}*" -not -path "*/.git/*" 2>/dev/null | head -10)
            if [[ -n "${matches}" ]]; then
                echo "Possible matches:"
                echo "${matches}" | sed "s|${REPO_DIR}/|  |g"
            else
                echo "No matching files or directories found"
            fi
            return 1
        fi
    fi
}

# -------- rollback: Rollback a file to a specific version --------
cmd_rollback() {
    local target_path="${1:-}"
    local commit_hash="${2:-}"

    if [[ -z "${target_path}" ]] || [[ -z "${commit_hash}" ]]; then
        echo "Usage: sync.sh rollback <file_path> <commit_hash>" >&2
        echo "Example: sync.sh rollback skills/my-skill/skill.md a3f8c2d" >&2
        return 1
    fi

    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        echo "Error: Sync system not initialized" >&2
        return 1
    fi

    acquire_lock
    trap cleanup_lock EXIT

    cd "${REPO_DIR}"

    # Validate commit hash
    if ! git cat-file -t "${commit_hash}" &>/dev/null; then
        echo "Error: Invalid commit hash '${commit_hash}'" >&2
        release_lock
        trap - EXIT
        return 1
    fi

    # Verify file exists in that commit
    if ! git show "${commit_hash}:${target_path}" &>/dev/null; then
        echo "Error: File '${target_path}' not found in commit ${commit_hash}" >&2
        release_lock
        trap - EXIT
        return 1
    fi

    echo "Rolling back: ${target_path} -> ${commit_hash}"

    # Checkout file from specified commit
    git checkout "${commit_hash}" -- "${target_path}" 2>&1

    # Commit the rollback
    local machine
    machine=$(get_machine_name)
    git add "${target_path}"
    git commit -m "[${machine}] rollback ${target_path} to ${commit_hash}" 2>&1

    # Deploy rolled-back file locally
    deploy_files

    # Push
    git push 2>&1 || true

    local new_commit
    new_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    log_operation "ROLLBACK" "SUCCESS" "file:    ${target_path}\nfrom:    ${commit_hash}\ncommit:  ${new_commit}"

    echo ""
    echo "Rollback successful!"
    echo "  File:        ${target_path}"
    echo "  Rolled back: ${commit_hash}"
    echo "  New commit:  ${new_commit}"

    notify_telegram "ROLLBACK [${machine}] ${target_path} -> ${commit_hash}"

    release_lock
    trap - EXIT
}

# -------- resolve: Resolve conflicts --------
cmd_resolve() {
    local conflict_file="${1:-}"
    local strategy="${2:---keep-local}"  # Default: keep local

    if [[ -z "${conflict_file}" ]]; then
        echo "Usage: sync.sh resolve <conflict_file> [--keep-local|--keep-remote|--manual]" >&2
        echo ""
        echo "Options:"
        echo "  --keep-local   Keep local version (default)"
        echo "  --keep-remote  Use remote version"
        echo "  --manual       Manual resolve (only remove .conflict marker)"
        echo ""

        # List all unresolved conflicts
        if [[ -d "${REPO_DIR}" ]]; then
            echo "Current unresolved conflicts:"
            local found_any=false
            while IFS= read -r -d '' cfile; do
                echo "  ${cfile#${REPO_DIR}/}"
                found_any=true
            done < <(find "${REPO_DIR}" -name "*.conflict" -print0 2>/dev/null)
            if [[ "${found_any}" == "false" ]]; then
                echo "  (no conflicts)"
            fi
        fi
        return 1
    fi

    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        echo "Error: Sync system not initialized" >&2
        return 1
    fi

    acquire_lock
    trap cleanup_lock EXIT

    cd "${REPO_DIR}"

    # Determine conflict file path
    local conflict_path="${conflict_file}"
    # If no .conflict suffix, try to find the corresponding conflict file
    if [[ ! "${conflict_path}" == *.conflict ]]; then
        conflict_path="${conflict_file}.conflict"
    fi

    # Check if conflict file exists in repo
    local full_conflict_path="${REPO_DIR}/${conflict_path}"
    if [[ ! -f "${full_conflict_path}" ]]; then
        echo "Error: Conflict file '${conflict_path}' not found" >&2
        echo "Use 'sync.sh resolve' (no args) to list all conflicts" >&2
        release_lock
        trap - EXIT
        return 1
    fi

    # Original file path (without .conflict suffix)
    local original_path="${conflict_path%.conflict}"
    local full_original_path="${REPO_DIR}/${original_path}"

    case "${strategy}" in
        --keep-local)
            echo "Keeping local version: ${original_path}"
            # Local version is already in place, just remove .conflict file
            rm -f "${full_conflict_path}"
            ;;
        --keep-remote)
            echo "Using remote version: ${original_path}"
            # Replace original with .conflict file
            if [[ -f "${full_conflict_path}" ]]; then
                mv "${full_conflict_path}" "${full_original_path}"
            fi
            ;;
        --manual)
            echo "Manual resolve mode: please edit ${original_path}"
            echo "Run resolve again when done to clean up .conflict file"
            # Only remove .conflict marker file
            rm -f "${full_conflict_path}"
            ;;
        *)
            echo "Error: Unknown strategy '${strategy}'" >&2
            echo "Options: --keep-local, --keep-remote, --manual" >&2
            release_lock
            trap - EXIT
            return 1
            ;;
    esac

    # Commit the resolution
    git add -A 2>/dev/null
    local machine
    machine=$(get_machine_name)
    git commit -m "[${machine}] resolve conflict: ${original_path} (${strategy})" 2>/dev/null || true
    git push 2>/dev/null || true

    # Deploy locally
    deploy_files

    # Log
    log_operation "RESOLVE" "SUCCESS" "file:     ${original_path}\nstrategy: ${strategy}"

    # Log to conflict log
    {
        echo "[$(get_timestamp)] Conflict resolved: ${original_path}"
        echo "  Strategy: ${strategy}"
        echo ""
    } >> "${CONFLICT_LOG}"

    echo ""
    echo "Conflict resolved: ${original_path}"
    echo "  Strategy: ${strategy}"

    notify_telegram "Conflict resolved [${machine}] ${original_path} (${strategy})"

    release_lock
    trap - EXIT
}

# ========================= Main Entry =========================

# Show help
show_help() {
    cat << 'HELP_EOF'
Claude Code Configuration Sync Tool

Usage: sync.sh <command> [args]

Commands:
  init                              Initialize sync system (clone repo, create dirs)
  push                              Push local config changes to remote
  pull                              Pull remote changes and deploy locally
  status                            Show sync status
  log [skill_name]                  View sync log or change history for a skill
  rollback <file_path> <commit>     Rollback a file to a specific version
  resolve <conflict_file> [strategy] Resolve conflict (--keep-local/--keep-remote/--manual)
  help                              Show this help

Exit codes:
  0  Success
  1  Error
  2  Conflict (during pull)

Config: ~/.claude-sync/sync-config.json
Log:    ~/.claude-sync/sync.log

HELP_EOF
}

# Parse command line args
main() {
    local command="${1:-help}"
    shift || true

    case "${command}" in
        init)
            cmd_init "$@"
            ;;
        push)
            cmd_push "$@"
            ;;
        pull)
            cmd_pull "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        log)
            cmd_log "$@"
            ;;
        rollback)
            cmd_rollback "$@"
            ;;
        resolve)
            cmd_resolve "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "Error: Unknown command '${command}'" >&2
            echo "Run 'sync.sh help' for usage" >&2
            exit 1
            ;;
    esac
}

main "$@"
