#!/bin/bash
# PKG_NAME: manzolo-backup-home
# PKG_VERSION: 2.2.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), rsync, coreutils, findutils
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Multi-directory rsync backup utility
# PKG_LONG_DESCRIPTION: Creates incremental backups for multiple directories
#  with verification, retention, compression options, and detailed logs.
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# ══════════════════════════════════════════════════════════════════════════════
# 🚀 ENHANCED MULTI-DIRECTORY BACKUP SCRIPT WITH RSYNC
# ══════════════════════════════════════════════════════════════════════════════
# Version: 2.1
# Author: Enhanced by Claude
# License: MIT
# Description: Professional backup solution with incremental backups,
#              error handling, notifications, and beautiful output
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'      # Secure Internal Field Separator

# ═══════════════════════════════════════════════════════════════════════════════
# 🎨 COLORS AND STYLING
# ═══════════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2034  # consumed by sourced modules
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
# shellcheck disable=SC2034  # consumed by sourced modules
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r PURPLE='\033[0;35m'
declare -r CYAN='\033[0;36m'
declare -r WHITE='\033[1;37m'
declare -r GRAY='\033[0;90m'
declare -r NC='\033[0m'

# Emoji and symbols
declare -r SUCCESS="✅"
# shellcheck disable=SC2034  # consumed by sourced modules
declare -r ERROR="❌"
declare -r WARNING="⚠️"
declare -r INFO="ℹ️"
declare -r ROCKET="🚀"
declare -r FOLDER="📁"
declare -r DISK="💾"
# shellcheck disable=SC2034  # consumed by sourced modules
declare -r CLOCK="⏰"
# shellcheck disable=SC2034  # consumed by sourced modules
declare -r STATS="📊"

# ═══════════════════════════════════════════════════════════════════════════════
# 📋 CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════
SCRIPT_NAME="$(basename "$0")"
# shellcheck disable=SC2034  # consumed by sourced modules
declare -r SCRIPT_NAME
# shellcheck disable=SC2034  # consumed by sourced modules
declare -r SCRIPT_VERSION="2.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_DIR
# shellcheck disable=SC2034  # consumed by sourced modules
declare -r LOG_DIR="/var/log/backup"
# shellcheck disable=SC2034  # consumed by sourced modules
declare -r CONFIG_FILE="$SCRIPT_DIR/backup.conf"

# Default configuration
declare -A CONFIG=(
    [max_backups]=1
    [compression]=true
    [notifications]=true
    [email_on_error]=""
    [bandwidth_limit]=""
    [parallel_jobs]=1
    [verify_integrity]=true
    [verify_method]="smart"
)

# Global variables
declare DEST_DISK=""
declare REAL_USER=""
declare DRY_RUN=false
declare VERBOSE=false
declare QUIET=false
declare FORCE=false
# shellcheck disable=SC2034  # --name flag declared but not yet wired into backup naming (TODO)
declare BACKUP_NAME=""
declare -a BACKUP_DIRS=("/etc" "/opt")
declare -a FAILED_BACKUPS=()
declare -a SUCCESS_BACKUPS=()

# ═══════════════════════════════════════════════════════════════════════════════
# 🛠️  UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# =================== MODULE LOADER ===================
# Implementation lives in manzolo-backup-home/*.sh. This script already
# defines SCRIPT_DIR (readonly, BASH_SOURCE-based) for config lookup, so
# the loader uses its own variable and resolves symlinks via readlink.
MODULE_DIR="$(dirname "$(readlink -f "$0")")/manzolo-backup-home"
readonly MODULE_DIR

for _module in "$MODULE_DIR/"*.sh; do
    if [ -f "$_module" ]; then
        # shellcheck disable=SC1090  # dynamic module loader
        source "$_module"
    else
        echo "Error: module $_module not found." >&2
        exit 1
    fi
done
unset _module

