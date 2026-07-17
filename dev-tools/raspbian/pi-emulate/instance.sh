# ==============================================================================
# ENHANCED INSTANCE CREATION
# ==============================================================================

create_instance() {
    local name
    name=$(dialog --inputbox "Instance name:" 8 40 "rpi-$(date +%Y%m%d)" 2>&1 >/dev/tty)
    [ -z "$name" ] && return
    
    local images=$(ls -1 "$IMAGES_DIR"/*.img 2>/dev/null)
    if [ -z "$images" ]; then
        dialog --msgbox "No images available! Download an OS image first." 8 50
        return
    fi
    
    local img_list=""
    local counter=1
    while IFS= read -r img; do
        local basename=$(basename "$img")
        img_list+="$counter \"$basename\" "
        ((counter++))
    done <<< "$images"
    
    local img_choice
    img_choice=$(eval dialog --title \"Select Image\" --menu \"Choose base image:\" 15 60 8 $img_list 2>&1 >/dev/tty)
    [ -z "$img_choice" ] && return
    
    local selected_image=$(echo "$images" | sed -n "${img_choice}p")
    
    local os_type="jessie"
    if [[ "$selected_image" == *"stretch"* ]]; then
        os_type="stretch"
    elif [[ "$selected_image" == *"buster"* ]]; then
        os_type="buster"
    elif [[ "$selected_image" == *"bullseye"* ]]; then
        os_type="bullseye"
    fi
    
    local recommended_kernel=$(auto_select_kernel "$os_type")
    
    local kernel_choice
    kernel_choice=$(dialog --title "Kernel Selection" --menu \
        "Recommended: $recommended_kernel\n\nSelect kernel:" 15 60 5 \
        "1" "Auto-select (recommended)" \
        "2" "Choose manually" \
        "3" "Download new kernel" \
        2>&1 >/dev/tty)
    
    local selected_kernel="$recommended_kernel"
    
    case $kernel_choice in
        2)
            local kernels=$(ls -1 "$KERNELS_DIR"/kernel-* 2>/dev/null)
            if [ -n "$kernels" ]; then
                local kernel_list=""
                counter=1
                while IFS= read -r kernel; do
                    local basename=$(basename "$kernel")
                    kernel_list+="$counter \"$basename\" "
                    ((counter++))
                done <<< "$kernels"
                
                local k_choice
                k_choice=$(eval dialog --title \"Select Kernel\" --menu \"Choose kernel:\" 15 60 8 $kernel_list 2>&1 >/dev/tty)
                [ -n "$k_choice" ] && selected_kernel=$(basename "$(echo "$kernels" | sed -n "${k_choice}p")")
            fi
            ;;
        3)
            download_specific_kernel
            return
            ;;
    esac
    
    local memory
    memory=$(dialog --inputbox "Memory (MB) [128-256]:" 8 40 "$DEFAULT_MEMORY" 2>&1 >/dev/tty)
    [ -z "$memory" ] && memory="$DEFAULT_MEMORY"
    if [[ ! "$memory" =~ ^[0-9]+$ ]] || [ "$memory" -gt 256 ] || [ "$memory" -lt 128 ]; then
        dialog --msgbox "Invalid memory! Using default: 256MB" 8 40
        memory="256"
    fi
    
    local ssh_port
    ssh_port=$(dialog --inputbox "SSH Port:" 8 40 "$DEFAULT_SSH_PORT" 2>&1 >/dev/tty)
    [ -z "$ssh_port" ] && ssh_port="$DEFAULT_SSH_PORT"
    
    local vnc_port
    vnc_port=$(dialog --inputbox "VNC Port (0 to disable):" 8 40 "0" 2>&1 >/dev/tty)
    
    local enable_audio="no"
    if dialog --yesno "Enable audio support?" 8 40; then
        enable_audio="yes"
    fi
    
    local enable_audio="no"
    local available=$(check_audio_support)
    if [ -n "$available" ]; then
        if dialog --yesno "Audio backends detected: $available\n\nEnable audio support?\n(Will be disabled if not functional)" 10 50; then
            enable_audio="yes"
        fi
    else
        dialog --msgbox "No functional audio backends detected.\nAudio will be disabled." 8 50
        enable_audio="no"
    fi
    
    local instance_img="${IMAGES_DIR}/${name}.img"
    echo "Creating instance image..."
    cp "$selected_image" "$instance_img"
    
    #if dialog --yesno "Expand image size?\n\nCurrent: ~2GB\nRecommended for full OS: 4GB+" 10 50; then
    #    local new_size
    #    new_size=$(dialog --inputbox "New size (e.g., 4G, 8G):" 8 40 "4G" 2>&1 >/dev/tty)
    #    if [ -n "$new_size" ]; then
    #        echo "Expanding image to $new_size..."
    #        qemu-img resize "$instance_img" "$new_size"
    #    fi
    #fi
    
    local instance_id=$(date +%s)
    
    echo "${instance_id}|${name}|${instance_img}|${selected_kernel}|${memory}|${ssh_port}|${vnc_port}|${enable_audio}|${audio_backend}|created|$(date +%s)" >> "$INSTANCES_DB"
    
    dialog --msgbox "Instance '$name' created!\n\nID: $instance_id\nKernel: $selected_kernel\nAudio: $enable_audio" 12 50
    
    if dialog --yesno "Start instance now?" 8 30; then
        launch_instance "$instance_id"
    fi
}

# ==============================================================================
# ENHANCED QEMU LAUNCHER WITH AUDIO AND KERNEL FALLBACK
# ==============================================================================

launch_instance() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    
    if [ -z "$instance_data" ]; then
        dialog --msgbox "Instance not found!" 8 30
        return 1
    fi
    
    IFS='|' read -r id name image kernel_name memory ssh_port vnc_port enable_audio audio_backend status created <<< "$instance_data"
    
    # Forza memoria a 256MB per VersatilePB
    if [ "$memory" != "256" ]; then
        memory="256"
        log INFO "Memory forced to 256MB for VersatilePB compatibility"
    fi
    
    if [ -z "$enable_audio" ]; then
        enable_audio="no"
        audio_backend="none"
        vnc_port="0"
    fi
    
    if pgrep -f "$image" > /dev/null; then
        dialog --msgbox "Instance already running!" 8 30
        return
    fi
    
    # Verifica kernel
    local kernel_file="${KERNELS_DIR}/${kernel_name}"
    if [ ! -f "$kernel_file" ]; then
        log WARNING "Kernel $kernel_name not found, attempting to locate similar kernel"
        kernel_file=$(find "$KERNELS_DIR" -name "*${kernel_name}*" | head -1)
        
        if [ ! -f "$kernel_file" ]; then
            dialog --msgbox "Kernel not found!\n\nTrying fallback kernel ($FALLBACK_KERNEL)..." 8 40
            kernel_file="${KERNELS_DIR}/$FALLBACK_KERNEL"
            
            if [ ! -f "$kernel_file" ]; then
                dialog --msgbox "No kernels available! Downloading fallback kernel..." 8 50
                download_kernel_version "4.4.34"
                kernel_file="${KERNELS_DIR}/$FALLBACK_KERNEL"
                if [ ! -f "$kernel_file" ]; then
                    dialog --msgbox "Failed to download fallback kernel!" 8 50
                    return 1
                fi
            fi
        fi
    fi
    
    # Validate audio backend - disabilita se non disponibile
    if [ "$enable_audio" = "yes" ] && [ "$audio_backend" != "none" ]; then
        case $audio_backend in
            pa)
                # Check if PulseAudio is actually running
                if command -v pactl &> /dev/null && pactl info &> /dev/null 2>&1; then
                    # Modern QEMU audio syntax
                    qemu_cmd+=" -audiodev pa,id=audio0,server=unix:/run/user/$(id -u)/pulse/native"
                    qemu_cmd+=" -device AC97,audiodev=audio0"
                    log INFO "PulseAudio audio enabled"
                else
                    log WARNING "PulseAudio not available, disabling audio"
                    enable_audio="no"
                fi
                ;;
            alsa)
                # Check ALSA availability more thoroughly
                if [ -d /proc/asound ] && [ -e /dev/snd/controlC0 ] && command -v aplay &> /dev/null; then
                    # Try to find default ALSA device
                    local alsa_device=$(aplay -l 2>/dev/null | grep "card 0" | head -1 | grep -o "device [0-9]*" | grep -o "[0-9]*" || echo "0")
                    qemu_cmd+=" -audiodev alsa,id=audio0,dev=hw:0,${alsa_device}"
                    qemu_cmd+=" -device AC97,audiodev=audio0"
                    log INFO "ALSA audio enabled with device hw:0,${alsa_device}"
                else
                    log WARNING "ALSA not available, disabling audio"
                    enable_audio="no"
                fi
                ;;
            oss)
                if [ -e /dev/dsp ] || [ -e /dev/audio ]; then
                    qemu_cmd+=" -audiodev oss,id=audio0"
                    qemu_cmd+=" -device AC97,audiodev=audio0"
                    log INFO "OSS audio enabled"
                else
                    log WARNING "OSS not available, disabling audio"
                    enable_audio="no"
                fi
                ;;
            sdl)
                # SDL audio as fallback
                qemu_cmd+=" -audiodev sdl,id=audio0"
                qemu_cmd+=" -device AC97,audiodev=audio0"
                log INFO "SDL audio enabled"
                ;;
            *)
                log WARNING "Unknown audio backend: $audio_backend, disabling audio"
                enable_audio="no"
                ;;
        esac
    fi
    
    clear
    echo "=========================================="
    echo " Starting Instance: $name"
    echo "=========================================="
    echo "Image: $(basename "$image")"
    echo "Kernel: $(basename "$kernel_file")"
    echo "Memory: ${memory}MB (Fixed for VersatilePB)"
    echo "SSH Port: ${ssh_port}"
    [ "$vnc_port" != "0" ] && echo "VNC Port: ${vnc_port}"
    [ "$enable_audio" = "yes" ] && echo "Audio: Enabled (${audio_backend})" || echo "Audio: Disabled"
    echo ""
    echo "IMPORTANT: Boot may take 2-3 minutes!"
    echo "Default login: pi / raspberry"
    echo ""
    echo "To connect:"
    echo "  SSH: ssh -p ${ssh_port} pi@localhost"
    [ "$vnc_port" != "0" ] && echo "  VNC: vncviewer localhost:${vnc_port}"
    echo ""
    echo "To exit QEMU: Press Ctrl+A, then X"
    echo "=========================================="
    echo ""
    
    # Costruzione comando QEMU con rete fissa
    local qemu_cmd="qemu-system-arm"
    qemu_cmd+=" -kernel \"$kernel_file\""
    qemu_cmd+=" -cpu arm1176"
    qemu_cmd+=" -m $memory"
    qemu_cmd+=" -M versatilepb"
    
    local dtb_file="${DTBS_DIR}/versatile-pb.dtb"
    if [ -f "$dtb_file" ]; then
        qemu_cmd+=" -dtb \"$dtb_file\""
    fi
    
    qemu_cmd+=" -append \"root=/dev/sda2 rootfstype=ext4 rw console=ttyAMA0 earlyprintk\""
    qemu_cmd+=" -drive format=raw,file=\"$image\""
    
    # RETE: Usa sempre -nic user come richiesto
    qemu_cmd+=" -nic user,hostfwd=tcp::${ssh_port}-:22"
    
    # Audio solo se abilitato e disponibile
    if [ "$enable_audio" = "yes" ] && [ "$audio_backend" != "none" ]; then
        case $audio_backend in
            pa)
                if command -v pactl &> /dev/null && pactl info &> /dev/null 2>&1; then
                    export QEMU_AUDIO_DRV=pa
                    qemu_cmd+=" -audiodev pa,id=audio0 -device AC97,audiodev=audio0"
                else
                    log WARNING "PulseAudio not available, disabling audio"
                    enable_audio="no"
                fi
                ;;
            alsa)
                if [ -d /proc/asound ] && [ -e /dev/snd/controlC0 ]; then
                    export QEMU_AUDIO_DRV=alsa
                    qemu_cmd+=" -audiodev alsa,id=audio0 -device AC97,audiodev=audio0"
                else
                    log WARNING "ALSA not available, disabling audio"
                    enable_audio="no"
                fi
                ;;
            oss)
                if [ -e /dev/dsp ] || [ -e /dev/audio ]; then
                    export QEMU_AUDIO_DRV=oss
                    qemu_cmd+=" -audiodev oss,id=audio0 -device AC97,audiodev=audio0"
                else
                    log WARNING "OSS not available, disabling audio"
                    enable_audio="no"
                fi
                ;;
            sdl)
                export QEMU_AUDIO_DRV=sdl
                qemu_cmd+=" -audiodev sdl,id=audio0 -device AC97,audiodev=audio0"
                ;;
        esac
    fi
    
    # Display configuration
    if [ "$vnc_port" != "0" ]; then
        qemu_cmd+=" -vnc :$((vnc_port - 5900))"
        qemu_cmd+=" -serial stdio"
    else
        qemu_cmd+=" -serial stdio"
        qemu_cmd+=" -display gtk,grab-on-hover=on"
    fi
    
    qemu_cmd+=" -no-reboot"
    
    echo "Starting QEMU with configuration..."
    log INFO "Launching: $qemu_cmd"
    sleep 2
    
    if ! eval $qemu_cmd; then
        log ERROR "QEMU failed with kernel $kernel_name"
        dialog --msgbox "QEMU failed to start!\nTrying fallback configuration..." 8 50
        
        # Fallback: disabilita audio e usa kernel di fallback
        kernel_file="${KERNELS_DIR}/$FALLBACK_KERNEL"
        if [ ! -f "$kernel_file" ]; then
            log INFO "Downloading fallback kernel $FALLBACK_KERNEL"
            download_kernel_version "4.4.34"
            if [ ! -f "$kernel_file" ]; then
                dialog --msgbox "Failed to download fallback kernel!" 8 50
                return 1
            fi
        fi
        
        # Comando fallback semplificato
        qemu_cmd="qemu-system-arm"
        qemu_cmd+=" -kernel \"$kernel_file\""
        qemu_cmd+=" -cpu arm1176"
        qemu_cmd+=" -m 256"
        qemu_cmd+=" -M versatilepb"
        qemu_cmd+=" -append \"root=/dev/sda2 rootfstype=ext4 rw console=ttyAMA0\""
        qemu_cmd+=" -drive format=raw,file=\"$image\""
        qemu_cmd+=" -nic user,hostfwd=tcp::${ssh_port}-:22"
        qemu_cmd+=" -serial stdio"
        qemu_cmd+=" -no-reboot"
        
        echo "Retrying with simplified fallback configuration..."
        log INFO "Fallback command: $qemu_cmd"
        sleep 2
        
        if ! eval $qemu_cmd; then
            log ERROR "Even fallback configuration failed"
            dialog --msgbox "QEMU failed with fallback configuration!\nCheck system compatibility." 8 50
            return 1
        fi
    fi
    
    echo ""
    read -p "Press ENTER to return to menu..."
}

# ==============================================================================
# ENHANCED INSTANCE MANAGEMENT
# ==============================================================================

list_instances() {
    local instances=""
    local counter=1
    local instance_ids=()
    
    while IFS='|' read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        
        IFS='|' read -r id name image kernel memory ssh_port vnc_port audio_enabled audio_backend status created <<< "$line"
        
        if [ -z "$status" ]; then
            status="$vnc_port"
            vnc_port="0"
            audio_enabled="no"
            audio_backend="none"
        fi
        
        local running_indicator=""
        if pgrep -f "$image" > /dev/null 2>&1; then
            running_indicator=" [RUNNING]"
        fi
        
        local audio_indicator=""
        [ "$audio_enabled" = "yes" ] && audio_indicator=" 🔊"
        
        instances+="$counter \"$name$running_indicator (Port: $ssh_port)$audio_indicator\" "
        instance_ids+=("$id")
        ((counter++))
    done < "$INSTANCES_DB"
    
    if [ -z "$instances" ]; then
        dialog --msgbox "No instances found!" 8 30
        return
    fi
    
    local choice
    choice=$(eval dialog --title \"Instances\" --menu \"Select instance:\" 15 70 10 $instances 2>&1 >/dev/tty)
    [ -z "$choice" ] && return
    
    local selected_id="${instance_ids[$((choice-1))]}"
    manage_instance_by_id "$selected_id"
}

manage_instance_by_id() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    
    if [ -z "$instance_data" ]; then
        dialog --msgbox "Instance not found!" 8 30
        return
    fi
    
    IFS='|' read -r id name image kernel memory ssh_port vnc_port audio_enabled audio_backend status created <<< "$instance_data"
    
    local is_running=false
    if pgrep -f "$image" > /dev/null 2>&1; then
        is_running=true
    fi
    
    local status_text="Stopped"
    [ "$is_running" = true ] && status_text="Running"
    
    local action
    action=$(dialog --title "Instance: $name [$status_text]" --menu "Select action:" 18 50 10 \
        "1" "Start" \
        "2" "Stop" \
        "3" "SSH Connect" \
        "4" "VNC Connect" \
        "5" "Edit Configuration" \
        "6" "Clone" \
        "7" "Create Snapshot" \
        "8" "Delete" \
        "9" "Properties" \
        "0" "Back" \
        2>&1 >/dev/tty)
    
    case $action in
        1) launch_instance "$id" ;;
        2) stop_instance "$id" ;;
        3) connect_ssh "$ssh_port" ;;
        4) connect_vnc "$vnc_port" ;;
        5) edit_instance_config "$id" ;;
        6) clone_instance "$id" ;;
        7) create_snapshot "$id" ;;
        8) delete_instance "$id" ;;
        9) show_properties "$id" ;;
    esac
}

edit_instance_config() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    
    IFS='|' read -r id name image kernel memory ssh_port vnc_port audio_enabled audio_backend status created <<< "$instance_data"
    
    # Memory configuration
    local new_memory
    new_memory=$(dialog --inputbox "Memory (MB) [128-256]:" 8 40 "$memory" 2>&1 >/dev/tty)
    [ -z "$new_memory" ] && new_memory="$memory"
    if [[ ! "$new_memory" =~ ^[0-9]+$ ]] || [ "$new_memory" -gt 256 ] || [ "$new_memory" -lt 128 ]; then
        dialog --msgbox "Invalid memory! Using previous value: $memory MB" 8 40
        new_memory="$memory"
    fi
    
    # SSH Port configuration
    local new_ssh_port
    new_ssh_port=$(dialog --inputbox "SSH Port:" 8 40 "$ssh_port" 2>&1 >/dev/tty)
    [ -z "$new_ssh_port" ] && new_ssh_port="$ssh_port"
    
    # VNC Port configuration
    local new_vnc_port
    new_vnc_port=$(dialog --inputbox "VNC Port (0 to disable):" 8 40 "$vnc_port" 2>&1 >/dev/tty)
    [ -z "$new_vnc_port" ] && new_vnc_port="$vnc_port"
    
    # Kernel selection
    local kernels=$(ls -1 "$KERNELS_DIR"/kernel-* 2>/dev/null)
    local new_kernel="$kernel"
    
    if [ -n "$kernels" ]; then
        local kernel_list=""
        local counter=1
        local kernel_array=()
        
        # Current kernel as first option
        kernel_list+="$counter \"$kernel (current)\" "
        kernel_array+=("$kernel")
        ((counter++))
        
        # Add other available kernels
        while IFS= read -r kernel_file; do
            local basename=$(basename "$kernel_file")
            if [ "$basename" != "$kernel" ]; then
                kernel_list+="$counter \"$basename\" "
                kernel_array+=("$basename")
                ((counter++))
            fi
        done <<< "$kernels"
        
        # Add download option
        kernel_list+="$counter \"Download new kernel...\" "
        kernel_array+=("download_new")
        
        local kernel_choice
        kernel_choice=$(eval dialog --title \"Kernel Selection\" --menu \"Current: $kernel\n\nSelect kernel:\" 15 70 8 $kernel_list 2>&1 >/dev/tty)
        
        if [ -n "$kernel_choice" ]; then
            local selected_option="${kernel_array[$((kernel_choice-1))]}"
            
            if [ "$selected_option" = "download_new" ]; then
                # Show download menu
                local download_choice
                download_choice=$(dialog --title "Download Kernel" --menu "Select kernel to download:" 15 60 6 \
                    "1" "4.4.34 (Jessie - Legacy)" \
                    "2" "4.14.79 (Stretch - Stable)" \
                    "3" "5.4.51 (Buster - Modern)" \
                    "4" "5.10.63 (Bullseye - Latest)" \
                    "5" "Auto-select for OS" \
                    2>&1 >/dev/tty)
                
                case $download_choice in
                    1) download_kernel_version "4.4.34" && new_kernel="kernel-qemu-4.4.34-jessie" ;;
                    2) download_kernel_version "4.14.79" && new_kernel="kernel-qemu-4.14.79-stretch" ;;
                    3) download_kernel_version "5.4.51" && new_kernel="kernel-qemu-5.4.51-buster" ;;
                    4) download_kernel_version "5.10.63" && new_kernel="kernel-qemu-5.10.63-bullseye" ;;
                    5) 
                        # Auto-detect OS type from image name and download appropriate kernel
                        local os_type="jessie"  # default
                        if [[ "$image" == *"stretch"* ]]; then
                            os_type="stretch"
                            download_kernel_version "4.14.79" && new_kernel="kernel-qemu-4.14.79-stretch"
                        elif [[ "$image" == *"buster"* ]]; then
                            os_type="buster"
                            download_kernel_version "5.4.51" && new_kernel="kernel-qemu-5.4.51-buster"
                        elif [[ "$image" == *"bullseye"* ]]; then
                            os_type="bullseye"
                            download_kernel_version "5.10.63" && new_kernel="kernel-qemu-5.10.63-bullseye"
                        else
                            download_kernel_version "4.4.34" && new_kernel="kernel-qemu-4.4.34-jessie"
                        fi
                        ;;
                esac
            else
                new_kernel="$selected_option"
            fi
        fi
    else
        dialog --msgbox "No kernels found!\nDownloading default kernel..." 8 40
        download_kernel_version "4.4.34"
        new_kernel="kernel-qemu-4.4.34-jessie"
    fi
    
    # Verify selected kernel exists
    if [ ! -f "${KERNELS_DIR}/${new_kernel}" ]; then
        dialog --msgbox "Selected kernel not found!\nUsing previous kernel: $kernel" 10 50
        new_kernel="$kernel"
    fi
    
    # Audio configuration
    local new_audio_enabled="$audio_enabled"
    local available=$(check_audio_support)
    
    if [ -n "$available" ]; then
        if dialog --yesno "Enable audio?\n\nDetected: $available" 10 40; then
            new_audio_enabled="yes"
        else
            new_audio_enabled="no"
        fi
    else
        dialog --msgbox "No functional audio backends available!\nAudio will be disabled." 8 50
        new_audio_enabled="no"
    fi
    
    local new_audio_backend="none"
    if [ "$new_audio_enabled" = "yes" ] && [ -n "$available" ]; then
        # Test più accurato per backend audio
        if echo "$available" | grep -q "pa" && pactl info &> /dev/null 2>&1; then
            new_audio_backend="pa"
        elif echo "$available" | grep -q "alsa" && [ -e /dev/snd/controlC0 ]; then
            new_audio_backend="alsa"
        else
            dialog --msgbox "Audio requested but not functional!\nDisabling audio." 8 50
            new_audio_enabled="no"
            new_audio_backend="none"
        fi
    fi
    
    # Update instance in database
    sed -i "/^$instance_id|/d" "$INSTANCES_DB"
    echo "${id}|${name}|${image}|${new_kernel}|${new_memory}|${new_ssh_port}|${new_vnc_port}|${new_audio_enabled}|${new_audio_backend}|${status}|${created}" >> "$INSTANCES_DB"
    
    # Show summary of changes
    local summary=""
    summary+="Configuration updated!\n\n"
    summary+="Instance: $name\n"
    summary+="Memory: $memory MB → $new_memory MB\n"
    summary+="SSH Port: $ssh_port → $new_ssh_port\n"
    summary+="VNC Port: $vnc_port → $new_vnc_port\n"
    summary+="Kernel: $kernel → $new_kernel\n"
    summary+="Audio: $audio_enabled → $new_audio_enabled"
    [ "$new_audio_enabled" = "yes" ] && summary+=" ($new_audio_backend)"
    summary+="\n"
    
    dialog --msgbox "$summary" 15 60
}

stop_instance() {
    local instance_id=$1
    
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    if [ -z "$instance_data" ]; then
        dialog --msgbox "Instance not found!" 8 30
        return
    fi
    
    IFS='|' read -r id name image kernel memory ssh_port vnc_port audio_enabled audio_backend status created <<< "$instance_data"
    
    local qemu_pids=$(pgrep -f "qemu-system-arm.*$(basename "$image")" || true)
    
    if [ -n "$qemu_pids" ]; then
        echo "$qemu_pids" | xargs kill -TERM 2>/dev/null || true
        dialog --msgbox "Instance stopped." 8 30
    else
        dialog --msgbox "Instance no
        
        t running!" 8 30
    fi
}

clone_instance() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel memory ssh_port vnc_port audio_enabled audio_backend status created <<< "$instance_data"
    
    local new_name
    new_name=$(dialog --inputbox "Clone name:" 8 40 "${name}-clone" 2>&1 >/dev/tty)
    [ -z "$new_name" ] && return
    
    local new_image="${IMAGES_DIR}/${new_name}.img"
    echo "Cloning instance..."
    cp "$image" "$new_image"
    
    local new_id=$(date +%s)
    echo "${new_id}|${new_name}|${new_image}|${kernel}|${memory}|$((ssh_port + 1))|${vnc_port}|${audio_enabled}|${audio_backend}|created|$(date +%s)" >> "$INSTANCES_DB"
    
    dialog --msgbox "Instance cloned successfully!" 8 40
}

delete_instance() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel memory ssh_port vnc_port audio_enabled audio_backend status created <<< "$instance_data"
    
    if dialog --yesno "Delete instance '$name'?\n\nThis will remove the image file!" 10 50; then
        rm -f "$image"
        sed -i "/^$instance_id|/d" "$INSTANCES_DB"
        dialog --msgbox "Instance deleted!" 8 30
    fi
}