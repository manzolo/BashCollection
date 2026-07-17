# nvidia-manager module: diagnostics and NVIDIA detection
# Sourced by nvidia-manager.sh — do not execute directly.
troubleshoot_nvidia() {
    # Set up trap to catch Ctrl+C and return to menu gracefully
    trap 'echo -e "\n${YELLOW}Returning to main menu...${NC}"; return 0' INT

    log "Running NVIDIA troubleshooting..."

    clear
    echo "=== NVIDIA Troubleshooting Report ==="
    echo "Generated: $(date)"
    echo -e "${GRAY}Press Ctrl+C to return to main menu${NC}"
    echo
    
    # 1. Verifica presenza driver host
    local host_version
    host_version=$(detect_host_nvidia)
    
    # 2. Verifica container
    detect_container_nvidia
    
    # 3. Test OpenGL
    echo "=== OpenGL Test ==="
    if command -v glxinfo >/dev/null 2>&1; then
        local gl_renderer
        gl_renderer=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -n1)
        if [[ "$gl_renderer" =~ NVIDIA ]]; then
            success "$gl_renderer"
        else
            warning "OpenGL renderer: $gl_renderer"
        fi
    else
        warning "glxinfo not available (install mesa-utils)"
    fi
    echo
    
    # 4. Test CUDA (se disponibile)
    echo "=== CUDA Test ==="
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            success "nvidia-smi working"
            nvidia-smi -L 2>/dev/null || warning "Could not list GPU devices"
        else
            error "nvidia-smi failed"
        fi
    else
        warning "nvidia-smi not available"
    fi
    echo
    
    # 5. Verifica device nodes
    echo "=== Device Nodes ==="
    local nvidia_devices=(
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
    )
    
    for device in "${nvidia_devices[@]}"; do
        if [ -e "$device" ]; then
            success "Found: $device"
        else
            warning "Missing: $device"
        fi
    done
    echo
    
    echo
    log "Troubleshooting completed"
    pause_for_enter

    # Remove trap when done
    trap - INT
}

# Rileva driver NVIDIA host
detect_host_nvidia() {
    log "Detecting host NVIDIA driver..."
    
    local host_version=""
    local detection_method=""
    
    # Metodo 1: /proc/driver/nvidia/version
    if [ -f "/proc/driver/nvidia/version" ]; then
        host_version=$(sed -nE 's/.*Module[ \t]+([0-9]+\.[0-9]+).*/\1/p' /proc/driver/nvidia/version | head -n1)
        if [ -n "$host_version" ]; then
            detection_method="/proc/driver/nvidia/version"
        fi
    fi
    
    # Metodo 2: nvidia-smi
    if [ -z "$host_version" ] && command -v nvidia-smi >/dev/null 2>&1; then
        host_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ')
        if [ -n "$host_version" ]; then
            detection_method="nvidia-smi"
        fi
    fi
    
    # Metodo 3: modinfo
    if [ -z "$host_version" ] && command -v modinfo >/dev/null 2>&1; then
        host_version=$(modinfo nvidia 2>/dev/null | grep '^version:' | awk '{print $2}')
        if [ -n "$host_version" ]; then
            detection_method="modinfo"
        fi
    fi
    
    echo "=== Host NVIDIA Driver ==="
    if [ -n "$host_version" ]; then
        success "Version: $host_version"
        echo "Detection method: $detection_method"
        echo "Major version: $(echo "$host_version" | cut -d. -f1)"
    else
        warning "No NVIDIA driver detected on host"
    fi
    echo
    
    echo "$host_version"
}

# Rileva driver container
detect_container_nvidia() {
    log "Detecting container NVIDIA packages..."
    
    echo "=== Container NVIDIA Packages ==="
    
    local nvidia_packages
    nvidia_packages=$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /nvidia/ {printf "%-30s %s\n", $2, $3}')
    
    if [ -n "$nvidia_packages" ]; then
        echo "$nvidia_packages"
        
        # Estrai versione principale
        local main_version
        main_version=$(dpkg -l 2>/dev/null | \
            awk '$1 == "ii" && $2 ~ /^libnvidia-gl-/ {print $3}' | \
            sed -nE 's/^([0-9]+(\.[0-9]+)?).*/\1/p' | \
            head -n1)
        
        if [ -n "$main_version" ]; then
            success "Primary driver version: $main_version"
        fi
    else
        warning "No NVIDIA packages found in container"
    fi
    echo
}

# Main menu
