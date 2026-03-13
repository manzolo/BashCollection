#!/bin/bash

# PKG_NAME: share-manager
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), coreutils, util-linux, cifs-utils
# PKG_RECOMMENDS: nfs-common, sshfs, dialog
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Manage CIFS/NFS/SSHFS shares with an interactive dialog TUI
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Source modules
for _mod in "$SCRIPT_DIR/share-manager/"*.sh; do
    # shellcheck source=/dev/null
    source "$_mod"
done

# ============================================================================
# Main
# ============================================================================

init_config
check_dependencies

show_info() {
    echo "share-manager - CIFS/NFS/SSHFS share management"
    echo "Version: $SCRIPT_VERSION"
    echo ""
    echo "Configuration: $CONFIG_FILE"
}

usage() {
    echo "Usage: $(basename "$0") [list|mount|umount|status|info|ui]"
    echo "  list             - List all configured shares"
    echo "  mount <name>     - Mount the specified share"
    echo "  umount <name>    - Unmount the specified share"
    echo "  status <name>    - Show status of the specified share"
    echo "  info             - Show script information"
    echo "  ui               - Launch interactive dialog UI"
    exit 1
}

if [ $# -eq 0 ]; then
    if command -v dialog &>/dev/null; then
        dialog_main_menu
    else
        show_info
        echo ""
        usage
    fi
    exit 0
fi

case "$1" in
    list)
        list_shares
        ;;
    mount)
        sudo -v || exit 1
        mount_share "$2"
        ;;
    umount)
        sudo -v || exit 1
        umount_share "$2"
        ;;
    status)
        check_status "$2"
        ;;
    info)
        show_info
        ;;
    ui)
        check_dialog
        dialog_main_menu
        ;;
    *)
        usage
        ;;
esac
