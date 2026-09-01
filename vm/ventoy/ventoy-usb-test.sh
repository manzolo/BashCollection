#!/bin/bash
# PKG_NAME: usb-boot-test
# PKG_VERSION: 2.4.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), qemu-system-x86, whiptail, jq, util-linux
# PKG_RECOMMENDS: ovmf, qemu-utils, socat
# PKG_PROVIDES: ventoy-usb-test
# PKG_REPLACES: ventoy-usb-test
# PKG_CONFLICTS: ventoy-usb-test
# PKG_ALIASES: ventoy-usb-test
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Test bootable USB drives and disk images in QEMU
# PKG_LONG_DESCRIPTION: Boot any USB device or disk image (ISO, IMG, qcow2,
#  VHD/vtoy, vdi, vmdk) in a QEMU virtual machine without rebooting the host.
#  Works with Ventoy, Ubuntu, Windows, rescue disks and any bootable media.
#  .
#  Features:
#  - Interactive whiptail TUI or fully scriptable CLI (usb-boot-test /dev/sdX)
#  - UEFI and BIOS/Legacy boot, dual test (UEFI then BIOS), auto-detect from ESP
#  - Snapshot mode (default): the guest never writes to the USB/image
#  - --dry-run prints the exact QEMU command line without running it
#  - Per-run log file, QEMU monitor on a per-run unix socket
#  - Refuses system disks; detects and offers to unmount auto-mounted partitions
#  - Configurable RAM, CPU, VGA, USB controller, network, sound
#  - OVMF firmware auto-detection (combined and split CODE/VARS layouts)
#  - Configuration saved under ~/.config/usb-boot-test/
#  .
#  Legacy name: ventoy-usb-test (still supported for backward compatibility)
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
#
# Changelog:
#   2.4.0 - Non-interactive CLI with --dry-run; snapshot mode; unmount check for
#           auto-mounted partitions; per-run log file; monitor on unix socket
#           (no fixed port 4444); XDG config parsed as key=value (no source);
#           module dir renamed usb-boot-test/, omvf.sh -> ovmf.sh
#   2.3.0 - Fix headless mode, ESC blanking settings, dual-test state, ESP-based
#           boot-mode detection; drop cache module and diagnostic benchmarks
#   2.2.2 - Previous release

set -euo pipefail

readonly SCRIPT_NAME="USB Boot Tester"
readonly VERSION="2.4.0"

# Determine the directory where the script is located (resolving symlinks)
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

# Runtime state: per-run OVMF VARS copy, monitor socket and log files.
# Several of the variables below are consumed only by the modules under
# usb-boot-test/*.sh that we source dynamically; they appear unused when this
# file is linted in isolation, hence the SC2034 annotations.
readonly RUN_DIR="/tmp/usb-boot-test"
# shellcheck disable=SC2034
readonly LOG_DIR="$RUN_DIR/logs"
# shellcheck disable=SC2034  # consumed by ovmf_firmware_qemu_args in ovmf.sh
readonly OVMF_VARS_RUN="$RUN_DIR/OVMF_VARS_$$.fd"
# shellcheck disable=SC2034  # consumed by build_qemu_command in qemu.sh
readonly MONITOR_SOCK="$RUN_DIR/monitor_$$.sock"
# shellcheck disable=SC2034  # set by run_qemu_test for each run
RUN_LOG=""

# Configuration lives under the *invoking* user's XDG config dir, also when the
# tool is run through sudo (previously it ended up in /root).
_cfg_home="$HOME"
if [[ -n "${SUDO_USER:-}" ]]; then
    _cfg_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$_cfg_home" ]] || _cfg_home="$HOME"
fi
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$_cfg_home/.config}/usb-boot-test"
# shellcheck disable=SC2034
readonly CONFIG_FILE="$CONFIG_DIR/config"
# shellcheck disable=SC2034  # migrated on first load by load_config
readonly LEGACY_CONFIG_FILE="$_cfg_home/.ventoy_test_config"
unset _cfg_home

