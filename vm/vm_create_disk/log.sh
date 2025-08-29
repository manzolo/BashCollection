# Log levels: 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG
LOG_LEVEL=${LOG_LEVEL:-2}

log_debug() {
    [ "$LOG_LEVEL" -ge 3 ] && echo -e "${BLUE}[$(date '+%H:%M:%S')] [DEBUG]${NC} $1" >&2
}

log_info() {
    [ "$LOG_LEVEL" -ge 2 ] && echo -e "${BLUE}[$(date '+%H:%M:%S')] [INFO]${NC} $1"
}

log_warn() {
    [ "$LOG_LEVEL" -ge 1 ] && echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] [ERROR]${NC} $1" >&2
}

log_success() {
    [ "$LOG_LEVEL" -ge 2 ] && echo -e "${GREEN}[$(date '+%H:%M:%S')] [SUCCESS]${NC} $1"
}

# Backward compatibility aliases
log() { log_info "$1"; }
error() { log_error "$1"; }
warning() { log_warn "$1"; }
success() { log_success "$1"; }