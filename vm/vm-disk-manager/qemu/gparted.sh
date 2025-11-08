gparted_boot() {
    local file=$1
    local gparted_dir="$HOME/.cache/manzolo_vm_disk_manager/gparted"
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
    
    # Detect disk format
    local format=$(detect_format "$file")
    log "Detected disk format for $file: $format"
    
    # Validate format
    case "$format" in
        raw|qcow2|vpc|vhdx|vmdk)
            log "Supported format: $format"
            ;;
        *)
            log "Unsupported disk format: $format"
            whiptail --msgbox "Unsupported disk format: $format\nSupported formats: raw, qcow2, vpc, vhdx, vmdk" 10 60
            return 1
            ;;
    esac
    
    # Start QEMU with detected format and capture PID
    log "Starting QEMU with GParted Live, disk format: $format"
    (
        echo 0
        echo "# Starting QEMU with GParted Live..."
        qemu-system-x86_64 -drive file="$file",format="$format" -cdrom "$gparted_iso_file" -boot d -m 2048 -enable-kvm </dev/null &>/dev/null &
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
    ) | whiptail --gauge "Starting QEMU with GParted Live..." 8 50 0
    
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