# Global variables with default values (consumed by sourced modules)
MEMORY="2048"
CORES="4"
# shellcheck disable=SC2034
THREADS="1"
# shellcheck disable=SC2034
SOCKETS="1"
# shellcheck disable=SC2034
MACHINE_TYPE="q35"
DEFAULT_BIOS="/usr/share/OVMF/OVMF.fd"
DISK=""
# shellcheck disable=SC2034
FORMAT="raw"
BIOS_MODE="uefi"
VGA_MODE="virtio"
# shellcheck disable=SC2034
NETWORK=false
# shellcheck disable=SC2034
SOUND=false
USB_VERSION="3.0"
# Snapshot mode: guest writes go to a throwaway overlay, the USB/image is never
# modified. Disable to test persistence features (Ventoy plugins, installers).
SNAPSHOT=true

# CLI-only state
CLI_MODE=false
DRY_RUN=false
CLI_UNMOUNT=false
CLI_FORMAT_SET=false
CLI_BOOT_SET=false

# Colors for messages (consumed by sourced modules)
# shellcheck disable=SC2034
readonly RED='\033[0;31m'
# shellcheck disable=SC2034
readonly GREEN='\033[0;32m'
# shellcheck disable=SC2034
readonly YELLOW='\033[1;33m'
# shellcheck disable=SC2034
readonly BLUE='\033[0;34m'
# shellcheck disable=SC2034
readonly NC='\033[0m'

# Source every module.
for script in "$SCRIPT_DIR/usb-boot-test/"*.sh; do
    if [ -f "$script" ]; then
        # shellcheck disable=SC1090  # dynamic module loader
        source "$script"
    else
        echo "Error: file script $script not found."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Interactive TUI
# ---------------------------------------------------------------------------

main_menu() {
    while true; do
        local disk_info=""
        if [[ -n "$DISK" ]]; then
            if [[ -b "$DISK" ]]; then
                local size
                size=$(lsblk -d -n -o SIZE "$DISK" 2>/dev/null | xargs || echo "?")
                disk_info="$(basename "$DISK") (${size})"
            else
                disk_info="$(basename "$DISK")"
            fi
        else
            disk_info="Not selected"
        fi

        # UEFI needs firmware on disk; BIOS is always ready.
        local boot_icon="✅"
        if [[ "$BIOS_MODE" == "uefi" && ! -f "$DEFAULT_BIOS" ]]; then
            boot_icon="⚠️ (OVMF missing)"
        fi
        local snap_label="off"
        [[ "$SNAPSHOT" == true ]] && snap_label="on"

        local choice
        choice=$(whiptail --title "$SCRIPT_NAME v$VERSION" \
            --menu "Main Menu:" \
            20 75 10 \
            "1" "💾 Disk/USB: $disk_info" \
            "2" "⚙️  Boot: $BIOS_MODE $boot_icon" \
            "3" "💻 System: ${MEMORY}MB RAM, ${CORES}c CPU" \
            "4" "🔧 Advanced: VGA=$VGA_MODE, USB=$USB_VERSION, snapshot=$snap_label" \
            "5" "🔍 Diagnostics & System Info" \
            "6" "📝 Configuration" \
            "7" "🚀 START SINGLE TEST!" \
            "8" "🧪 DUAL TEST (UEFI+BIOS)" \
            "9" "❓ Help" \
            "0" "🚪 Exit" \
            3>&1 1>&2 2>&3) || true

        case $choice in
            1) select_disk_menu ;;
            2) bios_menu ;;
            3) system_config_menu ;;
            4) advanced_menu ;;
            5) diagnostic_menu ;;
            6) config_management_menu ;;
            7)
                if [[ -z "$DISK" ]]; then
                    whiptail --title "Error" --msgbox "Select a disk first!" 8 40 || true
                else
                    confirm_and_run
                fi
                ;;
            8) test_both_modes ;;
            9) show_help ;;
            0) clean_exit ;;
            "")
                # ESC/Cancel on the main menu: confirm instead of quitting
                # outright (ESC on the confirm dialog counts as "No").
                if whiptail --title "Exit" --yesno "Exit $SCRIPT_NAME?" 8 40; then
                    clean_exit
                fi
                ;;
        esac
    done
}

