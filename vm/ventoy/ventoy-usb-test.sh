#!/bin/bash
# PKG_NAME: usb-boot-test
# PKG_VERSION: 2.6.1
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
#  - UEFI and BIOS/Legacy boot, dual test (UEFI then BIOS), auto-detect from
#    the EFI System Partition or the El Torito boot catalog
#  - Plain ISO 9660 images boot as a USB CD-ROM, hybrid ISOs as a USB disk
#  - Snapshot mode (default): the guest never writes to the USB/image
#  - --dry-run prints the exact QEMU command line without running it
#  - Per-run log file, QEMU monitor on a per-run unix socket
#  - Refuses system disks; detects and offers to unmount auto-mounted partitions
#  - Windows/Generic profiles, integrated mouse, scaling and fullscreen
#  - Emoji dashboard with command preview and session log viewer
#  - Configurable RAM, CPU, VGA, USB controller, network, sound
#  - OVMF firmware auto-detection (combined and split CODE/VARS layouts)
#  - Configuration saved under ~/.config/usb-boot-test/
#  .
#  Legacy name: ventoy-usb-test (still supported for backward compatibility)
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
#
# Changelog:
#   2.6.1 - Softer TUI palette: light grey on blue with grey highlights, no
#           red selection bar or bright cyan borders
#   2.6.0 - Integrated USB tablet, fit-to-window/fullscreen controls,
#           Windows/Generic presets, muted emoji dashboard, command preview
#           and session log viewer; explicit UHCI for USB 1.1 tests
#   2.5.0 - Plain (non-hybrid) ISO 9660 images are attached as a USB CD-ROM
#           instead of a disk, so they actually boot; boot mode auto-detection
#           reads the El Torito catalog; --media auto|disk|cdrom; per-user
#           run dir (unprivileged CLI failed to log after a sudo TUI run);
#           README rewritten for the 2.x CLI
#   2.4.0 - Non-interactive CLI with --dry-run; snapshot mode; unmount check for
#           auto-mounted partitions; per-run log file; monitor on unix socket
#           (no fixed port 4444); XDG config parsed as key=value (no source);
#           module dir renamed usb-boot-test/, omvf.sh -> ovmf.sh
#   2.3.0 - Fix headless mode, ESC blanking settings, dual-test state, ESP-based
#           boot-mode detection; drop cache module and diagnostic benchmarks
#   2.2.2 - Previous release

set -euo pipefail

readonly SCRIPT_NAME="USB Boot Tester"
readonly VERSION="2.6.1"

# Determine the directory where the script is located (resolving symlinks)
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

