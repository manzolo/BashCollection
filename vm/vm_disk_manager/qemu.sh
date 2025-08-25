# Function to test the VM with QEMU
test_vm_qemu() {
    local file=$1
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        whiptail --msgbox "qemu-system-x86_64 not found.\nInstall with: apt install qemu-system-x86" 10 60
        return 1
    fi
    
    local qemu_options=(
        "1" "Avvio MBR (Legacy)"
        "2" "Avvio UEFI/EFI (con 2GB RAM)"
        "3" "Avvio UEFI/EFI (con 4GB RAM)"
        "4" "Headless (solo MBR)"
        "5" "Avvio Personalizzato"
    )
    
    local choice=$(whiptail --title "Test VM with QEMU" --menu "Select boot mode:" 15 60 5 "${qemu_options[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local qemu_cmd="qemu-system-x86_64"
    local qemu_args=()
    
    case $choice in
        1)
            # Avvio MBR (Legacy) - questo è l'avvio predefinito
            qemu_args=("-hda" "$file" "-m" "2048" "-enable-kvm")
            ;;
        2)
            # Avvio UEFI/EFI
            if [ ! -f "/usr/share/ovmf/OVMF.fd" ]; then
                whiptail --msgbox "Il firmware OVMF non è stato trovato.\nInstalla il pacchetto 'ovmf' con 'sudo apt install ovmf'." 12 70
                return 1
            fi
            qemu_args=("-hda" "$file" "-m" "2048" "-enable-kvm" "-bios" "/usr/share/ovmf/OVMF.fd")
            ;;
        3)
            # Avvio UEFI/EFI con 4GB di RAM
            if [ ! -f "/usr/share/ovmf/OVMF.fd" ]; then
                whiptail --msgbox "Il firmware OVMF non è stato trovato.\nInstalla il pacchetto 'ovmf' con 'sudo apt install ovmf'." 12 70
                return 1
            fi
            qemu_args=("-hda" "$file" "-m" "4096" "-enable-kvm" "-bios" "/usr/share/ovmf/OVMF.fd")
            ;;
        4)
            # Headless (solo MBR)
            qemu_args=("-hda" "$file" "-m" "1024" "-nographic" "-enable-kvm")
            whiptail --msgbox "Modalità headless.\nPremi Ctrl+A, X per uscire da QEMU." 10 60
            ;;
        5)
            # Avvio Personalizzato
            local custom_args=$(whiptail --title "Opzioni Personalizzate" --inputbox "Inserisci argomenti aggiuntivi per QEMU:" 10 70 "-m 2048 -enable-kvm" 3>&1 1>&2 2>&3)
            if [ $? -eq 0 ] && [ -n "$custom_args" ]; then
                qemu_args=("-hda" "$file")
                IFS=' ' read -ra ADDR <<< "$custom_args"
                qemu_args+=("${ADDR[@]}")
            else
                return 1
            fi
            ;;
    esac
    
    if ! check_file_lock "$file"; then
        return 1
    fi
    
    (
        echo 0
        echo "# Starting QEMU..."
        "$qemu_cmd" "${qemu_args[@]}" </dev/null &>/dev/null &
        QEMU_PID=$!
        sleep 3
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            echo 100
            echo "# QEMU started!"
            sleep 1
        else
            echo 100
            echo "# QEMU failed to start"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Starting QEMU..." 8 50 0
    
    if [ $? -eq 0 ]; then
        log "QEMU started: PID $QEMU_PID, Command: $qemu_cmd ${qemu_args[*]}"
        whiptail --msgbox "QEMU started successfully!\n\nPID: $QEMU_PID\nCommand: $qemu_cmd ${qemu_args[*]}\n\nClose the QEMU window or use the menu to terminate." 15 80
    else
        log "QEMU start failed"
        whiptail --msgbox "Error starting QEMU." 8 50
        QEMU_PID=""
        return 1
    fi
    
    return 0
}

