# Build QEMU command
build_qemu_command() {
    local qemu_cmd=(
        qemu-system-x86_64
        -name "Ventoy Boot Test"
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
    
    # USB drive
    qemu_cmd+=(-drive file="$DISK",format="$FORMAT",cache=none,if=none,id=usb-drive)
    
    # KVM if available
    if [[ -c /dev/kvm && -r /dev/kvm ]]; then
        qemu_cmd+=(-enable-kvm -cpu host,kvm=on)
    else
        qemu_cmd+=(-cpu qemu64)
    fi
    
    # BIOS/UEFI
    if [[ "$BIOS_MODE" == "uefi" ]]; then
        qemu_cmd+=(-bios "$DEFAULT_BIOS")
    fi
    
    # Video
    if [[ "$VGA_MODE" != "none" ]]; then
        qemu_cmd+=(-vga "$VGA_MODE")
        qemu_cmd+=(-display gtk,show-cursor=on)
    else
        qemu_cmd+=(-nographic)
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

# Confirm and run
confirm_and_run() {
    local qemu_cmd_array=()
    readarray -t qemu_cmd_array < <(build_qemu_command)
    local qemu_cmd_string="${qemu_cmd_array[*]}"
    
    # Show configuration summary
    local summary="VENTOY BOOT TEST CONFIGURATION\n\n"
    summary+="• Disk: $DISK\n"
    summary+="• Mode: $BIOS_MODE\n"
    summary+="• RAM: ${MEMORY}MB\n"
    summary+="• CPU: ${CORES}c/${THREADS}t/${SOCKETS}s\n"
    summary+="• USB: $USB_VERSION\n"
    summary+="• VGA: $VGA_MODE\n"
    summary+="• Network: $([[ $NETWORK == true ]] && echo "Yes" || echo "No")\n"
    summary+="• Audio: $([[ $SOUND == true ]] && echo "Yes" || echo "No")\n\n"
    summary+="Monitor: telnet localhost 4444"
    
    if ! whiptail --title "Confirm Execution" --yesno \
        "$summary" \
        18 60; then
        return
    fi
    
    # Save configuration
    save_config
    
    # Final confirmation
    if whiptail --title "Start Test" --yesno \
        "Start the boot test?\n\nPress Ctrl+C to terminate QEMU." \
        10 50; then
        
        clear
        log_info "=== VENTOY BOOT TEST STARTED ==="
        log_info "Monitor: telnet localhost 4444"
        log_info "Full QEMU command:\n$qemu_cmd_string"
        log_info "Press Ctrl+C to terminate"
        echo
        
        # Run QEMU
        if "${qemu_cmd_array[@]}"; then
            log_info "Test completed successfully"
        else
            log_error "Test failed with error"
        fi
        
        echo
        read -p "Press Enter to return to the menu..." -r
    fi
}