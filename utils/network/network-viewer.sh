#!/bin/bash
# PKG_NAME: network-viewer
# PKG_VERSION: 1.0.3
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), iproute2, whiptail
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Interactive network configuration viewer
# PKG_LONG_DESCRIPTION: Display network interfaces, routes, subnets, and ARP
#  neighbors in a colored, human-readable format.
#  .
#  Features:
#  - Network interface table (IP, MAC, state, speed, type)
#  - IPv4 and IPv6 routing table with annotations
#  - Directly connected networks/subnets
#  - Route explanation for any IP or hostname
#  - Full network map piped to less
#  - Debug mode to trace all system commands
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

#===============================================================================
# NETWORK VIEWER
# Usage: network-viewer [--help|-h] [--explain <host>] [--debug]
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Colors ---
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'
readonly BOLD=$'\033[1m'

# --- Utility messages ---
msg_info() { echo -e "  ${BLUE}[i]${NC} $*" >&2; }
msg_ok()   { echo -e "  ${GREEN}[+]${NC} $*" >&2; }
msg_warn() { echo -e "  ${YELLOW}[!]${NC} $*" >&2; }
msg_err()  { echo -e "  ${RED}[x]${NC} $*" >&2; }

# --- Global state ---
DEBUG=false
SHOW_IPV6=false

# Open fd 3 as a persistent debug output channel pointing to the terminal.
# Unlike stderr, fd 3 is never redirected by callers (e.g. "$(run_cmd ... 2>/dev/null)"),
# so [CMD] lines are always visible even from inside command substitutions.
exec 3>&2

# --- Debug-aware command runner ---
run_cmd() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${CYAN}[CMD]${NC} $*" >&3
    fi
    "$@"
}

# --- Dependency check ---
check_dependencies() {
    local missing=()
    for cmd in ip whiptail; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_err "Missing required dependencies: ${missing[*]}"
        msg_info "Install with: sudo apt install iproute2 whiptail"
        exit 1
    fi

    # Optional dependencies — warn only
    for cmd in getent host; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_warn "Optional command not found: $cmd (hostname resolution may be limited)"
        fi
    done
}

# --- Usage ---
usage() {
    cat <<EOF

${BOLD}Network Viewer${NC} v1.0.1

Usage: $0 [options]

Options:
  --explain <ip|host>   Show route explanation for the given IP or hostname
  --ipv6                Include IPv6 addresses and routes (hidden by default)
  --debug               Enable debug mode (print each command before running)
  --help, -h            Show this help message

Without arguments: opens the interactive whiptail menu.

Examples:
  $0
  $0 --ipv6
  $0 --explain 8.8.8.8
  $0 --explain google.com --debug

EOF
    exit 0
}

# --- Source modules ---
_load_modules() {
    local mod_dir="${SCRIPT_DIR}/network-viewer"
    for module in ui.sh interfaces.sh routing.sh explain.sh map.sh; do
        local path="${mod_dir}/${module}"
        if [[ -f "$path" ]]; then
            # shellcheck source=/dev/null
            source "$path"
        else
            msg_err "Module not found: $path"
            exit 1
        fi
    done
}

# --- Main ---
main() {
    local explain_target=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)    usage ;;
            --debug)      DEBUG=true;     shift ;;
            --ipv6)       SHOW_IPV6=true; shift ;;
            --explain)
                [[ -z "${2:-}" ]] && { msg_err "--explain requires an argument"; exit 1; }
                explain_target="$2"
                shift 2
                ;;
            *)
                msg_err "Unknown option: $1"
                usage
                ;;
        esac
    done

    check_dependencies
    _load_modules

    if [[ -n "$explain_target" ]]; then
        # CLI mode: bypass menu
        explain_route_cli "$explain_target"
    else
        # Interactive menu
        run_menu
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
