# ==============================================================================
# QUICK START WITH AUTO-DETECTION
# ==============================================================================

quick_start() {
    dialog --title "Quick Start" --infobox "Auto-detecting best configuration..." 5 45
    
    local best_image=""
    local best_kernel=""
    local os_type=""
    
    for img_type in  "jessie_2017" "stretch_2018" "buster_2020"; do
        local img_file="${IMAGES_DIR}/${img_type}_full.img"
        if [ -f "$img_file" ]; then
            best_image="$img_file"
            
            if [[ "$img_type" == *"buster"* ]]; then
                os_type="buster"
                best_kernel="kernel-qemu-5.4.51-buster"
            elif [[ "$img_type" == *"stretch"* ]]; then
                os_type="stretch"
                best_kernel="kernel-qemu-4.14.79-stretch"
            else
                os_type="jessie"
                best_kernel="kernel-qemu-4.4.34-jessie"
            fi
            break
        fi
    done
    
    if [ -z "$best_image" ]; then
        dialog --msgbox "No OS images found.\nDownloading Raspbian Jessie (best compatibility)..." 8 50
        download_single_image "jessie_2017_full"
        best_image="${IMAGES_DIR}/jessie_2017_full.img"
        os_type="jessie"
        best_kernel="kernel-qemu-4.4.34-jessie"
    fi
    
    local kernel_file="${KERNELS_DIR}/${best_kernel}"
    if [ ! -f "$kernel_file" ]; then
        echo "Downloading optimal kernel..."
        
        if [ "$os_type" = "buster" ]; then
            download_kernel_version "5.4.51"
        elif [ "$os_type" = "stretch" ]; then
            download_kernel_version "4.14.79"
        else
            download_kernel_version "4.4.34"
        fi
    fi
   
    if [ ! -f "$kernel_file" ]; then
        dialog --msgbox "Failed to prepare kernel!" 8 40
        return
    fi
    
    # Test audio più robusto
    local audio_backend="none"
    local audio_enabled="no"

    # Diagnosi audio dettagliata
    echo "Diagnosing audio support..."

    # Test 1: Check PulseAudio
    if command -v pactl &> /dev/null; then
        echo "PulseAudio command found"
        if pactl info &> /dev/null 2>&1; then
            echo "PulseAudio server is running"
            # Test se QEMU può usare PulseAudio
            if timeout 3s qemu-system-arm -audiodev pa,id=test -M versatilepb -display none -serial null -monitor null </dev/null &>/dev/null; then
                audio_backend="pa"
                audio_enabled="yes"
                echo "PulseAudio compatible with QEMU"
            else
                echo "QEMU cannot use PulseAudio"
            fi
        else
            echo "PulseAudio server not running, trying to start..."
            pulseaudio --start --daemonize 2>/dev/null || echo "Failed to start PulseAudio"
        fi
    else
        echo "PulseAudio not installed"
    fi

    # Test 2: Check ALSA se PulseAudio fallisce
    if [ "$audio_enabled" = "no" ] && [ -d /proc/asound ]; then
        echo "Testing ALSA..."
        if timeout 3s qemu-system-arm -audiodev alsa,id=test -M versatilepb -display none -serial null -monitor null </dev/null &>/dev/null; then
            audio_backend="alsa"
            audio_enabled="yes"
            echo "ALSA compatible with QEMU"
        else
            echo "QEMU cannot use ALSA"
        fi
    fi

    # Test 3: SDL fallback
    if [ "$audio_enabled" = "no" ]; then
        echo "Testing SDL audio..."
        if timeout 3s qemu-system-arm -audiodev sdl,id=test -M versatilepb -display none -serial null -monitor null </dev/null &>/dev/null; then
            audio_backend="sdl"
            audio_enabled="yes"
            echo "SDL audio compatible with QEMU"
        else
            echo "SDL audio not available"
        fi
    fi

    # Se nessun backend funziona, disabilita audio
    if [ "$audio_enabled" = "no" ]; then
        echo "No functional audio backends found - audio will be disabled"
        log WARNING "Audio backends detected but not functional with QEMU"
    fi
    
    clear
    echo "=========================================="
    echo " Quick Start - Auto Configuration"
    echo "=========================================="
    echo "OS: Raspbian $(echo $os_type | tr '[:lower:]' '[:upper:]')"
    echo "Kernel: Modern $(basename "$kernel_file")"
    echo "Memory: 256MB (Fixed for VersatilePB)"
    echo "SSH Port: ${DEFAULT_SSH_PORT}"
    echo "Network: User mode with port forwarding"
    [ "$audio_enabled" = "yes" ] && echo "Audio: Enabled ($audio_backend)" || echo "Audio: Disabled (not functional)"
    echo ""
    echo "Default credentials:"
    echo "Username: pi"
    echo "Password: raspberry"
    echo ""
    echo "To connect via SSH (after boot):"
    echo "ssh -p ${DEFAULT_SSH_PORT} pi@localhost"
    echo ""
    echo "IMPORTANT: Boot may take 2-3 minutes!"
    echo "To exit QEMU: Press Ctrl+A, then X"
    echo "=========================================="
    echo ""
    echo "Starting QEMU with optimized settings..."
    sleep 3
    
    # Comando QEMU semplificato e robusto
    local qemu_cmd="qemu-system-arm"
    qemu_cmd+=" -kernel \"$kernel_file\""
    qemu_cmd+=" -cpu arm1176"
    qemu_cmd+=" -m 256"
    qemu_cmd+=" -M versatilepb"
    qemu_cmd+=" -append \"root=/dev/sda2 rootfstype=ext4 rw console=ttyAMA0\""
    qemu_cmd+=" -drive format=raw,file=\"$best_image\""
    qemu_cmd+=" -nic user,hostfwd=tcp::${DEFAULT_SSH_PORT}-:22"

    # Audio con sintassi corretta e test
    if [ "$audio_enabled" = "yes" ]; then
        case $audio_backend in
            pa)
                qemu_cmd+=" -audiodev pa,id=audio0"
                qemu_cmd+=" -device AC97,audiodev=audio0"
                ;;
            alsa)
                qemu_cmd+=" -audiodev alsa,id=audio0"
                qemu_cmd+=" -device AC97,audiodev=audio0"
                ;;
            sdl)
                qemu_cmd+=" -audiodev sdl,id=audio0"
                qemu_cmd+=" -device AC97,audiodev=audio0"
                ;;
        esac
        log INFO "Audio enabled with $audio_backend backend"
    else
        log INFO "Audio disabled - no functional backends"
    fi

    qemu_cmd+=" -serial stdio"
    qemu_cmd+=" -no-reboot"

    # Log del comando per debug
    log INFO "QEMU command: $qemu_cmd"

    if ! eval $qemu_cmd; then
        log ERROR "Quick start failed, trying without audio"
        
        # Retry senza audio
        qemu_cmd="qemu-system-arm"
        qemu_cmd+=" -kernel \"$kernel_file\""
        qemu_cmd+=" -cpu arm1176"
        qemu_cmd+=" -m 256"
        qemu_cmd+=" -M versatilepb"
        qemu_cmd+=" -append \"root=/dev/sda2 rootfstype=ext4 rw console=ttyAMA0\""
        qemu_cmd+=" -drive format=raw,file=\"$best_image\""
        qemu_cmd+=" -nic user,hostfwd=tcp::${DEFAULT_SSH_PORT}-:22"
        qemu_cmd+=" -serial stdio"
        qemu_cmd+=" -no-reboot"
        
        echo "Retrying without audio..."
        sleep 2
        
        if ! eval $qemu_cmd; then
            # Ultimo tentativo con kernel di fallback
            log ERROR "Quick start failed, trying fallback kernel"
            kernel_file="${KERNELS_DIR}/$FALLBACK_KERNEL"
            if [ ! -f "$kernel_file" ]; then
                download_kernel_version "4.4.34"
            fi
            
            if [ -f "$kernel_file" ]; then
                qemu_cmd="qemu-system-arm -kernel \"$kernel_file\" -cpu arm1176 -m 256 -M versatilepb"
                qemu_cmd+=" -append \"root=/dev/sda2 rootfstype=ext4 rw console=ttyAMA0\""
                qemu_cmd+=" -drive format=raw,file=\"$best_image\""
                qemu_cmd+=" -nic user,hostfwd=tcp::${DEFAULT_SSH_PORT}-:22 -serial stdio -no-reboot"
                
                echo "Final attempt with fallback kernel..."
                eval $qemu_cmd || dialog --msgbox "All attempts failed! Check system compatibility." 8 50
            fi
        fi
    fi
    
    echo ""
    read -p "Press ENTER to return to menu..."
}
