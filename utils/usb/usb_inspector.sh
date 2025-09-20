#!/bin/bash

# USB Inspector v4.0
# Script to correctly identify USB disks and adapters with performance
# Enhanced visual output with beautiful tables and colors
# Author: Manzolo
# Date: 20/09/2025

# Force C locale for consistent numeric calculations
export LC_NUMERIC=C
export LC_ALL=C

# Enhanced color palette
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
LIGHT_BLUE='\033[1;34m'
LIGHT_GREEN='\033[1;32m'
LIGHT_CYAN='\033[1;36m'
LIGHT_MAGENTA='\033[1;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'
DIM='\033[2m'

# Box drawing characters
TOP_LEFT="╔"
TOP_RIGHT="╗"
BOTTOM_LEFT="╚"
BOTTOM_RIGHT="╝"
HORIZONTAL="═"
VERTICAL="║"
CROSS="╬"
T_DOWN="╦"
T_UP="╩"
T_RIGHT="╠"
T_LEFT="╣"

# Function to draw a colored separator line
draw_separator() {
    local length=$1
    local color=$2
    printf "${color}"
    for ((i=0; i<length; i++)); do
        printf "═"
    done
    printf "${NC}\n"
}

# Function to draw a fancy header box
draw_header_box() {
    local title="$1"
    local width=80
    local title_length=${#title}
    local padding=$(( (width - title_length - 2) / 2 ))
    
    echo -e "${LIGHT_CYAN}${TOP_LEFT}$(printf '%.0s'"${HORIZONTAL}" $(seq 1 $((width-2))))${TOP_RIGHT}${NC}"
    printf "${LIGHT_CYAN}${VERTICAL}${NC}"
    printf "%*s" $padding ""
    printf "${BOLD}${WHITE}%s${NC}" "$title"
    printf "%*s" $((width - title_length - padding - 2)) ""
    printf "${LIGHT_CYAN}${VERTICAL}${NC}\n"
    echo -e "${LIGHT_CYAN}${BOTTOM_LEFT}$(printf '%.0s'"${HORIZONTAL}" $(seq 1 $((width-2))))${BOTTOM_RIGHT}${NC}"
}

# Function to determine USB version from speed
get_usb_version() {
    local speed=$1
    case $speed in
        "1.5") echo "USB 1.0 (1.5 Mbps)" ;;
        "12") echo "USB 1.1 (12 Mbps)" ;;
        "480") echo "USB 2.0 (480 Mbps)" ;;
        "5000") echo "USB 3.0 (5 Gbps)" ;;
        "10000") echo "USB 3.1 Gen2 (10 Gbps)" ;;
        "20000") echo "USB 3.2 (20 Gbps)" ;;
        "40000") echo "USB 4.0 (40 Gbps)" ;;
        *) echo "Unknown ($speed Mbps)" ;;
    esac
}

# Function to get USB speed color
get_speed_color() {
    local speed=$1
    case $speed in
        "480") echo "$YELLOW" ;;      # USB 2.0
        "5000") echo "$LIGHT_BLUE" ;; # USB 3.0
        "10000") echo "$LIGHT_GREEN" ;; # USB 3.1
        "20000"|"40000") echo "$LIGHT_MAGENTA" ;; # USB 3.2+
        *) echo "$GRAY" ;;
    esac
}

# Function to convert bytes to human-readable format
human_readable() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" == "0" ]; then
        echo "N/A"
        return
    fi
    
    local -a units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    local size=$bytes
    
    while (( $(LC_NUMERIC=C echo "$size >= 1024" | bc -l) )) && [ $unit -lt 4 ]; do
        size=$(LC_NUMERIC=C echo "scale=1; $size / 1024" | bc -l)
        ((unit++))
    done
    
    LC_NUMERIC=C printf "%.1f%s" "$size" "${units[$unit]}"
}

