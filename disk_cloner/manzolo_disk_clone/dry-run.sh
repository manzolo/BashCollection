dry_run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would execute: $*"
        return 0
    else
        log "Executing: $*"
        "$@"
        return $?
    fi
}

print_banner() {
    clear
    log "╔═══════════════════════════════════════╗"
    if [ "$DRY_RUN" = true ]; then
        log "║   🧪 Manzolo Disk Cloner v2.4 🧪      ║"
        log "║        DRY RUN MODE ENABLED          ║"
    else
        log "║   🚀 Manzolo Disk Cloner v2.4 🚀      ║"
    fi
    log "╚═══════════════════════════════════════╝"
}