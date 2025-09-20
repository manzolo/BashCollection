# -------------------- LOGGING SETUP --------------------
LOGFILE="/var/log/clone_script.log"
if ! touch "$LOGFILE" 2>/dev/null; then
    LOGFILE="$(pwd)/clone_script.log"
fi
chmod 600 "$LOGFILE" 2>/dev/null || true

# Preserve original terminal fds
exec 3>&1 4>&2

log() {
    local ts
    ts="$(date '+%F %T')"
    printf '%s %s\n' "$ts" "$*" | tee -a "$LOGFILE" >&3
}

# 1. Improved error handling and logging
log_with_level() {
    local level="$1"
    shift
    local message="$*"
    local ts="$(date '+%F %T')"
    
    case "$level" in
        ERROR)
            printf '%s [ERROR] %s\n' "$ts" "$message" | tee -a "$LOGFILE" >&3
            ;;
        WARN)
            printf '%s [WARN]  %s\n' "$ts" "$message" | tee -a "$LOGFILE" >&3
            ;;
        INFO)
            printf '%s [INFO]  %s\n' "$ts" "$message" | tee -a "$LOGFILE" >&3
            ;;
        DEBUG)
            if [ "${DEBUG:-false}" = true ]; then
                printf '%s [DEBUG] %s\n' "$ts" "$message" | tee -a "$LOGFILE" >&3
            fi
            ;;
    esac
}

run_log() {
    if [ $# -eq 0 ]; then return 1; fi
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would execute: $*"
        return 0
    fi
    
    if [ $# -eq 1 ]; then
        bash -c "set -o pipefail; $1" > >(tee -a "$LOGFILE" >&3) 2> >(tee -a "$LOGFILE" >&4)
        return $?
    else
        "$@" > >(tee -a "$LOGFILE" >&3) 2> >(tee -a "$LOGFILE" >&4)
        return $?
    fi
}