# Function to get USB info from a block device
get_usb_info_from_block() {
    local block_device=$1
    local block_name=$(basename "$block_device")
    
    local real_path=$(readlink -f "/sys/block/$block_name")
    local current_path="$real_path"
    
    for i in {1..10}; do
        if [ -f "$current_path/idVendor" ] && [ -f "$current_path/idProduct" ]; then
            local vendor=$(cat "$current_path/idVendor" 2>/dev/null)
            local product=$(cat "$current_path/idProduct" 2>/dev/null)
            local speed=$(cat "$current_path/speed" 2>/dev/null)
            echo "$vendor:$product:$speed"
            return 0
        fi
        current_path=$(dirname "$current_path")
        if [ "$current_path" == "/" ] || [ "$current_path" == "/sys" ]; then
            break
        fi
    done
    
    return 1
}

# Function to check if a device is USB
is_usb_device() {
    local block_device=$1
    local block_name=$(basename "$block_device")
    
    if readlink -f "/sys/block/$block_name" | grep -q "usb"; then
        return 0
    fi
    
    return 1
}

# Enhanced performance test function
test_performance() {
    local device=$1
    local usb_speed=$2
    
    if [ ! -b "$device" ] || [ "$EUID" -ne 0 ]; then
        echo "N/A|${GRAY}Need sudo${NC}"
        return
    fi
    
    local theoretical_speed=0
    case $usb_speed in
        "480") theoretical_speed=50 ;;
        "5000") theoretical_speed=400 ;;
        "10000") theoretical_speed=800 ;;
        "20000") theoretical_speed=1600 ;;
        *) echo "Unknown|Unknown"; return ;;
    esac
    
    local total_speed=0
    local valid_tests=0
    
    for i in {1..3}; do
        local test_result=$(timeout 3s dd if="$device" of=/dev/null bs=1M count=5 iflag=direct 2>&1 | grep -oE '[0-9]+([.,][0-9]+)? [MG]B/s' | head -1)
        
        if [ ! -z "$test_result" ]; then
            local actual_speed=$(echo "$test_result" | grep -oE '[0-9]+([.,][0-9]+)?' | sed 's/,/./')
            local unit=$(echo "$test_result" | grep -oE '[MG]B/s')
            
            if [[ "$unit" == *"GB/s"* ]]; then
                actual_speed=$(LC_NUMERIC=C echo "$actual_speed * 1024" | bc -l)
            fi
            
            total_speed=$(LC_NUMERIC=C echo "$total_speed + $actual_speed" | bc -l)
            ((valid_tests++))
        fi
    done
    
    if [ $valid_tests -gt 0 ]; then
        local avg_speed=$(LC_NUMERIC=C echo "scale=1; $total_speed / $valid_tests" | bc -l)
        local efficiency=$(LC_NUMERIC=C echo "scale=0; ($avg_speed * 100) / $theoretical_speed" | bc -l 2>/dev/null)
        
        if [ ! -z "$efficiency" ] && [ "$efficiency" -gt 0 ]; then
            if [ "$efficiency" -gt 85 ]; then
                echo -e "▰▰▰▰▰|${LIGHT_GREEN}Excellent (${efficiency}%)${NC}"
            elif [ "$efficiency" -gt 65 ]; then
                echo -e "▰▰▰▰▱|${YELLOW}Good (${efficiency}%)${NC}"
            elif [ "$efficiency" -gt 40 ]; then
                echo -e "▰▰▰▱▱|${RED}Fair (${efficiency}%)${NC}"
            else
                echo -e "▰▰▱▱▱|${RED}Poor (${efficiency}%)${NC}"
            fi
        else
            echo "Test Failed|Test Failed"
        fi
    else
        echo "Cannot Test|Cannot Test"
    fi
}

