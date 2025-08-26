# Main QEMU test function
test_vm_qemu() {
    local file=$1
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        whiptail --msgbox "qemu-system-x86_64 not found.\nInstall with: apt install qemu-system-x86" 10 60
        return 1
    fi
    
    local qemu_options=(
        "1" "MBR Boot (Legacy)"
        "2" "UEFI/EFI Boot"
        "3" "Headless Mode (SSH via port 2222)"
        "4" "Custom Boot Configuration"
        "5" "Debug Mode (verbose logging)"
    )
    
    local choice=$(whiptail --title "Test VM with QEMU" --menu "Select boot mode:" 16 70 6 "${qemu_options[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Detect file format and KVM support
    local file_format=$(detect_file_format "$file")
    local kvm_option=$(check_kvm_support)
    
    log "Detected file format: $file_format for file: $file" >> "$LOG_FILE"
    
    local qemu_args=()
    local boot_description=""
    
    case $choice in
        1)
            # Enhanced MBR Boot with options
            local prefs=$(get_user_preferences 2048)
            if [ $? -ne 0 ]; then return 1; fi
            local memory="${prefs%%|*}"
            local network="${prefs#*|}"
            local audio="${network#*|}"
            network="${network%%|*}"
            
            qemu_args=($(configure_mbr_boot "$file" "$file_format" "$kvm_option" "$memory" "$network" "$audio"))
            boot_description="Enhanced MBR Boot (${memory}MB RAM, Network: $network, Audio: $audio)"
            ;;
        2)
            # UEFI/EFI Boot
            local prefs=$(get_user_preferences 2048)
            if [ $? -ne 0 ]; then return 1; fi
            local memory="${prefs%%|*}"
            local network="${prefs#*|}"
            local audio="${network#*|}"
            network="${network%%|*}"
            
            qemu_args=($(configure_uefi_boot "$file" "$file_format" "$kvm_option" "$memory" "$network" "$audio"))
            if [ $? -ne 0 ]; then return 1; fi
            boot_description="UEFI/EFI Boot (${memory}MB RAM, Network: $network, Audio: $audio)"
            ;;
        3)
            # Headless Mode
            local prefs=$(get_user_preferences 1024)
            if [ $? -ne 0 ]; then return 1; fi
            local memory="${prefs%%|*}"
            local network="${prefs#*|}"
            local audio="${network#*|}"
            network="${network%%|*}"
            
            qemu_args=($(configure_headless_boot "$file" "$file_format" "$kvm_option" "$memory" "$network"))
            boot_description="Headless Mode (${memory}MB RAM, Network: $network, Audio: disabled)"
            whiptail --msgbox "Headless mode starting.\n\nSSH Access: ssh -p 2222 user@localhost\nMonitor: telnet localhost 4444\n\nTo exit QEMU:\n- Use 'quit' in monitor console\n- Or press Ctrl+A, then X" 14 60
            ;;
        4)
            # Custom Boot
            local custom_args=$(whiptail --title "Custom Options" --inputbox "Enter QEMU arguments (file will be added automatically):" 12 70 "-m 2048 $kvm_option -vga virtio" 3>&1 1>&2 2>&3)
            if [ $? -eq 0 ] && [ -n "$custom_args" ]; then
                qemu_args=(-drive "file=$file,format=$file_format,if=virtio")
                IFS=' ' read -ra ADDR <<< "$custom_args"
                qemu_args+=("${ADDR[@]}")
                boot_description="Custom Boot"
            else
                return 1
            fi
            ;;
        5)
            # Debug Mode
            local prefs=$(get_user_preferences 2048)
            if [ $? -ne 0 ]; then return 1; fi
            local memory="${prefs%%|*}"
            local network="${prefs#*|}"
            local audio="${network#*|}"
            network="${network%%|*}"
            
            qemu_args=($(configure_debug_boot "$file" "$file_format" "$kvm_option" "$memory" "$network" "$audio"))
            boot_description="Debug Mode (${memory}MB RAM, Network: $network, Audio: $audio)"
            ;;
    esac
    
    if ! check_file_lock "$file"; then
        return 1
    fi
    
    # Start QEMU
    log "Attempting to start QEMU with: $boot_description" >> "$LOG_FILE"
    log "Command: qemu-system-x86_64 ${qemu_args[*]}" >> "$LOG_FILE"
    
    local error_log="/tmp/qemu-error-$$.log"
    
    # Handle different execution modes
    if [[ "${qemu_args[*]}" == *"-nographic"* ]]; then
        # Headless mode - run in foreground
        qemu-system-x86_64 "${qemu_args[@]}" 2>>"$error_log"
        local qemu_exit_code=$?
        log "QEMU exited with code: $qemu_exit_code" >> "$LOG_FILE"
        
        if [ $qemu_exit_code -eq 0 ]; then
            whiptail --msgbox "QEMU session completed successfully." 8 50
        else
            whiptail --msgbox "QEMU exited with error code: $qemu_exit_code" 8 50
        fi
        return $qemu_exit_code
    else
        # GUI mode - run in background
        qemu-system-x86_64 "${qemu_args[@]}" </dev/null 2>"$error_log" &
        QEMU_PID=$!
        log "QEMU started with PID: $QEMU_PID, Error log: $error_log" >> "$LOG_FILE"
    fi

    # Check if the process started correctly
    (
        echo 10; echo "# Starting QEMU process..."
        sleep 1
        echo 30; echo "# Checking process status (PID: $QEMU_PID)..."
        sleep 2
        
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            echo 60; echo "# QEMU process is running..."
            sleep 1
            echo 80; echo "# Waiting for initialization..."
            sleep 2
            
            if kill -0 "$QEMU_PID" 2>/dev/null; then
                echo 100; echo "# QEMU started successfully!"
                sleep 1
            else
                echo 100; echo "# QEMU process died during startup"
                sleep 2; exit 1
            fi
        else
            echo 100; echo "# Error: QEMU process failed to start"
            sleep 2; exit 1
        fi
    ) | whiptail --gauge "Starting QEMU..." 8 50 0
    
    if [ $? -eq 0 ]; then
        log "QEMU started successfully: PID $QEMU_PID, Mode: $boot_description" >> "$LOG_FILE"
        
        # Success message with relevant information
        local info_msg="QEMU started successfully!\n\nMode: $boot_description\nPID: $QEMU_PID"
        
        # Add mode-specific information
        case $choice in
            1|2|3|5)
                info_msg+="\n\nFeatures:\n- VirtIO disk and network for better performance\n- SSH forwarding: ssh -p 2222 user@localhost (virtio-net)\n- SSH forwarding: ssh -p 2223 user@localhost (e1000)"
                ;;
            4)
                info_msg+="\n\nAccess:\n- SSH: ssh -p 2222 user@localhost\n- Monitor: telnet localhost 4444"
                ;;
        esac
        
        if [[ "$choice" == "2" || "$choice" == "3" ]]; then
            info_msg+="\n\nEFI Boot:\n- UEFI boot screen may take a moment\n- Serial log: /tmp/qemu-serial-$QEMU_PID.log"
        fi
        
        if [[ "$choice" == "5" ]]; then
            info_msg+="\n\nDebug files:\n- Serial: /tmp/qemu-debug-$QEMU_PID.log\n- Trace: /tmp/qemu-trace-$QEMU_PID.log"
        fi
        
        info_msg+="\n\nClose the QEMU window to terminate.\nIf network is not detected, check VirtIO or e1000 drivers in the guest OS."
        
        whiptail --msgbox "$info_msg" 20 80
        rm -f "$error_log"
    else
        log "QEMU start failed" >> "$LOG_FILE"
        
        local error_details=""
        if [ -f "$error_log" ] && [ -s "$error_log" ]; then
            error_details=$(head -10 "$error_log" | tr '\n' ' ')
            log "QEMU error output: $error_details" >> "$LOG_FILE"
        fi
        
        local error_msg="Error starting QEMU.\n\nMode: $boot_description\nPID: $QEMU_PID"
        
        if [ -n "$error_details" ]; then
            error_msg+="\n\nError details:\n${error_details:0:200}"
        fi
        
        error_msg+="\n\nCheck logs:\n- Main: $LOG_FILE\n- Errors: $error_log"
        
        whiptail --msgbox "$error_msg" 18 80
        QEMU_PID=""
        return 1
    fi
    
    return 0
}