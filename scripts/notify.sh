#!/usr/bin/env bash
# notify.sh - Telegram Bot Notification Script
# Send sync and deployment notifications via Telegram Bot API
set -euo pipefail

SYNC_HOME="$HOME/.claude-sync"
CONFIG_FILE="$SYNC_HOME/sync-config.json"

# ====== Help ======
usage() {
    cat <<'USAGE'
Usage: notify.sh <message_type> <message_body>

Send notifications via Telegram Bot API.

Message types:
  sync_push        Sync push successful
  sync_pull        Sync pull successful
  conflict         Conflict detected
  deploy_update    New code available for deploy
  deploy_done      Deployment complete
  error            Error occurred

Options:
  --help           Show this help

Examples:
  notify.sh sync_push "Pushed 3 file updates"
  notify.sh conflict "skills/web-search.md has a conflict"
  notify.sh error "git push failed: auth error"

Note:
  Requires bot_token and chat_id configured in sync-config.json.
  If not configured or enabled is false, the script exits silently.
USAGE
    exit 0
}

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
fi

# ====== Argument Check ======
if [[ $# -lt 2 ]]; then
    # Exit silently (may be called by other scripts)
    exit 0
fi

MSG_TYPE="$1"
MSG_BODY="$2"

# ====== Check Config ======

# If config file doesn't exist, exit silently
if [[ ! -f "$CONFIG_FILE" ]]; then
    exit 0
fi

# Read Telegram config
TELEGRAM_ENABLED="$(jq -r '.telegram.enabled // false' "$CONFIG_FILE" 2>/dev/null || echo "false")"
BOT_TOKEN="$(jq -r '.telegram.bot_token // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
CHAT_ID="$(jq -r '.telegram.chat_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"

# If not enabled or config incomplete, exit silently
if [[ "$TELEGRAM_ENABLED" != "true" ]] || [[ -z "$BOT_TOKEN" ]] || [[ -z "$CHAT_ID" ]]; then
    exit 0
fi

# ====== Read Machine Name ======
MACHINE_NAME="$(jq -r '.machine_name // "unknown"' "$CONFIG_FILE" 2>/dev/null || hostname -s)"

# ====== Build Message ======

# Choose icon and header based on message type
get_message_header() {
    case "$MSG_TYPE" in
        sync_push)
            echo "*[PUSH]* _${MACHINE_NAME}_"
            ;;
        sync_pull)
            echo "*[PULL]* _${MACHINE_NAME}_"
            ;;
        conflict)
            echo "*[CONFLICT]* _${MACHINE_NAME}_"
            ;;
        deploy_update)
            echo "*[DEPLOY]* _${MACHINE_NAME}_"
            ;;
        deploy_done)
            echo "*[DEPLOYED]* _${MACHINE_NAME}_"
            ;;
        error)
            echo "*[ERROR]* _${MACHINE_NAME}_"
            ;;
        *)
            echo "*[INFO]* _${MACHINE_NAME}_"
            ;;
    esac
}

# Build complete message (Markdown format)
build_message() {
    local header
    header="$(get_message_header)"
    local timestamp
    timestamp="$(date '+%H:%M:%S')"

    echo "${header}
${MSG_BODY}
_${timestamp}_"
}

# ====== Send Message ======
send_telegram() {
    local message
    message="$(build_message)"

    local api_url="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

    # Send via curl, 10s timeout, silent mode
    local response
    response="$(curl -s -m 10 -X POST "$api_url" \
        -d "chat_id=${CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" \
        -d "disable_web_page_preview=true" \
        2>/dev/null || echo '{"ok":false}')"

    # Check response (log only, don't exit)
    local ok_val
    ok_val="$(echo "$response" | jq -r '.ok // false' 2>/dev/null || echo "false")"
    if [[ "$ok_val" != "true" ]]; then
        # Log to file but don't output to terminal
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [notify] Send failed: $response" >> "$SYNC_HOME/sync.log" 2>/dev/null || true
    fi
}

# ====== Execute ======
send_telegram

exit 0