# Remove per-run artefacts (OVMF VARS copy, monitor socket) and the X11 grant.
cleanup_run_artifacts() {
    revoke_x11_for_root
    rm -f "$OVMF_VARS_RUN" "$MONITOR_SOCK"
}

clean_exit() {
    clear
    cleanup_run_artifacts
    log_info "Thank you for using $SCRIPT_NAME!"
    exit 0
}

show_help() {
    local help_text="USB BOOT TESTER GUIDE\n\n"
    help_text+="Test any bootable USB/disk in QEMU without rebooting!\n"
    help_text+="Works with: Ventoy, Ubuntu ISOs, Windows, rescue disks, etc.\n\n"
    help_text+="USAGE:\n"
    help_text+="1. Select a USB device or image file (ISO, IMG, qcow2, VHD...)\n"
    help_text+="2. Configure boot mode (UEFI/BIOS/Auto)\n"
    help_text+="3. Adjust system parameters if needed (RAM, CPU, VGA)\n"
    help_text+="4. Start the test (single mode or dual UEFI+BIOS)\n\n"
    help_text+="SNAPSHOT MODE (Advanced menu, default ON):\n"
    help_text+="• Guest writes go to a temporary overlay; the USB/image is\n"
    help_text+="  never modified. Turn it off to test persistence features.\n\n"
    help_text+="BOOT MODES:\n"
    help_text+="• UEFI: Modern, requires OVMF\n"
    help_text+="• BIOS: Legacy, for older systems\n"
    help_text+="• Auto: Looks for an EFI System Partition on the disk\n\n"
    help_text+="QEMU CONTROLS:\n"
    help_text+="• Ctrl+Alt+G: Release mouse\n"
    help_text+="• Ctrl+Alt+F: Fullscreen\n"
    help_text+="• Ctrl+C in the terminal: Terminate emulation\n"
    help_text+="• Monitor: socat - UNIX-CONNECT:$MONITOR_SOCK\n\n"
    help_text+="LOGS: $LOG_DIR/run-<timestamp>.log\n\n"
    help_text+="CLI: run '$(basename "$0") --help' for the non-interactive mode."

    whiptail --title "User Guide" --scrolltext \
        --msgbox "$help_text" 24 74 || true
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
$SCRIPT_NAME v$VERSION - Test bootable USB devices and disk images in QEMU

Usage:
  $(basename "$0")                         interactive TUI (requires root)
  $(basename "$0") [OPTIONS] TARGET        boot TARGET in QEMU, no prompts
  $(basename "$0") --dry-run [OPTIONS] TARGET
                                         print the QEMU command line and exit

TARGET is a block device (/dev/sdX, requires root) or an image file
(ISO, IMG, raw, qcow2, VHD/.vtoy, vdi, vmdk).

Boot mode:
  --uefi                UEFI boot with OVMF
  --bios                BIOS / legacy boot
  --auto                detect: UEFI if an EFI System Partition exists (default)

Virtual hardware:
  --ram MB              memory in MB                     (default: $MEMORY)
  --cores N             CPU cores                        (default: $CORES)
  --machine TYPE        q35 | pc | microvm               (default: $MACHINE_TYPE)
  --usb 1.1|2.0|3.0     USB controller for the drive     (default: $USB_VERSION)
  --vga MODE            virtio | std | cirrus | qxl | none (default: $VGA_MODE)
  --format FMT          force disk format (raw, qcow2, vpc, vdi, vmdk)
  --net                 enable user-mode network (e1000)
  --sound               enable Intel HDA audio
  --ovmf PATH           OVMF firmware file (OVMF.fd or OVMF_CODE*.fd)

Safety:
  --no-snapshot         let the guest write to TARGET (default: snapshot on,
                        TARGET is never modified)
  --unmount             unmount auto-mounted partitions of TARGET before boot
                        (otherwise the run is refused while they are mounted)

Other:
  -n, --dry-run         show the QEMU command line, do not run it
  -V, --version         print version and exit
  -h, --help            show this help and exit

Files:
  config   $CONFIG_FILE
  logs     $LOG_DIR/run-<timestamp>.log
  monitor  socat - UNIX-CONNECT:$RUN_DIR/monitor_<pid>.sock

Examples:
  sudo $(basename "$0") /dev/sdb
  sudo $(basename "$0") --bios --ram 1024 /dev/sdb
  $(basename "$0") --vga none --dry-run ~/ventoy.img
EOF
}

