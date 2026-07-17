# ───────────────────────────────
# Argument parsing
# ───────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run|-n)
                DRY_RUN=true
                echo -e "${CYAN}🧪 DRY RUN MODE ENABLED${NC}"
                ;;
            --help|-h)
                cat <<EOF
Manzolo Disk Cloner v2.4

Usage: $0 [OPTIONS]

Options:
  --dry-run, -n    Enable dry run mode (log commands without executing)
  --help, -h       Show this help message
EOF
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
        shift
    done
}

# ───────────────────────────────
# Root check
# ───────────────────────────────
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: This script requires root privileges${NC}"
        echo "Run with: sudo $0"
        exit 1
    fi
}

# ───────────────────────────────
# Dependency check
# ───────────────────────────────
check_dependencies() {
    for cmd in qemu-img dialog lsblk blockdev dd pv parted; do
        if ! command -v "$cmd" &> /dev/null; then
            log "Error: $cmd not found!"
            case $cmd in
                pv)      echo "Install with: sudo apt-get install pv" ;;
                parted)  echo "Install with: sudo apt-get install parted" ;;
                *)       echo "Install with: sudo apt-get install qemu-utils dialog" ;;
            esac
            exit 1
        fi
    done

    if command -v sgdisk &> /dev/null; then
        GPT_SUPPORT=true
        log "✅ GPT support enabled"
    else
        log "⚠️  GPT optimization disabled (install gdisk for better support)"
    fi
}