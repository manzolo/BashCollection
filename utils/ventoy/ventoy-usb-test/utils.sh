# Test both modes (UEFI and BIOS)
test_both_modes() {
    if [[ -z "$DISK" ]]; then
        whiptail --title "Error" --msgbox "Select a disk first!" 8 40
        return
    fi
    
    if ! whiptail --title "Dual Test" --yesno \
        "Test both UEFI and BIOS modes?\n\nTwo consecutive tests will be run." \
        10 50; then
        return
    fi
    
    # Test UEFI
    BIOS_MODE="uefi"
    if [[ ! -f "$DEFAULT_BIOS" ]]; then
        whiptail --title "OVMF Required" --msgbox \
            "OVMF is required for UEFI testing.\nSkipping UEFI test." \
            8 50
    else
        whiptail --title "UEFI Test" --msgbox \
            "Starting UEFI mode test...\nPress OK to continue." \
            8 40
        
        clear
        log_info "=== UEFI TEST STARTED ==="
        local qemu_cmd_array=()
        readarray -t qemu_cmd_array < <(build_qemu_command)
        "${qemu_cmd_array[@]}" || log_error "UEFI test failed"
        
        echo
        read -p "UEFI test completed. Press Enter for BIOS test..." -r
    fi
    
    # Test BIOS
    BIOS_MODE="bios"
    whiptail --title "BIOS Test" --msgbox \
        "Starting BIOS Legacy mode test...\nPress OK to continue." \
        8 40
    
    clear
    log_info "=== BIOS LEGACY TEST STARTED ==="
    local qemu_cmd_array=()
    readarray -t qemu_cmd_array < <(build_qemu_command)
    "${qemu_cmd_array[@]}" || log_error "BIOS test failed"
    
    echo
    log_info "Dual test completed!"
    read -p "Press Enter to return to the menu..." -r
}

# Test KVM functionality
test_kvm_functionality() {
    local result=""
    
    if [[ ! -c /dev/kvm ]]; then
        result="KVM is not available\n\nThe KVM module is not loaded."
    elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        result="KVM present but not accessible\n\nSolution:\nsudo usermod -a -G kvm $USER\n\nThen restart your session."
    else
        # Quick KVM test
        local test_result
        if timeout 10 qemu-system-x86_64 -enable-kvm -m 64 -nographic -no-reboot \
            -kernel /dev/null 2>/dev/null; then
            test_result="Functional"
        else
            test_result="Issues detected"
        fi
        
        result="KVM fully functional\n\n"
        result+="KVM Group: $(groups | grep -o kvm || echo "Not in group")\n"
        result+="Permissions: $(ls -l /dev/kvm)\n"
        result+="Quick Test: $test_result"
    fi
    
    whiptail --title "KVM Test" --msgbox "$result" 15 60
}