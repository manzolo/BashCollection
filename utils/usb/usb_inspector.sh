#!/bin/bash

# USB Inspector v5.0
# Script to correctly identify USB disks and adapters with performance
# Enhanced visual output with beautiful tables and colors
# Now with HTML report generation capability
# Author: Manzolo
# Date: 20/09/2025

# Force C locale for consistent numeric calculations
export LC_NUMERIC=C
export LC_ALL=C

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HTML_TEMPLATE_FILE="/tmp/usb_inspector_template.html"
HTML_OUTPUT_FILE="$SCRIPT_DIR/usb_inspector_report_$(date +%Y%m%d_%H%M%S).html"

readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# ───────────────────────────────
# Load helper scripts
# ───────────────────────────────
load_modules() {
    for script in "$SCRIPT_DIR/usb_inspector/"*.sh; do
        if [ -f "$script" ]; then
            source "$script"
        else
            echo "Error: missing module $script"
            exit 1
        fi
    done
}

load_modules

# Get the actual user when running with sudo
ACTUAL_USER=${SUDO_USER:-$(whoami)}
ACTUAL_HOME=$(getent passwd $ACTUAL_USER | cut -d: -f6)

# Parse command line arguments
HTML_MODE=0
for arg in "$@"; do
    case $arg in
        --html)
            HTML_MODE=1
            shift
            ;;
        --help|-h)
            echo "USB Inspector v5.0"
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --html    Generate HTML report and open in browser"
            echo "  --help    Show this help message"
            echo ""
            echo "Run with sudo for performance tests:"
            echo "  sudo $0"
            echo "  sudo $0 --html"
            exit 0
            ;;
    esac
done

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

# HTML data storage
HTML_STORAGE_DATA=""
HTML_ADAPTER_DATA=""
HTML_CONTROLLER_DATA=""
HTML_SUMMARY_DATA=""

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

# Function to determine USB version and theoretical speed
get_usb_version_and_speed() {
    local speed=$1
    case $speed in
        "1.5") echo "USB 1.0|1.5 Mbps|1.5" ;;
        "12") echo "USB 1.1|12 Mbps|12" ;;
        "480") echo "USB 2.0|480 Mbps|480" ;;
        "5000") echo "USB 3.0/3.1 Gen1|5 Gbps|5000" ;;
        "10000") echo "USB 3.1 Gen2|10 Gbps|10000" ;;
        "20000") echo "USB 3.2 Gen2x2|20 Gbps|20000" ;;
        "40000") echo "USB4|40 Gbps|40000" ;;
        *) echo "Unknown|Unknown|0" ;;
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

# Function to get USB speed color for HTML
get_speed_color_html() {
    local speed=$1
    case $speed in
        "480") echo "#fbbf24" ;;      # USB 2.0 - yellow
        "5000") echo "#60a5fa" ;;     # USB 3.0 - blue
        "10000") echo "#34d399" ;;    # USB 3.1 - green
        "20000"|"40000") echo "#a78bfa" ;; # USB 3.2+ - purple
        *) echo "#9ca3af" ;;           # Unknown - gray
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
        echo "N/A|${GRAY}Need sudo${NC}|0|N/A"
        return
    fi
    
    local theoretical_speed=0
    case $usb_speed in
        "480") theoretical_speed=50 ;;
        "5000") theoretical_speed=400 ;;
        "10000") theoretical_speed=800 ;;
        "20000") theoretical_speed=1600 ;;
        *) echo "Unknown|Unknown|0|N/A"; return ;;
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
            local rating=""
            if [ "$efficiency" -gt 85 ]; then
                echo -e "▰▰▰▰▰|${LIGHT_GREEN}Excellent (${efficiency}%)${NC}|$efficiency|Excellent"
                rating="Excellent"
            elif [ "$efficiency" -gt 65 ]; then
                echo -e "▰▰▰▰▱|${YELLOW}Good (${efficiency}%)${NC}|$efficiency|Good"
                rating="Good"
            elif [ "$efficiency" -gt 40 ]; then
                echo -e "▰▰▰▱▱|${RED}Fair (${efficiency}%)${NC}|$efficiency|Fair"
                rating="Fair"
            else
                echo -e "▰▰▱▱▱|${RED}Poor (${efficiency}%)${NC}|$efficiency|Poor"
                rating="Poor"
            fi
        else
            echo "Test Failed|Test Failed|0|Failed"
        fi
    else
        echo "Cannot Test|Cannot Test|0|N/A"
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