main() {
    local start_time
    start_time=$(date +%s)
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage 0
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            --name)
                # shellcheck disable=SC2034  # --name flag accepted but not yet wired into backup naming (TODO)
                BACKUP_NAME="$2"
                shift 2
                ;;
            --config)
                create_default_config
                exit 0
                ;;
            -*)
                log "ERROR" "Unknown option: $1"
                show_usage
                ;;
            *)
                if [ -z "$DEST_DISK" ]; then
                    DEST_DISK="$1"
                else
                    get_real_user "$1"
                fi
                shift
                ;;
        esac
    done
    
    # Validate arguments
    if [ -z "$DEST_DISK" ]; then
        log "ERROR" "Destination disk path required"
        show_usage
    fi
    
    # Initialize
    check_prerequisites "$@"
    load_config
    [ -z "$REAL_USER" ] && get_real_user
    
    # Verify destination
    if [ ! -d "$DEST_DISK" ]; then
        log "ERROR" "Destination '$DEST_DISK' does not exist or is not mounted"
        exit 1
    fi
    
    if [ ! -w "$DEST_DISK" ]; then
        log "ERROR" "No write permissions on '$DEST_DISK'"
        exit 1
    fi
    
    # Show system information
    [ "$QUIET" = false ] && show_system_info
    
    # Confirmation prompt - fixed alignment
    if [ "$FORCE" = false ] && [ "$DRY_RUN" = false ]; then
        echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC} ${WARNING} ${WHITE}BACKUP CONFIRMATION${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${FOLDER} Directories to backup: ${#BACKUP_DIRS[@]}"
        for dir in "${BACKUP_DIRS[@]}"; do
            local dir_display="$dir"
            if [ ${#dir_display} -gt 70 ]; then
                dir_display="...${dir_display: -67}"
            fi
            echo -e "${CYAN}║${NC}   • ${dir_display}"
        done
        echo -e "${CYAN}║${NC} ${DISK} Destination: ${DEST_DISK}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${WHITE}Continue with backup? [y/N]:${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo -ne "${WHITE}Your choice: ${NC}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log "INFO" "Backup cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    # Create exclude file
    local exclude_file
    exclude_file=$(mktemp)
    create_exclude_file "$exclude_file"
    
    # Cleanup function
    cleanup() {
        if [ -n "${exclude_file:-}" ]; then
            rm -f "$exclude_file"
        fi
    }
    trap cleanup EXIT
    
    # Build rsync options
    local rsync_options="-ahAXS --delete --delete-excluded --exclude-from=$exclude_file"
    
    if [ "${CONFIG[compression]}" = "true" ]; then
        rsync_options="$rsync_options -z"
    fi
    
    if [ -n "${CONFIG[bandwidth_limit]}" ]; then
        rsync_options="$rsync_options --bwlimit=${CONFIG[bandwidth_limit]}"
    fi
    
    if [ "$VERBOSE" = true ]; then
        rsync_options="$rsync_options --progress --stats"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        rsync_options="$rsync_options --dry-run"
        log "WARN" "DRY RUN MODE ENABLED - No files will be copied"
    fi
    
    # Perform backups
    local current=0
    local total=${#BACKUP_DIRS[@]}
    
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC} ${ROCKET} ${WHITE}BACKUP IN PROGRESS${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    
    for source_dir in "${BACKUP_DIRS[@]}"; do
        current=$((current + 1))
        
        # Get base name for display
        local base_name_dir
        base_name_dir=$(basename "$source_dir")
        
        echo -e "\n${BLUE}╭─────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "${BLUE}│${NC} ${FOLDER} ${WHITE}Processing:${NC} ${base_name_dir} (${current}/${total})"
        echo -e "${BLUE}│${NC} ${INFO} ${GRAY}Source:${NC} $source_dir"
        
        # Create destination path
        local base_name
        base_name=$(basename "$source_dir" | sed 's/\//_/g')
        [ "$base_name" = "" ] && base_name="root"
        
        local dest_dir="$DEST_DISK/backup_${base_name}"
        local log_file
        log_file="$dest_dir/backup_$(date +%Y%m%d_%H%M%S).log"
        
        echo -e "${BLUE}│${NC} ${DISK} ${GRAY}Destination:${NC} $dest_dir"
        echo -e "${BLUE}╰─────────────────────────────────────────────────────────────────────────────╯${NC}"
        
        # Create log directory
        mkdir -p "$dest_dir"
        
        # Perform backup
        perform_backup "$source_dir" "$dest_dir" "$log_file" "$DRY_RUN" "$rsync_options" "$exclude_file"
        
        # Cleanup old backups
        [ "$DRY_RUN" = false ] && cleanup_old_backups
        
        # Show completion for this directory
        echo -e "${GREEN}└─ ${SUCCESS} Backup completed for ${base_name_dir}${NC}\n"
    done
    
    # Show final statistics
    local end_time
    end_time=$(date +%s)
    [ "$QUIET" = false ] && show_final_stats "$start_time" "$end_time"
    
    # Send notifications
    if [ ${#FAILED_BACKUPS[@]} -gt 0 ]; then
        send_notification "Backup Completed with Errors" "Failed backups: ${FAILED_BACKUPS[*]}"
        exit 1
    else
        send_notification "Backup Completed Successfully" "All ${#SUCCESS_BACKUPS[@]} directories backed up successfully"
        log "SUCCESS" "All backups completed successfully!"
        exit 0
    fi
}

# Execute main function with all arguments
main "$@"