# Function to extract emoji and type from styled device type
get_device_type_and_icon() {
    local vendor_id=$1
    local product_id=$2
    local description=$3
    local device_type=""
    local icon=""
    
    case "$vendor_id:$product_id" in
        "0bda:9210"|"0bda:9201")
            device_type="USB-SATA Adapter"
            icon="🔌"
            ;;
        "413c:"*)
            device_type="Keyboard"
            icon="⌨️"
            ;;
        "054c:"*)
            device_type="Game Controller"
            icon="🎮"
            ;;
        "03f0:"*)
            device_type="Mouse"
            icon="🖱️"
            ;;
        "8087:"*)
            device_type="Bluetooth"
            icon="📶"
            ;;
        "1b1c:"*)
            device_type="RGB Controller"
            icon="💡"
            ;;
        "0c45:"*)
            device_type="Camera"
            icon="📷"
            ;;
        "1d6b:"*|"1a40:"*|"05e3:"*)
            device_type="USB Hub"
            icon="🔗"
            ;;
        *)
            device_type="USB Device"
            icon="🔌"
            ;;
    esac
    echo "$device_type|$icon"
}

# Header
clear
echo ""
draw_header_box "USB INSPECTOR v4.0"
echo ""

# Check dependencies
MISSING_DEPS=""
for cmd in lsusb lsblk bc; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_DEPS="$MISSING_DEPS $cmd"
    fi
done

if [ ! -z "$MISSING_DEPS" ]; then
    echo -e "${RED}❌ Missing dependencies:$MISSING_DEPS${NC}"
    echo -e "Install with: ${CYAN}sudo apt-get install usbutils util-linux bc${NC}"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}⚠️  For performance tests, run with: ${BOLD}sudo $0${NC}"
    echo ""
fi

# USB Storage Devices Section
echo -e "${BOLD}${LIGHT_CYAN}📦 DETECTED USB STORAGE DEVICES${NC}"
draw_separator 80 "$LIGHT_CYAN"
echo ""

# Storage table header
printf "${BOLD}${WHITE}%-12s %-10s %-22s %-20s %-15s %s %s${NC}\n" \
    "DEVICE" "CAPACITY" "USB VERSION" "MODEL" "MOUNT POINT" "PERF" "PERFORMANCE"

printf "${DIM}%s %s %s %s %s %s %s${NC}\n" \
    "────────────" "──────────" "──────────────────────" "────────────────────" "───────────────" "─────" "───────────────"

# Array to store USB storage info
declare -a usb_storage_devices