# Main execution starts here

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

# Create HTML template if needed
if [ $HTML_MODE -eq 1 ]; then
    create_html_template
fi

# Start timing for report generation
START_TIME=$(date +%s)

# Console output header (skip if HTML mode)
if [ $HTML_MODE -eq 0 ]; then
    clear
    echo ""
    draw_header_box "USB INSPECTOR v5.0"
    echo ""
    
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}⚠️  For performance tests, run with: ${BOLD}sudo $0${NC}"
        echo ""
    fi
fi

# USB Storage Devices Section
if [ $HTML_MODE -eq 0 ]; then
    echo -e "${BOLD}${LIGHT_CYAN}📦 DETECTED USB STORAGE DEVICES${NC}"
    draw_separator 95 "$LIGHT_CYAN"
    echo ""
    
    # Storage table header
    printf "${BOLD}${WHITE}%-12s %-10s %-12s %-10s %-20s %-15s %-5s %s${NC}\n" \
        "DEVICE" "CAPACITY" "USB VERSION" "T. SPEED" "MODEL" "MOUNT POINT" "PERF" "PERFORMANCE"
    
    printf "${DIM}%s %s %s %s %s %s %s %s${NC}\n" \
        "────────────" "──────────" "────────────" "──────────" "────────────────────" "───────────────" "─────" "───────────────"
fi

# Array to store USB storage info
declare -a usb_storage_devices
TOTAL_CAPACITY_BYTES=0

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
            TOTAL_CAPACITY_BYTES=$((TOTAL_CAPACITY_BYTES + size_bytes))
        else
            size="Unknown"
            size_bytes=0
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
            IFS='|' read -r usb_version theoretical_speed speed_raw <<< "$(get_usb_version_and_speed "$speed")"
            speed_color=$(get_speed_color "$speed")
            speed_color_html=$(get_speed_color_html "$speed")
            
            # Performance test
            if [ "$EUID" -eq 0 ]; then
                if [ $HTML_MODE -eq 0 ]; then
                    printf "${DIM}  Testing $device...${NC}\r"
                fi
                performance=$(test_performance "$device" "$speed_raw")
                if [ $HTML_MODE -eq 0 ]; then
                    printf "                    \r"
                fi
            else
                performance="${GRAY}N/A${NC}|${GRAY}Need sudo${NC}|0|N/A"
            fi
        else
            vendor_id="Unknown"
            product_id="Unknown"
            usb_version="Unknown"
            theoretical_speed="N/A"
            speed_color="$GRAY"
            speed_color_html="#9ca3af"
            performance="N/A|N/A|0|N/A"
        fi
        
        # Split performance into components
        IFS='|' read -r perf_indicator perf_description perf_value perf_rating <<< "$performance"
        
        # Console output
        if [ $HTML_MODE -eq 0 ]; then
            printf "${BOLD}${WHITE}%-12s ${LIGHT_GREEN}%-10s ${speed_color}%-12s ${LIGHT_MAGENTA}%-10s ${LIGHT_BLUE}%-20s ${LIGHT_CYAN}%-15s %-5s %-15s${NC}\n" \
                "$device" \
                "$size" \
                "$usb_version" \
                "$theoretical_speed" \
                "${model:0:20}" \
                "${mount_point:0:15}" \
                "$perf_indicator" \
                "$perf_description"
        fi
        
        # HTML data collection
        if [ $HTML_MODE -eq 1 ]; then
            usb_class=$(echo "$usb_version" | tr ' ' '-' | tr '.' '-' | tr '/' '-' | tr '[A-Z]' '[a-z]')
            perf_bar=""
            if [ "$perf_value" != "0" ] && [ "$perf_value" != "N/A" ]; then
                perf_class=$(echo "$perf_rating" | tr '[A-Z]' '[a-z]')
                perf_bar="<div class='performance-bar'><div class='performance-fill $perf_class' style='width: ${perf_value}%'>${perf_value}%</div></div>"
            else
                perf_bar="<span style='color: #94a3b8; font-style: italic;'>${perf_rating}</span>"
            fi
            
            HTML_STORAGE_DATA="${HTML_STORAGE_DATA}<tr>"
            HTML_STORAGE_DATA="${HTML_STORAGE_DATA}<td><span class='device-path' data-full-path='$device'>$device</span></td>"
            HTML_STORAGE_DATA="${HTML_STORAGE_DATA}<td style='font-weight: 600; color: #10b981;'>$size</td>"
            HTML_STORAGE_DATA="${HTML_STORAGE_DATA}<td><span class='usb-version $usb_class'>$usb_version</span></td>"
            HTML_STORAGE_DATA="${HTML_STORAGE_DATA}<td style='color: $speed_color_html; font-weight: 600;'>$theoretical_speed</td>"
            HTML_STORAGE_DATA="${HTML_STORAGE_DATA}<td>${model}</td>"
            if [ "$mount_point" != "Not mounted" ]; then
                HTML_STORAGE_DATA="${HTML_STORAGE_DATA}<td><span class='mount-point'>$mount_point</span></td>"
            else
                HTML_STORAGE_DATA="${HTML_STORAGE_DATA}<td style='color: #94a3b8; font-style: italic;'>Not mounted</td>"
            fi
            HTML_STORAGE_DATA="${HTML_STORAGE_DATA}<td>$perf_bar</td>"
            HTML_STORAGE_DATA="${HTML_STORAGE_DATA}</tr>"
        fi
        
        usb_storage_devices+=("$device|$vendor_id:$product_id|$model|$size|$usb_version|$theoretical_speed|$mount_point|$performance")
    fi