# Runtime state: per-run OVMF VARS copy, monitor socket and log files.
# Several of the variables below are consumed only by the modules under
# usb-boot-test/*.sh that we source dynamically; they appear unused when this
# file is linted in isolation, hence the SC2034 annotations.
# The directory is per user: the TUI runs as root (sudo) while the CLI can run
# unprivileged on image files, and a shared root-owned /tmp/usb-boot-test made
# the unprivileged run fail to write its log.
RUN_DIR="${TMPDIR:-/tmp}/usb-boot-test-$(id -un)"
readonly RUN_DIR
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
# shellcheck disable=SC2034  # consumed by config, menus and QEMU builder
MOUSE_MODE="tablet"
# shellcheck disable=SC2034
DISPLAY_SCALE="fit"
# shellcheck disable=SC2034
FULLSCREEN=false
# shellcheck disable=SC2034
NETWORK=false
# shellcheck disable=SC2034
SOUND=false
USB_VERSION="3.0"
# Snapshot mode: guest writes go to a throwaway overlay, the USB/image is never
# modified. Disable to test persistence features (Ventoy plugins, installers).
SNAPSHOT=true
# How the target is presented to the guest. MEDIA_MODE is the user's choice
# (auto|disk|cdrom), MEDIA the effective value (disk|cdrom) computed by
# refresh_media_type: plain ISO 9660 images become a USB CD-ROM.
MEDIA_MODE="auto"
MEDIA="disk"

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
    local selected="1"
    while true; do
        ui_dimensions
        local disk_info="Choose a USB device or image to get started"
        if [[ -n "$DISK" ]]; then
            disk_info="$(basename "$DISK")"
            if [[ -b "$DISK" ]]; then
                local size
                size=$(lsblk -d -n -o SIZE "$DISK" 2>/dev/null | xargs || echo "?")
                disk_info+=" ($size)"
            fi
        fi
        # Bound long filenames so they cannot push actions out of the dialog.
        disk_info="${disk_info:0:$((UI_WIDTH - 12))}"
        local acceleration="TCG" protection="🔒 Snapshot ON · target protected"
        [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] && acceleration="KVM"
        [[ "$SNAPSHOT" == false ]] && protection="⚠ Snapshot OFF · guest writes to target"
        [[ "$MEDIA" == cdrom ]] && protection="🔒 Read-only USB CD-ROM"
        local boot_status="$BIOS_MODE"
        [[ "$BIOS_MODE" == uefi && ! -f "$DEFAULT_BIOS" ]] && boot_status="uefi (OVMF missing)"
        local dashboard="💾 $disk_info\n$protection\n$boot_status · ${MEMORY} MB · ${CORES}c/${THREADS}t/${SOCKETS}s · $acceleration"
        local choice
        choice=$(whiptail --title "🚀 $SCRIPT_NAME · v$VERSION" \
            --backtitle "USB Boot Tester  |  Arrows: navigate · Enter: select · Esc: back" \
            --ok-button "Select" --cancel-button "Exit" --default-item "$selected" \
            --menu "$dashboard" "$UI_HEIGHT" "$UI_WIDTH" "$UI_LIST_HEIGHT" \
            "1" "🚀 Start boot test" \
            "2" "💾 Select USB / image" \
            "3" "✨ Quick profiles · Windows / Generic" \
            "4" "💻 Hardware · RAM, CPU, USB" \
            "5" "🖥  Display & mouse · $DISPLAY_SCALE / $MOUSE_MODE" \
            "6" "⚙️  Boot mode · $BIOS_MODE" \
            "7" "🔧 Advanced · video, network, audio, snapshot" \
            "8" "🧪 Dual test · UEFI + BIOS" \
            "9" "🔍 Tools · command preview, logs, diagnostics, help" \
            "c" "📝 Configuration · save / load / reset" \
            "0" "🚪 Exit" \
            3>&1 1>&2 2>&3) || true
        [[ -n "$choice" ]] && selected="$choice"
        case "$choice" in
            1)
                if [[ -z "$DISK" ]]; then
                    select_disk_menu || continue
                fi
                [[ -n "$DISK" ]] && confirm_and_run
                ;;
            2) select_disk_menu || true ;;
            3) profile_menu ;;
            4) system_config_menu ;;
            5) display_menu ;;
            6) bios_menu ;;
            7) advanced_menu ;;
            8) test_both_modes ;;
            9) tools_menu ;;
            c) config_management_menu ;;
            0) clean_exit ;;
            "")
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
    help_text+="   Plain ISOs boot as a USB CD-ROM, everything else as a USB disk\n"
    help_text+="2. Configure boot mode (UEFI/BIOS/Auto)\n"
    help_text+="3. Choose a quick profile (Windows: 8 GiB / Generic: 2 GiB)\n"
    help_text+="4. Start the test (single mode or dual UEFI+BIOS)\n\n"
    help_text+="SNAPSHOT MODE (Advanced menu, default ON):\n"
    help_text+="• Guest writes go to a temporary overlay; the USB/image is\n"
    help_text+="  never modified. Turn it off to test persistence features.\n\n"
    help_text+="BOOT MODES:\n"
    help_text+="• UEFI: Modern, requires OVMF\n"
    help_text+="• BIOS: Legacy, for older systems\n"
    help_text+="• Auto: EFI System Partition on disks, El Torito catalog on ISOs\n\n"
    help_text+="DISPLAY: integrated mouse and fit-to-window by default.\n"
    help_text+="Use Display & Mouse for native scale or fullscreen.\n"
    help_text+="Tools contains the command preview and last run log.\n\n"
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
  --auto                detect (default): UEFI if an EFI System Partition
                        exists; for plain ISOs, from the El Torito catalog

