#!/bin/bash
# PKG_NAME: ssh-manager
# PKG_VERSION: 2.7.3
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), openssh-client, jq
# PKG_RECOMMENDS: sshpass, autossh, fzf
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Enhanced SSH connection manager with profiles and automation
# PKG_LONG_DESCRIPTION: Comprehensive SSH management tool for managing
#  multiple SSH connections, profiles, and automation tasks.
#  .
#  Features:
#  - Save and manage SSH connection profiles
#  - Quick connect to saved hosts
#  - SSH key management and generation
#  - Advanced port forwarding (Local, Remote, Dynamic/SOCKS)
#  - Auto-reconnect tunnels with autossh
#  - Connection logging and history
#  - Batch operations across multiple hosts
#  - JSON-based configuration
#  - Modular architecture for easy extension
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Enhanced SSH Manager
# Version: 2.6.2 - Replace pause_for_enter with pause_for_key (any key to continue)

# Get script directory for module loading
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
CONFIG_DIR="$HOME/.config/manzolo/ssh-manager"
# shellcheck disable=SC2034
export CONFIG_FILE="$CONFIG_DIR/config.json"
# shellcheck disable=SC2034
export LOG_FILE="$CONFIG_DIR/ssh-manager.log"
# shellcheck disable=SC2034
export VERSION="2.7.3"

# Source all modules
for module in "$SCRIPT_DIR/ssh-manager/"*.sh; do
    if [[ -f "$module" ]]; then
        # shellcheck source=/dev/null
        source "$module"
    fi
done

trap 'handle_interrupt' INT

# Main function
main() {
    # Check Bash version
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        print_message "$RED" "❌ Bash version 4 or higher required. Current version: $BASH_VERSION"
        exit 1
    fi
    
    # Check prerequisites
    if ! command -v dialog &> /dev/null; then
        print_message "$RED" "❌ Dialog is not installed. Run option 9 from the menu."
        echo "Do you want to install the prerequisites now? (Y/n)"
        read -r response
        if [[ -z "$response" || "$response" =~ ^[Yy]$ ]]; then
            install_prerequisites || exit 1
        else
            exit 1
        fi
    fi

    if ! command -v jq &> /dev/null; then
        print_message "$RED" "❌ jq is not installed. Run option 9 from the menu."
        echo "Do you want to install the prerequisites now? (Y/n)"
        read -r response
        if [[ -z "$response" || "$response" =~ ^[Yy]$ ]]; then
            install_prerequisites || exit 1
        else
            exit 1
        fi
    fi
    
    # Initialize configuration
    init_config
    
    # Log startup
    log_message "INFO" "SSH Manager started"
    
    # Start main menu
    main_menu
}

# Run if script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        -h|--help)
            echo "Usage: $(basename "$0") [OPTIONS] [CONNECTION-NAME]"
            echo ""
            echo "Interactive SSH connection manager with profiles and automation."
            echo ""
            echo "Options:"
            echo "  -h, --help         Show this help message and exit"
            echo ""
            echo "Commands:"
            echo "  list               List all saved connections"
            echo "  CONNECTION-NAME    Connect directly (partial match; fzf picker if ambiguous)"
            echo ""
            echo "Run without arguments to launch the interactive menu."
            exit 0
            ;;
        "")
            ;;
        list)
            if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then echo "Bash 4+ required." >&2; exit 1; fi
            init_config
            printf "%-24s %-30s %s\n" "NAME" "HOST" "DESCRIPTION"
            printf "%-24s %-30s %s\n" "----" "----" "-----------"
            jq -r '.servers[] | [
                .name,
                (.user + "@" + .host + ":" + (.port // 22 | tostring)),
                (.description // "")
            ] | @tsv' "$CONFIG_FILE" | \
                while IFS=$'\t' read -r name host desc; do
                    printf "%-24s %-30s %s\n" "$name" "$host" "$desc"
                done
            exit 0
            ;;
        *)
            if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
                echo "Bash 4+ required." >&2
                exit 1
            fi
            init_config
            _fuzzy_matches=$(find_server_fuzzy "$1")
            _fuzzy_status=$?
            case $_fuzzy_status in
                0)
                    execute_ssh_action "ssh" "$_fuzzy_matches"
                    exit $?
                    ;;
                1|2)
                    if command -v fzf >/dev/null 2>&1; then
                        _fzf_list=$(jq -r '.servers | to_entries[] |
                            "\(.key)\t\(.value.name)\t\(.value.user)@\(.value.host):\(.value.port // 22)\t\(.value.description // "")"' \
                            "$CONFIG_FILE")
                        _selected=$(echo "$_fzf_list" | fzf \
                            --delimiter=$'\t' \
                            --with-nth=2,3,4 \
                            --query="$1" \
                            --prompt="Connect to > " \
                            --height=40% \
                            --reverse \
                            --no-multi)
                        [[ -z "$_selected" ]] && exit 1
                        _sel_idx=$(echo "$_selected" | cut -f1)
                        execute_ssh_action "ssh" "$_sel_idx"
                        exit $?
                    elif [[ $_fuzzy_status -eq 1 ]]; then
                        echo "Connection '$1' not found. Use 'ssh-manager list' to see available connections." >&2
                        exit 1
                    else
                        echo "Multiple matches for '$1':" >&2
                        while IFS= read -r _idx; do
                            jq -r --argjson i "$_idx" '"  \(.servers[$i].name)  (\(.servers[$i].user)@\(.servers[$i].host))"' "$CONFIG_FILE" >&2
                        done <<< "$_fuzzy_matches"
                        echo "Please be more specific." >&2
                        exit 1
                    fi
                    ;;
            esac
            ;;
    esac
    main "$@"
fi