done

if [ ${#usb_storage_devices[@]} -eq 0 ] && [ $HTML_MODE -eq 0 ]; then
    echo -e "${GRAY}No USB storage devices detected${NC}"
fi

if [ $HTML_MODE -eq 0 ]; then
    echo ""
fi

# USB Adapters and Other Devices Section
if [ $HTML_MODE -eq 0 ]; then
    echo -e "${BOLD}${YELLOW}🔌 DETECTED USB ADAPTERS & DEVICES${NC}"
    draw_separator 95 "$YELLOW"
    echo ""
    
    # Table header
    printf "${BOLD}${WHITE}%-20s %-15s %-30s %-12s %-10s %-15s %s${NC}\n" \
        "TYPE" "VENDOR:PRODUCT" "MODEL" "USB VERSION" "T. SPEED" "DEVICE PATH" "ICON"
    
    printf "${DIM}%s %s %s %s %s %s %s${NC}\n" \
        "────────────────────" "───────────────" "──────────────────────────────" "────────────" "──────────" "───────────────" "─────"
fi

# Track what we've already shown as storage
declare -A shown_devices
ADAPTER_COUNT=0

# Temporary file for adapter data (to avoid subshell issues)
ADAPTER_TEMP_FILE="/tmp/usb_adapter_data_$.tmp"
> "$ADAPTER_TEMP_FILE"

while IFS= read -r line; do
    bus=$(echo "$line" | cut -d' ' -f2)
    dev=$(echo "$line" | cut -d' ' -f4 | sed 's/://')
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
    
    # Get USB speed and version
    speed=""
    device_path_id="N/A"
    device_path_full=""  # Aggiungi questa variabile
    for dev_path in /sys/bus/usb/devices/*; do
        if [ -f "$dev_path/idVendor" ] && [ -f "$dev_path/idProduct" ]; then
            dev_vendor=$(cat "$dev_path/idVendor" 2>/dev/null)
            dev_product=$(cat "$dev_path/idProduct" 2>/dev/null)
            if [ "$dev_vendor" == "$vendor_id" ] && [ "$dev_product" == "$product_id" ]; then
                speed=$(cat "$dev_path/speed" 2>/dev/null)
                device_path_full="/dev/bus/usb/$bus/$dev"  # Percorso completo
                if [ -e "$device_path_full" ]; then
                    device_path_id="$bus/$dev"  # Visualizzazione abbreviata
                fi
                break
            fi
        fi
    done
    
    IFS='|' read -r usb_version theoretical_speed speed_raw <<< "$(get_usb_version_and_speed "$speed")"
    speed_color=$(get_speed_color "$speed")
    speed_color_html=$(get_speed_color_html "$speed")
    
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
    
    ((ADAPTER_COUNT++))
    
    # Console output
    if [ $HTML_MODE -eq 0 ]; then
        vendor_product="${vendor_id}:${product_id}"
        model_truncated="${description:0:30}"
        usb_version_truncated="${usb_version:0:12}"
        
        printf "${WHITE}%-20s ${LIGHT_GREEN}%s%-*s${NC} ${LIGHT_BLUE}%-30s ${speed_color}%-12s ${LIGHT_MAGENTA}%-10s ${LIGHT_CYAN}%-15s ${YELLOW}%s${NC}\n" \
            "$device_type" \
            "$vendor_product" \
            $((15 - ${#vendor_product})) "" \
            "$model_truncated" \
            "$usb_version_truncated" \
            "$theoretical_speed" \
            "$device_path_id" \
            "$icon"
    fi
    
    # Save HTML data to temp file
    if [ $HTML_MODE -eq 1 ]; then
        usb_class=$(echo "$usb_version" | tr ' ' '-' | tr '.' '-' | tr '/' '-' | tr '[A-Z]' '[a-z]')
        
        # Assicurati che il percorso completo sia disponibile
        if [ -z "$device_path_full" ]; then
            device_path_full="/dev/bus/usb/$bus/$dev"
        fi
        
        echo "<tr>" >> "$ADAPTER_TEMP_FILE"
        echo "<td>${icon} ${device_type}</td>" >> "$ADAPTER_TEMP_FILE"
        echo "<td><span class='vendor-product'>${vendor_id}:${product_id}</span></td>" >> "$ADAPTER_TEMP_FILE"
        echo "<td>${description}</td>" >> "$ADAPTER_TEMP_FILE"
        echo "<td><span class='usb-version $usb_class'>$usb_version</span></td>" >> "$ADAPTER_TEMP_FILE"
        echo "<td style='color: $speed_color_html; font-weight: 600;'>$theoretical_speed</td>" >> "$ADAPTER_TEMP_FILE"
        echo "<td><span class='device-path' data-full-path='$device_path_full'>$device_path_id</span></td>" >> "$ADAPTER_TEMP_FILE"
        echo "</tr>" >> "$ADAPTER_TEMP_FILE"
    fi
done < <(lsusb)

# Read HTML adapter data from temp file
if [ $HTML_MODE -eq 1 ] && [ -f "$ADAPTER_TEMP_FILE" ]; then
    HTML_ADAPTER_DATA=$(cat "$ADAPTER_TEMP_FILE")
    rm -f "$ADAPTER_TEMP_FILE"
fi

if [ $HTML_MODE -eq 0 ]; then
    echo ""
fi

# System USB Controllers
CONTROLLER_COUNT=0
CONTROLLER_TEMP_FILE="/tmp/usb_controller_data_$.tmp"
> "$CONTROLLER_TEMP_FILE"

if [ $HTML_MODE -eq 0 ]; then
    echo -e "${BOLD}${LIGHT_CYAN}🎛️  SYSTEM USB CONTROLLERS${NC}"
    draw_separator 95 "$LIGHT_CYAN"
fi

while read controller; do
    ((CONTROLLER_COUNT++))
    if [ $HTML_MODE -eq 0 ]; then
        echo -e "${LIGHT_GREEN}🔧${NC} $controller"
    else
        echo "<div class='controller-card'>🔧 $controller</div>" >> "$CONTROLLER_TEMP_FILE"
    fi
done < <(lspci | grep -i usb)

# Read HTML controller data from temp file
if [ $HTML_MODE -eq 1 ] && [ -f "$CONTROLLER_TEMP_FILE" ]; then
    HTML_CONTROLLER_DATA=$(cat "$CONTROLLER_TEMP_FILE")
    rm -f "$CONTROLLER_TEMP_FILE"
fi

# Statistics and Summary (Console mode)
total_usb_storage=${#usb_storage_devices[@]}

if [ $HTML_MODE -eq 0 ]; then
    echo ""
    echo -e "${BOLD}${LIGHT_CYAN}📊 SUMMARY${NC}"
    draw_separator 95 "$LIGHT_CYAN"
    echo -e "${LIGHT_GREEN}✅ USB storage devices found: ${BOLD}$total_usb_storage${NC}"
    
    # Show detailed analysis for storage devices
    if [ $total_usb_storage -gt 0 ]; then
        echo ""
        echo -e "${BOLD}${LIGHT_MAGENTA}🔍 DETAILED ANALYSIS${NC}"
        draw_separator 95 "$LIGHT_MAGENTA"
        
        for info in "${usb_storage_devices[@]}"; do
            IFS='|' read -r device ids model size usb_version theoretical_speed mount_point performance <<< "$info"
            
            echo ""
            echo -e "${CYAN}📱 Device: ${BOLD}$device${NC}"
            echo -e "   ${GRAY}├─${NC} Vendor/Product ID: ${LIGHT_GREEN}$ids${NC}"
            echo -e "   ${GRAY}├─${NC} Model: ${LIGHT_BLUE}$model${NC}"
            echo -e "   ${GRAY}├─${NC} Capacity: ${LIGHT_GREEN}$size${NC}"
            echo -e "   ${GRAY}├─${NC} USB Version: ${LIGHT_CYAN}$usb_version${NC}"
            echo -e "   ${GRAY}├─${NC} Theoretical Speed: ${LIGHT_MAGENTA}$theoretical_speed${NC}"
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
    draw_separator 95 "$YELLOW"
    echo -e "${LIGHT_BLUE}🔌${NC} Use USB 3.0+ ports (blue/teal colored) for best performance"
    echo -e "${LIGHT_BLUE}🚫${NC} Avoid USB hubs for high-speed storage devices"
    echo -e "${LIGHT_BLUE}⚡${NC} For detailed tests: ${CYAN}sudo hdparm -tT /dev/sdX${NC}"
    echo -e "${LIGHT_BLUE}📊${NC} For benchmarks: ${CYAN}sudo fio --name=test --filename=/dev/sdX --rw=read --bs=1M --size=100M${NC}"
    echo -e "${LIGHT_BLUE}🌡️${NC} Monitor temperature: ${CYAN}sudo hddtemp /dev/sdX${NC}"
    echo -e "${LIGHT_BLUE}📄${NC} Generate HTML report: ${CYAN}$0 --html${NC}"
    
    echo ""
    draw_separator 95 "$LIGHT_GREEN"
    echo -e "${BOLD}${LIGHT_GREEN}✅ Scan completed successfully!${NC}"
    echo ""
fi

# HTML Report Generation
if [ $HTML_MODE -eq 1 ]; then
    END_TIME=$(date +%s)
    GENERATION_TIME=$((END_TIME - START_TIME))
    
    # Calculate total capacity
    TOTAL_CAPACITY=$(human_readable $TOTAL_CAPACITY_BYTES)
    
    # Read template
    if [ -f "$HTML_TEMPLATE_FILE" ]; then
        HTML_CONTENT=$(cat "$HTML_TEMPLATE_FILE")
    else
        echo -e "${RED}❌ HTML template not found!${NC}"
        exit 1
    fi
    
    # Generate tables
    STORAGE_TABLE=$(generate_html_storage_table)
    ADAPTER_TABLE=$(generate_html_adapter_table)
    CONTROLLER_LIST=$(generate_html_controller_list)
    
    # Replace placeholders
    HTML_CONTENT="${HTML_CONTENT//\{\{TIMESTAMP\}\}/$(date '+%Y-%m-%d %H:%M:%S')}"
    HTML_CONTENT="${HTML_CONTENT//\{\{STORAGE_COUNT\}\}/$total_usb_storage}"
    HTML_CONTENT="${HTML_CONTENT//\{\{ADAPTER_COUNT\}\}/$ADAPTER_COUNT}"
    HTML_CONTENT="${HTML_CONTENT//\{\{TOTAL_CAPACITY\}\}/$TOTAL_CAPACITY}"
    HTML_CONTENT="${HTML_CONTENT//\{\{CONTROLLER_COUNT\}\}/$CONTROLLER_COUNT}"
    HTML_CONTENT="${HTML_CONTENT//\{\{GENERATION_TIME\}\}/$GENERATION_TIME}"
    HTML_CONTENT="${HTML_CONTENT//\{\{STORAGE_TABLE\}\}/$STORAGE_TABLE}"
    HTML_CONTENT="${HTML_CONTENT//\{\{ADAPTER_TABLE\}\}/$ADAPTER_TABLE}"
    HTML_CONTENT="${HTML_CONTENT//\{\{CONTROLLER_LIST\}\}/$CONTROLLER_LIST}"
    
    # Write HTML file
    echo "$HTML_CONTENT" > "$HTML_OUTPUT_FILE"
    
    # Fix permissions if running with sudo
    if [ ! -z "$SUDO_USER" ]; then
        chown $SUDO_USER:$SUDO_USER "$HTML_OUTPUT_FILE"
    fi
    
    echo -e "${BOLD}${LIGHT_GREEN}✅ HTML Report generated successfully!${NC}"
    echo -e "${LIGHT_CYAN}📄 Report saved to: ${BOLD}$HTML_OUTPUT_FILE${NC}"
    
    # Try to open in browser with proper user context
    if [ ! -z "$SUDO_USER" ]; then
        # Running with sudo, use the actual user's environment
        if command -v xdg-open &> /dev/null; then
            sudo -u $SUDO_USER DISPLAY=:0 xdg-open "$HTML_OUTPUT_FILE" 2>/dev/null &
            echo -e "${LIGHT_GREEN}🌐 Opening report in browser...${NC}"
            # Cancella il file HTML dopo alcuni secondi
            (sleep 5 && rm -f "$HTML_OUTPUT_FILE" 2>/dev/null) &
        elif command -v open &> /dev/null; then
            sudo -u $SUDO_USER open "$HTML_OUTPUT_FILE" 2>/dev/null &
            echo -e "${LIGHT_GREEN}🌐 Opening report in browser...${NC}"
            # Cancella il file HTML dopo alcuni secondi
            (sleep 5 && rm -f "$HTML_OUTPUT_FILE" 2>/dev/null) &
        else
            echo -e "${YELLOW}⚠️  Please open the HTML file manually in your browser${NC}"
        fi
    else
        # Running without sudo
        if command -v xdg-open &> /dev/null; then
            xdg-open "$HTML_OUTPUT_FILE" 2>/dev/null &
            echo -e "${LIGHT_GREEN}🌐 Opening report in browser...${NC}"
            # Cancella il file HTML dopo alcuni secondi
            (sleep 5 && rm -f "$HTML_OUTPUT_FILE" 2>/dev/null) &
        elif command -v open &> /dev/null; then
            open "$HTML_OUTPUT_FILE" 2>/dev/null &
            echo -e "${LIGHT_GREEN}🌐 Opening report in browser...${NC}"
            # Cancella il file HTML dopo alcuni secondi
            (sleep 5 && rm -f "$HTML_OUTPUT_FILE" 2>/dev/null) &
        else
            echo -e "${YELLOW}⚠️  Please open the HTML file manually in your browser${NC}"
        fi
    fi
    
    echo ""
fi