# Find USB storage devices
for device in /dev/sd* /dev/nvme*n*; do
    if [ ! -b "$device" ] || [[ "$device" =~ [0-9]+$ ]]; then
        continue
    fi
    
    if is_usb_device "$device"; then
        device_name=$(basename "$device")
        usb_info=$(get_usb_info_from_block "$device")
        
        # Get size
        if [ -f "/sys/block/$device_name/size" ]; then
            sectors=$(cat "/sys/block/$device_name/size")
            size_bytes=$((sectors * 512))
            size=$(human_readable $size_bytes)
        else
            size="Unknown"
        fi
        
        # Get model
        model="Unknown"
        if [ -f "/sys/block/$device_name/device/model" ]; then
            model=$(cat "/sys/block/$device_name/device/model" | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        fi
        
        # Mount point
        mount_point=$(lsblk -no MOUNTPOINT "$device" 2>/dev/null | grep -v "^$" | head -1)
        if [ -z "$mount_point" ]; then
            for part in ${device}[0-9]* ${device}p[0-9]*; do
                if [ -b "$part" ]; then
                    mp=$(lsblk -no MOUNTPOINT "$part" 2>/dev/null | grep -v "^$" | head -1)
                    if [ ! -z "$mp" ]; then
                        mount_point="$mp"
                        break
                    fi
                fi
            done
        fi
        [ -z "$mount_point" ] && mount_point="Not mounted"
        
        # USB information
        if [ ! -z "$usb_info" ]; then
            IFS=':' read -r vendor_id product_id speed <<< "$usb_info"
            usb_version=$(get_usb_version "$speed")
            speed_color=$(get_speed_color "$speed")
            
            # Performance test
            if [ "$EUID" -eq 0 ]; then
                printf "${DIM}  Testing $device...${NC}\r"
                performance=$(test_performance "$device" "$speed")
                printf "                    \r"
            else
                performance="${GRAY}N/A${NC}|${GRAY}Need sudo${NC}"
            fi
        else
            vendor_id="Unknown"
            product_id="Unknown"
            usb_version="Unknown"
            speed_color="$GRAY"
            performance="N/A|N/A"
        fi
        
        # Split performance into indicator and description
        IFS='|' read -r perf_indicator perf_description <<< "$performance"
        
        # Print storage device row with reordered columns
        printf "${BOLD}${WHITE}%-12s ${LIGHT_GREEN}%-10s ${speed_color}%-22s ${LIGHT_MAGENTA}%-20s ${LIGHT_CYAN}%-15s %-5s %-15s${NC}\n" \
            "$device" \
            "$size" \
            "$usb_version" \
            "${model:0:20}" \
            "${mount_point:0:15}" \
            "$perf_indicator" \
            "$perf_description"
        
        usb_storage_devices+=("$device|$vendor_id:$product_id|$model|$size|$usb_version|$mount_point|$performance")
    fi
done

if [ ${#usb_storage_devices[@]} -eq 0 ]; then
    echo -e "${GRAY}No USB storage devices detected${NC}"
fi

echo ""

# USB Adapters and Other Devices Section
echo -e "${BOLD}${YELLOW}🔌 DETECTED USB ADAPTERS & DEVICES${NC}"
draw_separator 80 "$YELLOW"
echo ""

# Function to strip ANSI color codes for accurate length calculation
strip_ansi() {
    local text="$1"
    echo "$text" | sed -r 's/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g'
}

# Table header
printf "${BOLD}${WHITE}%-20s %-15s %-35s %-22s %-5s${NC}\n" \
    "TYPE" "VENDOR:PRODUCT" "MODEL" "USB VERSION" "ICON"

printf "${DIM}%s %s %s %s %s${NC}\n" \
    "────────────────────" "───────────────" "───────────────────────────────────" "──────────────────────" "─────"

# Track what we've already shown as storage
declare -A shown_devices

lsusb | while IFS= read -r line; do
    vendor_id=$(echo "$line" | grep -oP 'ID \K[0-9a-f]{4}')
    product_id=$(echo "$line" | grep -oP 'ID [0-9a-f]{4}:\K[0-9a-f]{4}')
    description=$(echo "$line" | cut -d' ' -f7-)
    
    if [ -z "$vendor_id" ] || [ -z "$product_id" ]; then
        continue
    fi
    
    # Skip root hubs
    if [[ "$description" == *"root hub"* ]]; then
        continue
    fi
    
    # Get USB speed
    speed=""
    for dev_path in /sys/bus/usb/devices/*; do
        if [ -f "$dev_path/idVendor" ] && [ -f "$dev_path/idProduct" ]; then
            dev_vendor=$(cat "$dev_path/idVendor" 2>/dev/null)
            dev_product=$(cat "$dev_path/idProduct" 2>/dev/null)
            if [ "$dev_vendor" == "$vendor_id" ] && [ "$dev_product" == "$product_id" ]; then
                speed=$(cat "$dev_path/speed" 2>/dev/null)
                break
            fi
        fi
    done
    
    usb_version=$(get_usb_version "$speed")
    speed_color=$(get_speed_color "$speed")
    
    # Get device type and icon
    IFS='|' read -r device_type icon <<< "$(get_device_type_and_icon "$vendor_id" "$product_id" "$description")"
    
    # Check if already shown as storage
    is_storage=0
    for storage_info in "${usb_storage_devices[@]}"; do
        if [[ "$storage_info" == *"$vendor_id:$product_id"* ]]; then
            is_storage=1
            break
        fi
    done
    
    # Skip if already shown as storage
    [ $is_storage -eq 1 ] && continue
    
    # Format fields with consistent width
    vendor_product="${vendor_id}:${product_id}"
    model_truncated="${description:0:35}"
    usb_version_truncated="${usb_version:0:22}"
    
    # Print device row with adjusted alignment
    printf "${WHITE}%-20s ${LIGHT_GREEN}%s%-*s${NC} ${LIGHT_BLUE}%-35s ${speed_color}%-22s ${YELLOW}%-5s${NC}\n" \
        "$device_type" \
        "$vendor_product" \
        $((15 - ${#vendor_product})) "" \
        "$model_truncated" \
        "$usb_version_truncated" \
        "$icon"
done

echo ""

# Statistics and Summary
total_usb_storage=${#usb_storage_devices[@]}
echo -e "${BOLD}${LIGHT_CYAN}📊 SUMMARY${NC}"
draw_separator 80 "$LIGHT_CYAN"
echo -e "${LIGHT_GREEN}✅ USB storage devices found: ${BOLD}$total_usb_storage${NC}"

# Show detailed analysis for storage devices
if [ $total_usb_storage -gt 0 ]; then
    echo ""
    echo -e "${BOLD}${LIGHT_MAGENTA}🔍 DETAILED ANALYSIS${NC}"
    draw_separator 80 "$LIGHT_MAGENTA"
    
    for info in "${usb_storage_devices[@]}"; do
        IFS='|' read -r device ids model size usb_version mount_point performance <<< "$info"
        
        echo ""
        echo -e "${CYAN}📱 Device: ${BOLD}$device${NC}"
        echo -e "   ${GRAY}├─${NC} Vendor/Product ID: ${LIGHT_GREEN}$ids${NC}"
        echo -e "   ${GRAY}├─${NC} Model: ${LIGHT_BLUE}$model${NC}"
        echo -e "   ${GRAY}├─${NC} Capacity: ${LIGHT_GREEN}$size${NC}"
        echo -e "   ${GRAY}├─${NC} USB Version: ${LIGHT_CYAN}$usb_version${NC}"
        echo -e "   ${GRAY}├─${NC} Mount Point: ${YELLOW}$mount_point${NC}"
        echo -e "   ${GRAY}└─${NC} Performance: ${performance}"
        
        # Show partitions
        echo -e "   ${GRAY}└─${NC} Partitions:"
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$device" 2>/dev/null | tail -n +2 | while read line; do
            echo -e "      ${DIM}$line${NC}"
        done
        
        # Show disk usage if mounted
        if [ "$mount_point" != "Not mounted" ]; then
            df_info=$(df -h "$mount_point" 2>/dev/null | tail -1)
            if [ ! -z "$df_info" ]; then
                used=$(echo $df_info | awk '{print $3}')
                avail=$(echo $df_info | awk '{print $4}')
                percent=$(echo $df_info | awk '{print $5}')
                echo -e "      ${LIGHT_GREEN}💾 Usage: $used used / $avail free ($percent full)${NC}"
            fi
        fi
    done
fi

echo ""
echo -e "${BOLD}${YELLOW}💡 PERFORMANCE OPTIMIZATION TIPS${NC}"
draw_separator 80 "$YELLOW"
echo -e "${LIGHT_BLUE}🔌${NC} Use USB 3.0+ ports (blue/teal colored) for best performance"
echo -e "${LIGHT_BLUE}🚫${NC} Avoid USB hubs for high-speed storage devices"
echo -e "${LIGHT_BLUE}⚡${NC} For detailed tests: ${CYAN}sudo hdparm -tT /dev/sdX${NC}"
echo -e "${LIGHT_BLUE}📊${NC} For benchmarks: ${CYAN}sudo fio --name=test --filename=/dev/sdX --rw=read --bs=1M --size=100M${NC}"
echo -e "${LIGHT_BLUE}🌡️${NC} Monitor temperature: ${CYAN}sudo hddtemp /dev/sdX${NC}"

echo ""
echo -e "${BOLD}${LIGHT_CYAN}🎛️  SYSTEM USB CONTROLLERS${NC}"
draw_separator 80 "$LIGHT_CYAN"
lspci | grep -i usb | while read controller; do
    echo -e "${LIGHT_GREEN}🔧${NC} $controller"
done

echo ""
draw_separator 80 "$LIGHT_GREEN"
echo -e "${BOLD}${LIGHT_GREEN}✅ Scan completed successfully!${NC}"
echo ""