die() { log_error "$*"; exit 2; }

# shellcheck disable=SC2034  # NETWORK/SOUND are consumed by build_qemu_command
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -V|--version) echo "$SCRIPT_NAME v$VERSION"; exit 0 ;;
            -n|--dry-run) DRY_RUN=true ;;
            --uefi) BIOS_MODE="uefi"; CLI_BOOT_SET=true ;;
            --bios) BIOS_MODE="bios"; CLI_BOOT_SET=true ;;
            --auto) BIOS_MODE="auto"; CLI_BOOT_SET=true ;;
            --ram) MEMORY="${2:-}"; shift ;;
            --cores) CORES="${2:-}"; shift ;;
            --machine) MACHINE_TYPE="${2:-}"; shift ;;
            --usb) USB_VERSION="${2:-}"; shift ;;
            --vga) VGA_MODE="${2:-}"; shift ;;
            --format) FORMAT="${2:-}"; CLI_FORMAT_SET=true; shift ;;
            --ovmf) DEFAULT_BIOS="${2:-}"; shift ;;
            --net) NETWORK=true ;;
            --sound) SOUND=true ;;
            --no-snapshot) SNAPSHOT=false ;;
            --snapshot) SNAPSHOT=true ;;
            --unmount) CLI_UNMOUNT=true ;;
            --) shift; break ;;
            -*) die "Unknown option: $1 (see --help)" ;;
            *)
                [[ -z "$DISK" ]] || die "Only one TARGET may be given"
                DISK="$1"
                ;;
        esac
        shift
    done
    if [[ $# -gt 0 ]]; then
        # Remaining word after `--` is the target.
        [[ -z "$DISK" && $# -eq 1 ]] || die "Only one TARGET may be given"
        DISK="$1"
    fi

    # Any target or dry-run request means non-interactive mode.
    if [[ -n "$DISK" || "$DRY_RUN" == true ]]; then
        CLI_MODE=true
    fi

    # Validate option values early, with readable errors.
    [[ "$MEMORY" =~ ^[0-9]+$ ]] && (( MEMORY >= 128 )) || die "--ram must be a number of MB >= 128"
    [[ "$CORES" =~ ^[0-9]+$ ]] && (( CORES >= 1 )) || die "--cores must be a positive number"
    case "$USB_VERSION" in 1.1|2.0|3.0) ;; *) die "--usb must be 1.1, 2.0 or 3.0" ;; esac
    case "$VGA_MODE" in virtio|std|cirrus|qxl|none) ;; *) die "--vga must be virtio, std, cirrus, qxl or none" ;; esac
    case "$MACHINE_TYPE" in q35|pc|microvm) ;; *) die "--machine must be q35, pc or microvm" ;; esac
    case "$BIOS_MODE" in uefi|bios|auto) ;; *) die "boot mode must be uefi, bios or auto" ;; esac
}

