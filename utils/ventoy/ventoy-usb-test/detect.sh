# Detect system capabilities
detect_system() {
    local sys_cores sys_memory_gb kvm_status
    
    sys_cores=$(nproc)
    sys_memory_gb=$(( $(free -m | awk '/^Mem:/{print $2}') / 1024 ))
    
    if [[ -c /dev/kvm && -r /dev/kvm ]]; then
        kvm_status="Available ✓"
    else
        kvm_status="Not available ✗"
    fi
    
    whiptail --title "System Information" --msgbox \
        "Detected System:\n\n• CPU Cores: $sys_cores\n• RAM: ${sys_memory_gb}GB\n• KVM: $kvm_status\n\nRecommendations:\n• CPU Cores: max $sys_cores\n• RAM: max $(( sys_memory_gb * 1024 / 2 ))MB" \
        15 50
    
    # Adjust values if necessary
    if [[ $CORES -gt $sys_cores ]]; then
        CORES="$sys_cores"
    fi
}

# Detect USB devices
detect_usb_devices() {
    local devices=()
    local all_disks_info
    
    # Use lsblk with JSON output for better processing
    all_disks_info=$(lsblk -d -J -o NAME,SIZE,HOTPLUG,RM,TYPE,LABEL,TRAN 2>/dev/null | jq -c '.blockdevices[]' 2>/dev/null)
    
    # Handle case where lsblk or jq fails or no devices are found
    if [[ -z "$all_disks_info" ]]; then
        whiptail --title "Error" --msgbox "Unable to retrieve device list" 10 50
        echo "BROWSE 'Browse image file (ISO/IMG)...'"
        echo "CUSTOM 'Custom path...'"
        return
    fi

    # Process each device
    while IFS= read -r disk; do
        local name=$(jq -r '.name' <<< "$disk" 2>/dev/null)
        local size=$(jq -r '.size' <<< "$disk" 2>/dev/null)
        local rm=$(jq -r '.rm' <<< "$disk" 2>/dev/null)
        local type=$(jq -r '.type' <<< "$disk" 2>/dev/null)
        local label=$(jq -r '.label' <<< "$disk" 2>/dev/null)
        local tran=$(jq -r '.tran' <<< "$disk" 2>/dev/null)
        
        [[ -z "$name" ]] && continue

        local full_device="/dev/$name"
        local desc="$full_device ($size)"
        
        # Add device to list only if it is a removable USB disk
        if [[ "$type" == "disk" && ( "$rm" == "1" || "$tran" == "usb" ) ]]; then
            [[ -n "$label" && "$label" != "null" ]] && desc="$desc - $label"
            devices+=("$full_device" "$desc")
        fi
    done <<< "$all_disks_info"

    # Add standard options
    devices+=("BROWSE" "Browse image file (ISO/IMG)...")
    devices+=("CUSTOM" "Custom path...")
    
    # Handle case where no USB devices are detected
    if [[ ${#devices[@]} -eq 2 ]]; then  # Only BROWSE and CUSTOM
        whiptail --title "No USB Devices" --msgbox \
            "No USB devices detected. You can select an image file." 10 50
    fi
    
    # Return array for whiptail
    printf '%s\n' "${devices[@]}"
}

# Show detailed hardware information
show_hardware_info() {
    local info=""
    
    # CPU Info
    local cpu_info=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
    local cpu_cores=$(nproc)
    local cpu_freq=$(lscpu | grep "CPU max MHz" | cut -d: -f2 | xargs || echo "N/A")
    
    # Memory Info
    local mem_total=$(free -h | awk '/^Mem:/{print $2}')
    local mem_avail=$(free -h | awk '/^Mem:/{print $7}')
    
    # Storage Info
    local disk_info=""
    if [[ -n "$DISK" && -b "$DISK" ]]; then
        disk_info=$(lsblk -d -o MODEL,SIZE "$DISK" 2>/dev/null | tail -1 || echo "N/A")
    fi
    
    # Virtualization
    local virt_support="No"
    if grep -q "vmx\|svm" /proc/cpuinfo; then
        virt_support="Yes ($(grep -o "vmx\|svm" /proc/cpuinfo | head -1 | tr 'a-z' 'A-Z'))"
    fi
    
    info="SYSTEM HARDWARE INFORMATION\n\n"
    info+="CPU:\n  ${cpu_info}\n  Cores: ${cpu_cores}\n  Max Freq: ${cpu_freq} MHz\n\n"
    info+="MEMORY:\n  Total: ${mem_total}\n  Available: ${mem_avail}\n\n"
    info+="VIRTUALIZATION:\n  Support: ${virt_support}\n  KVM: $([[ -c /dev/kvm ]] && echo "Available" || echo "Not available")\n\n"
    
    if [[ -n "$disk_info" ]]; then
        info+="SELECTED DISK:\n  ${disk_info}\n\n"
    fi
    
    info+="QEMU:\n  Version: $(qemu-system-x86_64 --version | head -1 || echo "N/A")"
    
    whiptail --title "Hardware Information" --scrolltext \
        --msgbox "$info" 20 70
}

# Disk speed test
test_disk_speed() {
    if [[ -z "$DISK" ]]; then
        whiptail --title "Error" --msgbox "Select a disk first!" 8 40
        return
    fi
    
    if [[ ! -b "$DISK" ]]; then
        whiptail --title "Info" --msgbox "Disk speed test is only available for block devices." 10 50
        return
    fi
    
    if ! whiptail --title "Disk Speed Test" --yesno \
        "Test read speed of $DISK?\n\nThe test is safe (read-only)." \
        10 50; then
        return
    fi
    
    local temp_result=$(mktemp)
    
    {
        echo "10"; echo "# Preparing test..."
        sleep 1
        echo "30"; echo "# Sequential read test..."
        sudo hdparm -t "$DISK" > "$temp_result" 2>&1 || echo "hdparm error" > "$temp_result"
        echo "70"; echo "# Cache read test..."
        sudo hdparm -T "$DISK" >> "$temp_result" 2>&1 || echo "Cache test error" >> "$temp_result"
        echo "100"; echo "# Completed"
    } | whiptail --gauge "Disk speed test in progress..." 8 50 0
    
    local result
    result=$(cat "$temp_result")
    rm -f "$temp_result"
    
    whiptail --title "Disk Speed Test Results" --scrolltext \
        --msgbox "Device: $DISK\n\n$result" 15 70
}

# Simple CPU benchmark
benchmark_cpu() {
    if ! command -v bc >/dev/null; then
        whiptail --title "Error" --msgbox \
            "bc (calculator) is not installed.\nInstall with: sudo apt install bc" \
            10 50
        return
    fi
    
    if ! whiptail --title "CPU Benchmark" --yesno \
        "Run a quick CPU benchmark?\n\nDuration: approximately 10 seconds." \
        10 50; then
        return
    fi
    
    local result=""
    
    {
        echo "20"; echo "# Calculating Pi..."
        local pi_time
        pi_time=$(time (echo "scale=1000; 4*a(1)" | bc -l) 2>&1 | grep real | awk '{print $2}')
        
        echo "60"; echo "# Arithmetic test..."
        local arith_start arith_end arith_time
        arith_start=$(date +%s%N)
        for i in {1..100000}; do
            echo "scale=2; sqrt($i)" | bc -l >/dev/null
        done
        arith_end=$(date +%s%N)
        arith_time=$(echo "scale=3; ($arith_end - $arith_start) / 1000000000" | bc)
        
        echo "100"; echo "# Completed"
        
        result="CPU BENCHMARK\n\n"
        result+="CPU: $(nproc) cores\n"
        result+="Model: $(lscpu | grep "Model name" | cut -d: -f2 | xargs)\n\n"
        result+="Pi calculation (1000 decimals): ${pi_time}\n"
        result+="Arithmetic test (100k ops): ${arith_time}s\n\n"
        result+="Note: Results are indicative for relative comparison"
        
    } | whiptail --gauge "Benchmark in progress..." 8 50 0
    
    whiptail --title "Benchmark Results" --scrolltext \
        --msgbox "$result" 15 60
}