# Function to boot GParted Live ISO with QEMU
gparted_boot() {
    local file=$1
    local gparted_dir="${SCRIPT_DIR}/gparted"  # Use fixed script dir instead of PWD
    local gparted_iso_version="1.7.0-8"
    local gparted_iso_filename="gparted-live-${gparted_iso_version}-amd64.iso"
    local gparted_iso_url="https://sourceforge.net/projects/gparted/files/gparted-live-stable/${gparted_iso_version}/${gparted_iso_filename}/download"
    local gparted_iso_file="$gparted_dir/$gparted_iso_filename"
    
    # Checksum file from gparted.org
    local checksum_url="https://gparted.org/gparted-live/stable/CHECKSUMS.TXT"
    local checksum_file="$gparted_dir/CHECKSUMS.TXT"
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        whiptail --msgbox "qemu-system-x86_64 not found.\nInstall with: apt install qemu-system-x86" 10 60
        return 1
    fi
    
    mkdir -p "$gparted_dir"
    log "Gparted location: $gparted_dir"
    
    # Ensure checksum file exists (download if missing)
    if [ ! -f "$checksum_file" ]; then
        log "Downloading checksum file..."
        wget -O "$checksum_file" "$checksum_url" 2>>"$LOG_FILE"
        if [ $? -ne 0 ]; then
            log "Error downloading checksum file."
            whiptail --msgbox "Error downloading checksum file." 8 50
            return 1
        fi
    fi
    
    # Extract expected SHA256 from checksum file (under ### SHA256SUMS:)
    local expected_sha256=$(awk '
        /### SHA256SUMS:/ {found=1; next}
        found && /^###/ {found=0; next}
        found && $2 == "'"$gparted_iso_filename"'" {print $1; exit}
    ' "$checksum_file")
    
    if [ -z "$expected_sha256" ]; then
        log "Could not extract SHA256 for $gparted_iso_filename from checksum file."
        whiptail --msgbox "Could not find SHA256 checksum in file. It may be corrupted or mismatched." 10 60
        rm "$checksum_file"
        return 1
    fi
    log "Expected SHA256 from checksum file: $expected_sha256"
    
    # Verify if ISO exists and matches checksum
    if [ ! -f "$gparted_iso_file" ]; then
        log "ISO file not found, proceeding with download."
    else
        # Compute checksum of existing file
        local computed_sha256=$(cd "$gparted_dir" && sha256sum "$gparted_iso_filename" | cut -d' ' -f1)
        log "Computed SHA256: $computed_sha256, Expected: $expected_sha256"
        if [ "$computed_sha256" != "$expected_sha256" ]; then
            log "Checksum mismatch, removing existing file and downloading again."
            rm "$gparted_iso_file"
        else
            log "Checksum verified, using existing ISO file."
        fi
    fi
    
    if [ ! -f "$gparted_iso_file" ]; then
        # Download ISO (checksum is already handled)
        (
            echo 0
            echo "# Downloading GParted Live ISO..."
            wget -O "$gparted_iso_file" "$gparted_iso_url" 2>>"$LOG_FILE"
            echo 100
            echo "# Download complete!"
            sleep 1
        ) | whiptail --gauge "Downloading GParted Live ISO..." 8 50 0
        
        if [ $? -ne 0 ]; then
            log "Error downloading GParted ISO."
            whiptail --msgbox "Error downloading GParted ISO." 8 50
            rm "$checksum_file"  # Clean up
            return 1
        fi
    fi
    
    # Verify checksum after download (or re-verify existing)
    (
        echo 0
        echo "# Verifying checksum..."
        cd "$gparted_dir"
        local computed_sha256=$(sha256sum "$gparted_iso_filename" | cut -d' ' -f1)
        if [ "$computed_sha256" = "$expected_sha256" ]; then
            echo 100
            echo "# Checksum verified successfully!"
            sleep 1
        else
            echo 100
            echo "# Checksum verification failed!"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Verifying GParted ISO..." 8 50 0
    
    if [ $? -ne 0 ]; then
        log "Checksum verification failed for GParted ISO."
        whiptail --msgbox "Checksum verification failed.\nThe downloaded file may be corrupted. Please try again." 10 60
        rm "$gparted_iso_file" "$checksum_file"
        return 1
    fi
    
    if ! check_file_lock "$file"; then
        return 1
    fi
    
    # Start QEMU and capture PID
    echo 0
    echo "# Starting QEMU with GParted Live..."
    qemu-system-x86_64 -hda "$file" -cdrom "$gparted_iso_file" -boot d -m 2048 -enable-kvm </dev/null &>/dev/null &
    QEMU_PID=$!
    sleep 3
    if kill -0 "$QEMU_PID" 2>/dev/null; then
        echo 100
        echo "# QEMU started!"
        sleep 1
    else
        echo 100
        echo "# QEMU failed to start"
        sleep 2
        exit 1
    fi | whiptail --gauge "Starting QEMU with GParted Live..." 8 50 0
    
    if [ $? -eq 0 ]; then
        log "GParted QEMU started: PID $QEMU_PID"
        whiptail --msgbox "QEMU started successfully!\n\nPID: $QEMU_PID\n\nYou can now use GParted Live to resize the partitions inside the VM.\nLogin password: live" 15 80
    else
        log "GParted QEMU start failed"
        whiptail --msgbox "Error starting QEMU." 8 50
        QEMU_PID=""
        return 1
    fi
    
    return 0
}