Virtual hardware:
  --profile windows|generic
                        windows: 8192 MB, 4 cores, q35, USB 3.0, std VGA,
                        integrated mouse and fit-to-window; generic: 2048 MB, VirtIO
                        put individual overrides after the profile
  --ram MB              memory in MB                     (default: $MEMORY)
  --cores N             CPU cores                        (default: $CORES)
  --machine TYPE        q35 | pc | microvm               (default: $MACHINE_TYPE)
  --usb 1.1|2.0|3.0     USB controller for the drive     (default: $USB_VERSION)
  --vga MODE            virtio | std | cirrus | qxl | none (default: $VGA_MODE)
  --format FMT          force disk format (raw, qcow2, vpc, vdi, vmdk)
  --media auto|disk|cdrom
                        present TARGET as a USB disk or a USB CD-ROM
                        (default: auto — plain ISO 9660 images without a
                        partition table become a CD-ROM, the rest a disk)
  --net                 enable user-mode network (e1000)
  --sound               enable Intel HDA audio
  --ovmf PATH           OVMF firmware file (OVMF.fd or OVMF_CODE*.fd)

Display and input (ignored with --vga none):
  --mouse tablet|relative
                        integrated pointer or legacy mouse (default: $MOUSE_MODE)
  --scale fit|native    fit image to window or native size (default: $DISPLAY_SCALE)
  --fullscreen          start fullscreen
  --windowed            start in a window (default)

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
  (paths are per user: the TUI under sudo uses .../usb-boot-test-root)

Examples:
  sudo $(basename "$0") /dev/sdb
  sudo $(basename "$0") --bios --ram 1024 /dev/sdb
  sudo $(basename "$0") --profile windows /dev/sdb
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
            --profile)
                case "${2:-}" in windows|generic) ;; *) die "--profile must be windows or generic" ;; esac
                apply_hardware_profile "$2"
                shift
                ;;
            --mouse) MOUSE_MODE="${2:-}"; [[ $# -gt 1 ]] || die "--mouse requires tablet or relative"; shift ;;
            --scale) DISPLAY_SCALE="${2:-}"; [[ $# -gt 1 ]] || die "--scale requires fit or native"; shift ;;
            --fullscreen) FULLSCREEN=true ;;
            --windowed) FULLSCREEN=false ;;
            --ram) MEMORY="${2:-}"; shift ;;
            --cores) CORES="${2:-}"; shift ;;
            --machine) MACHINE_TYPE="${2:-}"; shift ;;
            --usb) USB_VERSION="${2:-}"; shift ;;
            --vga) VGA_MODE="${2:-}"; shift ;;
            --format) FORMAT="${2:-}"; CLI_FORMAT_SET=true; shift ;;
            --media) MEDIA_MODE="${2:-}"; shift ;;
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
    case "$MEDIA_MODE" in auto|disk|cdrom) ;; *) die "--media must be auto, disk or cdrom" ;; esac
    case "$MOUSE_MODE" in tablet|relative) ;; *) die "--mouse must be tablet or relative" ;; esac
    case "$DISPLAY_SCALE" in fit|native) ;; *) die "--scale must be fit or native" ;; esac
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

    # Disk format and media type (USB disk vs. USB CD-ROM for plain ISOs)
    if [[ "$CLI_FORMAT_SET" != true ]]; then
        FORMAT=$(detect_image_format "$DISK")
        [[ "$FORMAT" == "unknown" ]] && FORMAT="raw"
    fi
    refresh_media_type

    # Boot mode: the CLI defaults to auto-detection (the TUI default is uefi).
    [[ "$CLI_BOOT_SET" == true ]] || BIOS_MODE="auto"
    local mode_note=""
    if [[ "$BIOS_MODE" == "auto" ]]; then
        local detected reason
        detected=$(detect_boot_mode "$DISK") || true
        read -r BIOS_MODE reason <<< "$detected"
        mode_note="(auto: $reason)"
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
        echo "# media:     $MEDIA$([[ $MEDIA_MODE == auto ]] && echo " (auto)")"
        echo "# boot-mode: $BIOS_MODE $mode_note"
        echo "# snapshot:  $([[ $MEDIA == cdrom ]] && echo "n/a (cdrom is read-only)" || echo "$SNAPSHOT")"
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
    ui_init
    initial_checks
    main_menu
}

# Execute only if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
