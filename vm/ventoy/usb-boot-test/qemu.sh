# shellcheck shell=bash
# QEMU command construction, target safety checks and execution.
# shellcheck disable=SC2054  # commas inside QEMU option values are intended

# Print an argument list as a copy-pasteable shell command line. Only tokens
# that need it are quoted, so QEMU's comma-separated option values stay
# readable (printf %q would escape every comma).
shell_join() {
    local arg out=""
    for arg in "$@"; do
        if [[ "$arg" =~ ^[A-Za-z0-9_./:=,+@-]+$ ]]; then
            out+="$arg "
        else
            out+="$(printf '%q' "$arg") "
        fi
    done
    printf '%s\n' "${out% }"
}

# Build the QEMU argument list for the current configuration, one token per
# line so callers can `readarray -t` it into an array.
build_qemu_command() {
    local qemu_cmd=(
        qemu-system-x86_64
        -name "USB Boot Test"
        -m "$MEMORY"
        -smp cores="$CORES",threads="$THREADS",sockets="$SOCKETS"
        -machine "$MACHINE_TYPE"
    )

    # USB controller based on version
    case "$USB_VERSION" in
        "1.1") qemu_cmd+=(-device piix3-usb-uhci,id=uhci -device usb-storage,bus=uhci.0,drive=usb-drive) ;;
        "2.0") qemu_cmd+=(-device ich9-usb-ehci1,id=ehci -device usb-storage,bus=ehci.0,drive=usb-drive) ;;
        "3.0") qemu_cmd+=(-device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=usb-drive) ;;
    esac

    # USB drive. cache=writeback avoids the O_DIRECT requirement of cache=none,
    # which fails on some filesystems/image files; fine for a throwaway test VM.
    # snapshot=on sends guest writes to a temporary overlay so the real
    # device/image is never modified. A plain ISO 9660 image is presented as a
    # USB CD-ROM (read-only by nature, so snapshot does not apply): attached
    # as a disk it has no partition table and nothing would boot.
    local drive="file=$DISK,format=$FORMAT,cache=writeback,if=none,id=usb-drive"
    if [[ "$MEDIA" == "cdrom" ]]; then
        drive+=",media=cdrom,readonly=on"
    elif [[ "$SNAPSHOT" == true ]]; then
        drive+=",snapshot=on"
    fi
    qemu_cmd+=(-drive "$drive")

    # KVM if available
    if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        qemu_cmd+=(-enable-kvm -cpu host,kvm=on)
    else
        qemu_cmd+=(-cpu qemu64)
    fi

    # BIOS/UEFI. UEFI firmware handling (combined -bios vs split pflash with a
    # writable VARS copy) is resolved by ovmf_firmware_qemu_args in ovmf.sh.
    if [[ "$BIOS_MODE" == "uefi" ]]; then
        local _fw_args=()
        readarray -t _fw_args < <(ovmf_firmware_qemu_args)
        qemu_cmd+=("${_fw_args[@]}")
    fi

    # Video. Headless uses `-display none` rather than `-nographic`: the latter
    # also redirects the serial console to stdio, which collides with the
    # explicit `-serial stdio` below ("cannot use stdio by multiple character
    # devices").
    if [[ "$VGA_MODE" != "none" ]]; then
        qemu_cmd+=(-vga "$VGA_MODE")
        local display="gtk,show-cursor=on"
        [[ "$DISPLAY_SCALE" == fit ]] && display+=",zoom-to-fit=on" || display+=",zoom-to-fit=off"
        [[ "$FULLSCREEN" == true ]] && display+=",full-screen=on" || display+=",full-screen=off"
        qemu_cmd+=(-display "$display")
        if [[ "$MOUSE_MODE" == tablet ]]; then
            case "$USB_VERSION" in
                "1.1") qemu_cmd+=(-device usb-tablet,bus=uhci.0) ;;
                "2.0")
                    # The tablet is full-speed: EHCI alone cannot serve it.
                    # Keep the tested storage on EHCI and provide a UHCI bus.
                    qemu_cmd+=(-device piix3-usb-uhci,id=tablet-usb -device usb-tablet,bus=tablet-usb.0)
                    ;;
                "3.0") qemu_cmd+=(-device usb-tablet,bus=xhci.0) ;;
            esac
        fi
    else
        qemu_cmd+=(-display none)
    fi

    # Network
    if [[ "$NETWORK" == true ]]; then
        qemu_cmd+=(-netdev user,id=net0 -device e1000,netdev=net0)
    else
        qemu_cmd+=(-nic none)
    fi

    # Audio
    if [[ "$SOUND" == true ]]; then
        qemu_cmd+=(-audiodev pa,id=audio0 -device intel-hda -device hda-duplex,audiodev=audio0)
    fi

    # Monitor on a per-run unix socket (no fixed TCP port, so several instances
    # can coexist) and the guest serial console on the terminal.
    qemu_cmd+=(-monitor "unix:$MONITOR_SOCK,server,nowait" -serial stdio)

    printf '%s\n' "${qemu_cmd[@]}"
}