run_cli() {
    [[ -n "$DISK" ]] || die "TARGET is required in non-interactive mode (see --help)"
    [[ -b "$DISK" || -f "$DISK" ]] || die "TARGET not found or not a device/regular file: $DISK"

    if [[ -b "$DISK" && "$DRY_RUN" != true && "$EUID" -ne 0 ]]; then
        die "Root is required to boot a block device. Re-run with sudo."
    fi
    if [[ "$DRY_RUN" != true ]] && ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        die "qemu-system-x86_64 not found. Install qemu-system-x86."
    fi

    # Disk format
    if [[ "$CLI_FORMAT_SET" != true ]]; then
        FORMAT=$(detect_image_format "$DISK")
        [[ "$FORMAT" == "unknown" ]] && FORMAT="raw"
    fi

    # Boot mode: the CLI defaults to auto-detection (the TUI default is uefi).
    [[ "$CLI_BOOT_SET" == true ]] || BIOS_MODE="auto"
    local mode_note=""
    if [[ "$BIOS_MODE" == "auto" ]]; then
        if BIOS_MODE=$(detect_boot_mode "$DISK"); then
            mode_note="(auto: $([[ $BIOS_MODE == uefi ]] && echo "EFI System Partition found" || echo "MBR, no EFI partition"))"
        else
            mode_note="(auto: no partition table, defaulting to uefi)"
        fi
    fi
    if [[ "$BIOS_MODE" == "uefi" ]]; then
        ovmf_autodetect_default || true
        if [[ ! -f "$DEFAULT_BIOS" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                log_warn "OVMF firmware not found ($DEFAULT_BIOS); UEFI run would fail. Install 'ovmf' or pass --ovmf."
            else
                die "OVMF firmware not found ($DEFAULT_BIOS). Install 'ovmf' or pass --ovmf PATH."
            fi
        fi
    fi

    # Target safety (block devices only)
    if [[ -b "$DISK" ]]; then
        if target_has_critical_mounts "$DISK"; then
            die "$DISK carries mounted system filesystems (/, /boot, /home...). Refusing."
        fi
        local mounted
        mounted=$(list_target_mounts "$DISK")
        if [[ -n "$mounted" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                log_warn "Mounted partitions on $DISK (would need --unmount):"$'\n'"$mounted"
            elif [[ "$CLI_UNMOUNT" == true ]]; then
                unmount_target_partitions "$DISK" || die "Could not unmount all partitions of $DISK"
            else
                die "Partitions of $DISK are mounted:"$'\n'"$mounted"$'\n'"Unmount them or pass --unmount."
            fi
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        local qemu_cmd_array=()
        readarray -t qemu_cmd_array < <(build_qemu_command)
        echo "# target:    $DISK"
        echo "# format:    $FORMAT"
        echo "# boot-mode: $BIOS_MODE $mode_note"
        echo "# snapshot:  $SNAPSHOT"
        [[ "$BIOS_MODE" == "uefi" ]] && echo "# firmware:  $DEFAULT_BIOS"
        echo "# monitor:   socat - UNIX-CONNECT:$MONITOR_SOCK"
        shell_join "${qemu_cmd_array[@]}"
        rm -f "$OVMF_VARS_RUN"
        return 0
    fi

    mkdir -p "$RUN_DIR"
    [[ "$VGA_MODE" != "none" ]] && setup_x11_for_root
    trap cleanup_run_artifacts EXIT INT TERM

    [[ -n "$mode_note" ]] && log_info "Boot mode: $BIOS_MODE $mode_note"
    local rc=0
    run_qemu_test "USB BOOT TEST" || rc=$?
    return $rc
}

# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    if [[ "$CLI_MODE" == true ]]; then
        run_cli
        exit $?
    fi

    if [ "$EUID" -ne 0 ]; then
        echo "The interactive mode needs root (raw device access, KVM)."
        echo "Run: sudo $(basename "$0")   — or see --help for the CLI mode."
        exit 1
    fi
    trap cleanup_run_artifacts EXIT INT TERM
    initial_checks
    main_menu
}

# Execute only if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
