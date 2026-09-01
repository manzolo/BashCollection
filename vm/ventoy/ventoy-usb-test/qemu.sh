# QEMU command construction and execution.

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
        "1.1") qemu_cmd+=(-usb -device usb-storage,drive=usb-drive) ;;
        "2.0") qemu_cmd+=(-device ich9-usb-ehci1,id=ehci -device usb-storage,bus=ehci.0,drive=usb-drive) ;;
        "3.0") qemu_cmd+=(-device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=usb-drive) ;;
    esac

    # USB drive. cache=writeback avoids the O_DIRECT requirement of cache=none,
    # which fails on some filesystems/image files; fine for a throwaway test VM.
    qemu_cmd+=(-drive file="$DISK",format="$FORMAT",cache=writeback,if=none,id=usb-drive)

    # KVM if available
    if [[ -c /dev/kvm && -r /dev/kvm ]]; then
        qemu_cmd+=(-enable-kvm -cpu host,kvm=on)
    else
        qemu_cmd+=(-cpu qemu64)
    fi

    # BIOS/UEFI. UEFI firmware handling (combined -bios vs split pflash with a
    # writable VARS copy) is resolved by ovmf_firmware_qemu_args in omvf.sh.
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
        qemu_cmd+=(-display gtk,show-cursor=on)
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

    # Monitor and serial
    qemu_cmd+=(-monitor telnet:127.0.0.1:4444,server,nowait -serial stdio)

    printf '%s\n' "${qemu_cmd[@]}"
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

# Run one QEMU boot test with the current configuration. Prints a header,
# flushes the target device, runs QEMU in the foreground and reports the
# outcome. Returns QEMU's exit status.
run_qemu_test() {
    local label="${1:-USB BOOT TEST}"
    local qemu_cmd_array=()
    readarray -t qemu_cmd_array < <(build_qemu_command)

    clear
    log_info "=== $label STARTED ==="
    log_info "Disk: $DISK ($FORMAT) — Mode: $BIOS_MODE"
    log_info "Monitor: telnet localhost 4444"
    prepare_system_for_qemu "$DISK"
    log_info "Full QEMU command:\n${qemu_cmd_array[*]}"
    log_info "Press Ctrl+C to terminate"
    echo

    local rc=0
    "${qemu_cmd_array[@]}" || rc=$?
    echo
    if [[ $rc -eq 0 ]]; then
        log_info "$label completed"
    else
        log_error "$label failed (QEMU exit code $rc)"
    fi
    return $rc
}

# Show a configuration summary, confirm, then run a single test.
confirm_and_run() {
    local summary="USB BOOT TEST CONFIGURATION\n\n"
    summary+="• Disk: $DISK\n"
    summary+="• Format: $FORMAT\n"
    summary+="• Mode: $BIOS_MODE\n"
    summary+="• RAM: ${MEMORY}MB\n"
    summary+="• CPU: ${CORES}c/${THREADS}t/${SOCKETS}s\n"
    summary+="• USB: $USB_VERSION\n"
    summary+="• VGA: $VGA_MODE\n"
    summary+="• Network: $([[ $NETWORK == true ]] && echo "Yes" || echo "No")\n"
    summary+="• Audio: $([[ $SOUND == true ]] && echo "Yes" || echo "No")\n\n"
    summary+="Monitor: telnet localhost 4444\n"
    summary+="Press Ctrl+C in the terminal to terminate QEMU."

    if ! whiptail --title "Confirm and Start" --yesno "$summary" 20 60; then
        return
    fi

    save_config
    run_qemu_test "USB BOOT TEST" || true
    read -p "Press Enter to return to the menu..." -r
}
