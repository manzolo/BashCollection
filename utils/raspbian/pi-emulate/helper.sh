show_properties() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel_name memory ssh_port vnc_port audio_enabled audio_backend status created <<< "$instance_data"
    
    local props=""
    props+="Instance Properties:\n\n"
    props+="Name: $name\n"
    props+="ID: $id\n"
    props+="Image: $(basename "$image")\n"
    props+="Kernel: $kernel_name\n"
    props+="Memory: ${memory}MB\n"
    props+="SSH Port: $ssh_port\n"
    props+="VNC Port: ${vnc_port}\n"
    props+="Audio: ${audio_enabled} (${audio_backend})\n"
    props+="Status: $status\n"
    props+="Created: $(date -d "@$created" 2>/dev/null || echo "$created")\n"
    
    if [ -f "$image" ]; then
        local size=$(du -h "$image" | cut -f1)
        props+="Image Size: $size\n"
    fi
    
    dialog --title "Properties" --msgbox "$props" 15 50
}

# ==============================================================================
# PERFORMANCE TIPS
# ==============================================================================

show_performance_tips() {
    local tips=""
    tips+="QEMU Raspberry Pi - Enhanced Performance Guide\n"
    tips+="==============================================\n\n"
    
    tips+="🎯 OPTIMAL CONFIGURATIONS:\n\n"
    
    tips+="Best OS/Kernel Combinations:\n"
    tips+="✅ Bullseye + kernel 5.10.63 - MODERN\n"
    tips+="✅ Buster + kernel 5.4.51 - RECOMMENDED\n"
    tips+="✅ Stretch + kernel 4.14.79 - STABLE\n"
    tips+="✅ Jessie + kernel 4.4.34 - LEGACY\n\n"
    
    tips+="🔊 AUDIO CONFIGURATION:\n"
    tips+="• PulseAudio: Best compatibility\n"
    tips+="• ALSA: Lower latency\n"
    tips+="• Device: AC97 emulation\n"
    tips+="• Ensure audio backend is running\n\n"
    
    tips+="⚡ PERFORMANCE OPTIMIZATIONS:\n"
    tips+="• Memory: 128-256MB (VersatilePB limit)\n"
    tips+="• Use SSD for image storage\n"
    tips+="• Enable KSM for multiple instances\n"
    tips+="• Close unnecessary host applications\n\n"
    
    tips+="🌐 NETWORK PERFORMANCE:\n"
    tips+="• Modern syntax: -netdev user + -device\n"
    tips+="• RTL8139 NIC for compatibility\n"
    tips+="• Port forwarding for services\n\n"
    
    tips+="💡 TIPS:\n"
    tips+="• First boot takes longer (2-3 min)\n"
    tips+="• Expand image for more storage\n"
    tips+="• Create snapshots before major changes\n"
    tips+="• Use VNC for GUI applications\n\n"
    
    tips+="⚠️ LIMITATIONS:\n"
    tips+="• Single-core ARM emulation only\n"
    tips+="• No GPU acceleration\n"
    tips+="• No KVM on x86 for ARM guests\n"
    tips+="• Memory capped at 256MB for VersatilePB\n"
    
    dialog --title "Enhanced Performance Tips" --msgbox "$tips" 24 70
}

# ==============================================================================
# SYSTEM DIAGNOSTICS
# ==============================================================================

system_diagnostics() {
    local diag_info=""
    
    diag_info+="QEMU RPi Manager v${VERSION}\n"
    diag_info+="================================\n\n"
    
    diag_info+="QEMU Version:\n$(qemu-system-arm --version | head -1)\n\n"
    
    diag_info+="Host System:\n"
    diag_info+="  CPU: $(lscpu | grep "Model name" | cut -d: -f2 | xargs)\n"
    diag_info+="  Cores: $(nproc)\n"
    diag_info+="  RAM: $(free -h | grep "Mem:" | awk '{print $2}')\n"
    diag_info+="  Kernel: $(uname -r)\n\n"
    
    diag_info+="Audio Support:\n"
    local audio_available=$(check_audio_support)
    if [ -n "$audio_available" ]; then
        diag_info+="  Available: $audio_available\n"
    else
        diag_info+="  Not configured\n"
    fi
    diag_info+="\n"
    
    local running_count=$(pgrep -c qemu-system-arm 2>/dev/null || echo 0)
    diag_info+="Running Instances: $running_count\n\n"
    
    diag_info+="Storage Usage:\n"
    diag_info+="  Images: $(du -sh "$IMAGES_DIR" 2>/dev/null | awk '{print $1}')\n"
    diag_info+="  Kernels: $(du -sh "$KERNELS_DIR" 2>/dev/null | awk '{print $1}')\n"
    diag_info+="  Snapshots: $(du -sh "$SNAPSHOTS_DIR" 2>/dev/null | awk '{print $1}')\n"
    diag_info+="  Cache: $(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')\n\n"
    
    diag_info+="Available Resources:\n"
    diag_info+="  Images: $(ls -1 "$IMAGES_DIR"/*.img 2>/dev/null | wc -l)\n"
    diag_info+="  Kernels: $(ls -1 "$KERNELS_DIR"/kernel-* 2>/dev/null | wc -l)\n"
    diag_info+="  Snapshots: $(ls -1 "$SNAPSHOTS_DIR"/*.img 2>/dev/null | wc -l)\n\n"
    
    diag_info+="Modern Kernels (5.x):\n"
    for kernel in "$KERNELS_DIR"/kernel-*5.*; do
        if [ -f "$kernel" ]; then
            diag_info+="  ✓ $(basename "$kernel")\n"
        fi
    done
    
    local free_space=$(df -h "$WORK_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    diag_info+="\nFree Disk Space: $free_space\n"
    
    dialog --title "System Diagnostics" --msgbox "$diag_info" 22 70
}