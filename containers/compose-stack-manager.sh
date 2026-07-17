#!/bin/bash
# PKG_NAME: compose-stack-manager
# PKG_VERSION: 1.1.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), docker-ce
# PKG_RECOMMENDS: docker-compose-plugin
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Docker Compose stack monitor and updater with ASCII dashboard

set -uo pipefail

# shellcheck disable=SC2034  # consumed by sourced modules
readonly VERSION="1.1.0"
SCRIPT_NAME="$(basename "$0")"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly SCRIPT_NAME

# shellcheck disable=SC2034  # consumed by sourced modules
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
# shellcheck disable=SC2034  # consumed by sourced modules
readonly BLUE='\033[0;34m'
# shellcheck disable=SC2034  # consumed by sourced modules
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# shellcheck disable=SC2034  # consumed by sourced modules
readonly STATUS_RUNNING="running"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly STATUS_WARN="warning"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly STATUS_STOPPED="stopped"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly STATUS_ERROR="error"

# shellcheck disable=SC2034  # consumed by sourced modules
readonly UPDATE_UPDATED="updated"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly UPDATE_UNCHANGED="unchanged"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly UPDATE_FAILED="failed"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly UPDATE_SKIPPED="skipped"

# shellcheck disable=SC2034  # consumed by sourced modules
readonly MAX_HOST_PORTS_WIDTH=18
# shellcheck disable=SC2034  # consumed by sourced modules
readonly MAX_INTERNAL_PORTS_WIDTH=24

# shellcheck disable=SC2034  # consumed by sourced modules
readonly COMPOSE_FILES=(
    "docker-compose.yml"
    "docker-compose.yaml"
    "compose.yml"
    "compose.yaml"
)

MODE="check"
INTERACTIVE=false
START_DIR="$(pwd)"
HAS_PYTHON3=false
# shellcheck disable=SC2034  # consumed by sourced modules
LOG_ERRORS=()

# shellcheck disable=SC2034  # consumed by sourced modules
STACK_DIRS=()
# shellcheck disable=SC2034  # consumed by sourced modules
STACK_FILES=()
# shellcheck disable=SC2034  # consumed by sourced modules
STACK_LABELS=()

# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_STACK_NAMES=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_STACK_ROWS=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_STACK_WIDTH_SERVICE=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_STACK_WIDTH_STATUS=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_STACK_WIDTH_HOST_PORTS=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_STACK_WIDTH_INTERNAL_PORTS=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_STACK_WIDTH_IMAGE=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_SERVICES=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_STATUSES=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_STATUS_KINDS=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_HOST_PORTS=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_INTERNAL_PORTS=()
# shellcheck disable=SC2034  # consumed by sourced modules
CHECK_IMAGES=()

# shellcheck disable=SC2034  # consumed by sourced modules
UPDATE_STACKS=()
# shellcheck disable=SC2034  # consumed by sourced modules
UPDATE_RESULTS=()
# shellcheck disable=SC2034  # consumed by sourced modules
UPDATE_DETAILS=()

# =================== MODULE LOADER ===================
# Implementation lives in compose-stack-manager/*.sh. Resolve symlinks so the loader
# works from /usr/local/bin wrappers and direct invocation alike.
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

for _module in "$SCRIPT_DIR/compose-stack-manager/"*.sh; do
    if [ -f "$_module" ]; then
        # shellcheck disable=SC1090  # dynamic module loader
        source "$_module"
    else
        echo "Error: module $_module not found." >&2
        exit 1
    fi
done
unset _module

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --update)
                MODE="update"
                ;;
            -i|--interactive)
                INTERACTIVE=true
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            *)
                printf '%bUnknown option:%b %s\n' "$RED" "$NC" "$1" >&2
                print_help >&2
                exit 1
                ;;
        esac
        shift
    done

    if $INTERACTIVE && [ "$MODE" != "update" ]; then
        printf '%bWarning:%b --interactive has effect only with --update\n' "$YELLOW" "$NC" >&2
    fi
}

main() {
    parse_args "$@"

    if command_exists python3; then
# shellcheck disable=SC2034  # consumed by sourced modules
        HAS_PYTHON3=true
    fi

    scan_directory_recursive "$START_DIR"

    case "$MODE" in
        check) run_check_mode ;;
        update) run_update_mode ;;
    esac
}

main "$@"
