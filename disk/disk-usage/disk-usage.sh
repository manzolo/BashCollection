#!/bin/bash
# shellcheck disable=SC2034  # globals here are consumed by the sourced modules
# PKG_NAME: disk-usage
# PKG_VERSION: 2.5.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), coreutils (>= 8.0), findutils (>= 4.0)
# PKG_RECOMMENDS: ncdu
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced disk usage analyzer with HTML report export
# PKG_LONG_DESCRIPTION: Analyzes directory sizes with visual progress bars
#  and exports interactive Baobab-style HTML reports.
#  .
#  Features:
#  - Colored terminal output with progress bars
#  - Interactive HTML treemap (squarified, drill-down, breadcrumb)
#  - Sortable/filterable file table in HTML report
#  - Top N largest files listing
#  - Customizable scan depth and hidden file support
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MAX_DEPTH=1
BAR_WIDTH=20
SHOW_HIDDEN=false
SHOW_TOP_FILES=false
TOP_FILES_COUNT=10
HTML_OUTPUT=""
HTML_DEPTH=3
REMOTE_HOST=""
REMOTE_PATH=""
SSH_OPTS=""

# =================== MODULE LOADER ===================
# Implementation lives in disk-usage/*.sh. Resolve symlinks so the loader
# works from /usr/local/bin wrappers and direct invocation alike.
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

for _module in "$SCRIPT_DIR/disk-usage/"*.sh; do
    if [ -f "$_module" ]; then
        # shellcheck disable=SC1090  # dynamic module loader
        source "$_module"
    else
        echo "Error: module $_module not found." >&2
        exit 1
    fi
done
unset _module


# ─── Argument Parsing ────────────────────────────────────────────────────────

TARGET_DIR="."

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--depth)       MAX_DEPTH="$2"; shift 2 ;;
        -w|--width)       BAR_WIDTH="$2"; shift 2 ;;
        -a|--all)         SHOW_HIDDEN=true; shift ;;
        -f|--files)
            SHOW_TOP_FILES=true
            if [[ $2 =~ ^[0-9]+$ ]]; then TOP_FILES_COUNT="$2"; shift 2; else shift; fi ;;
        -s|--sort)        shift 2 ;;  # kept for compatibility, unused
        --html)
            if [[ -n $2 && $2 != -* && ! -d "$2" ]]; then
                # Check if the value looks like [user@]host:/path (SSH target)
                if [[ "$2" =~ ^[A-Za-z0-9._@-]+:.+ ]]; then
                    # Parse SSH target: split on first ':'
                    REMOTE_HOST="${2%%:*}"
                    REMOTE_PATH="${2#*:}"
                    HTML_OUTPUT="$(mktemp /tmp/disk-usage-XXXXXX.html)"
                    shift 2
                else
                    HTML_OUTPUT="$2"; shift 2
                fi
            else
                HTML_OUTPUT="$(mktemp /tmp/disk-usage-XXXXXX.html)"; shift
            fi ;;
        --html-depth)     HTML_DEPTH="$2"; shift 2 ;;
        --ssh-opts)       SSH_OPTS="$2"; shift 2 ;;
        -h|--help)        show_help; exit 0 ;;
        *)
            # Detect [user@]host:/path as positional argument (without --html)
            if [[ "$1" =~ ^[A-Za-z0-9._@-]+:.+ ]]; then
                REMOTE_HOST="${1%%:*}"
                REMOTE_PATH="${1#*:}"
                [ -z "$HTML_OUTPUT" ] && HTML_OUTPUT="$(mktemp /tmp/disk-usage-XXXXXX.html)"
            elif [ -d "$1" ]; then
                TARGET_DIR="$1"
            else
                echo -e "${RED}Error: '$1' is not a valid directory, SSH path, or option${NC}"
                show_help; exit 1
            fi
            shift ;;
    esac
done

if [ -n "$HTML_OUTPUT" ]; then
    generate_html_report "$HTML_OUTPUT" "$TARGET_DIR"
else
    analyze_directory "$TARGET_DIR" "$MAX_DEPTH"
fi