# Human-readable media / snapshot descriptions shared by the TUI and the logs.
media_label() {
    if [[ "$MEDIA" == "cdrom" ]]; then
        echo "USB CD-ROM (ISO 9660, El Torito)"
    else
        echo "USB disk"
    fi
}

snapshot_label() {
    if [[ "$MEDIA" == "cdrom" ]]; then
        echo "n/a (CD-ROM is read-only)"
    elif [[ "$SNAPSHOT" == true ]]; then
        echo "on (target not modified)"
    else
        echo "OFF (guest may write to target)"
    fi
}

# --- Target safety ---------------------------------------------------------

# True when any partition of the block device is mounted on a system path.
target_has_critical_mounts() {
    local device="$1" mount
    while read -r mount; do
        [[ -z "$mount" ]] && continue
        if [[ "$mount" =~ ^(/|/boot|/boot/efi|/home|/usr|/var|/opt|/root)$ ]]; then
            return 0
        fi
    done < <(lsblk -no MOUNTPOINT "$device" 2>/dev/null)
    return 1
}

# Print "<partition> <mountpoint>" for every mounted partition of the device.
list_target_mounts() {
    local device="$1"
    lsblk -lnpo PATH,MOUNTPOINT "$device" 2>/dev/null | awk 'NF>=2 {print}'
}

# Unmount every mounted partition of the device. Returns non-zero if any
# unmount failed.
unmount_target_partitions() {
    local device="$1" part rc=0
    while read -r part _; do
        [[ -n "$part" ]] || continue
        log_info "Unmounting $part"
        umount "$part" 2>/dev/null || { log_error "Failed to unmount $part"; rc=1; }
    done < <(list_target_mounts "$device")
    return $rc
}

# TUI helper: if partitions of the target are mounted, offer to unmount them.
# Returns 1 when the user declines (caller should abort the run).
ensure_target_unmounted_tui() {
    local device="$1"
    [[ -b "$device" ]] || return 0
    local mounted
    mounted=$(list_target_mounts "$device")
    [[ -n "$mounted" ]] || return 0

    if whiptail --title "Partitions mounted" --yesno \
        "Partitions of $device are mounted on the host:\n\n$mounted\n\nBooting a mounted device can corrupt data.\nUnmount them now?" \
        16 72; then
        if ! unmount_target_partitions "$device"; then
            whiptail --title "Unmount failed" --msgbox \
                "Some partitions could not be unmounted.\nClose programs using them and retry." 9 60 || true
            return 1
        fi
        return 0
    fi
    return 1
}

# Make sure anything the host recently wrote to the target device has reached
# it before the guest starts reading. For image files a plain sync is enough.
prepare_system_for_qemu() {
    local disk="$1"
    sync
    if [[ -b "$disk" ]] && command -v blockdev >/dev/null 2>&1; then
        blockdev --flushbufs "$disk" 2>/dev/null || true
    fi
}

# --- Execution -------------------------------------------------------------

# Run one QEMU boot test with the current configuration. Prints a header,
# flushes the target device, runs QEMU in the foreground with its output
# duplicated to a per-run log file, and reports the outcome. Returns QEMU's
# exit status.
run_qemu_test() {
    local label="${1:-USB BOOT TEST}"
    local qemu_cmd_array=()
    readarray -t qemu_cmd_array < <(build_qemu_command)

    mkdir -p "$LOG_DIR"
    RUN_LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
    rm -f "$MONITOR_SOCK"

    clear
    log_info "=== $label STARTED ==="
    log_info "Disk: $DISK ($FORMAT, $(media_label)) — Mode: $BIOS_MODE — Snapshot: $(snapshot_label)"
    log_info "Monitor: socat - UNIX-CONNECT:$MONITOR_SOCK"
    log_info "Log: $RUN_LOG"
    prepare_system_for_qemu "$DISK"
    log_info "Full QEMU command:\n$(shell_join "${qemu_cmd_array[@]}")"
    log_info "Press Ctrl+C to terminate"
    echo

    {
        echo "# $SCRIPT_NAME v$VERSION — $label — $(date -Is)"
        echo "# target=$DISK format=$FORMAT media=$MEDIA mode=$BIOS_MODE snapshot=$SNAPSHOT"
        echo "# cmd: $(shell_join "${qemu_cmd_array[@]}")"
        echo
    } > "$RUN_LOG"

    local rc=0
    set +e
    "${qemu_cmd_array[@]}" 2>&1 | tee -a "$RUN_LOG"
    rc=${PIPESTATUS[0]}
    set -e
    rm -f "$MONITOR_SOCK"

    echo
    if [[ $rc -eq 0 ]]; then
        log_info "$label completed — log: $RUN_LOG"
    else
        log_error "$label failed (QEMU exit code $rc) — log: $RUN_LOG"
    fi
    return "$rc"
}

# Show a configuration summary, confirm, then run a single test.
confirm_and_run() {
    local summary="USB BOOT TEST CONFIGURATION\n\n"
    summary+="• Disk: $DISK\n"
    summary+="• Format: $FORMAT\n"
    summary+="• Media: $(media_label)\n"
    summary+="• Mode: $BIOS_MODE\n"
    summary+="• Snapshot: $(snapshot_label)\n"
    summary+="• RAM: ${MEMORY}MB\n"
    summary+="• CPU: ${CORES}c/${THREADS}t/${SOCKETS}s\n"
    summary+="• USB: $USB_VERSION\n"
    summary+="• VGA: $VGA_MODE\n"
    if [[ "$VGA_MODE" != none ]]; then
        summary+="• Mouse: $MOUSE_MODE / Scale: $DISPLAY_SCALE / Fullscreen: $FULLSCREEN\n"
    fi
    summary+="• Network: $([[ $NETWORK == true ]] && echo "Yes" || echo "No")\n"
    summary+="• Audio: $([[ $SOUND == true ]] && echo "Yes" || echo "No")\n\n"
    summary+="Press Ctrl+C in the terminal to terminate QEMU."

    if ! whiptail --title "Confirm and Start" --yesno "$summary" 23 78; then
        return
    fi

    if [[ "$BIOS_MODE" == "uefi" && ! -f "$DEFAULT_BIOS" ]]; then
        whiptail --title "OVMF missing" --msgbox \
            "UEFI mode needs OVMF firmware.\nInstall it from Advanced → OVMF Management, or switch to BIOS." 9 64 || true
        return
    fi
    ensure_target_unmounted_tui "$DISK" || return 0

    save_config
    run_qemu_test "USB BOOT TEST" || true
    read -p "Press Enter to return to the menu..." -r
}
