#!/bin/bash
# PKG_NAME: check-disks
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), smartmontools (>= 7.0)
# PKG_RECOMMENDS: nvme-cli
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: SMART disk health and temperature monitoring tool
# PKG_LONG_DESCRIPTION: Lists all physical disks (SATA, SAS, USB, NVMe) with
#  comprehensive health information including SMART status, temperatures,
#  and critical attributes.
#  .
#  Features:
#  - Automatic detection of SATA/SAS/USB and NVMe drives
#  - SMART health status monitoring
#  - Color-coded temperature readings
#  - Critical attribute reporting (reallocated sectors, pending, uncorrectable)
#  - Support for multiple temperature attribute formats
#  - Kelvin to Celsius automatic conversion for NVMe
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
# ==================================================================
# Script: check-disks.sh
# Lists all physical disks (SATA + NVMe) with:
#   • Model and serial number
#   • Overall SMART status
#   • Current temperature
#   • Critical attributes (reallocated, pending, etc.)
# Usage: sudo ./check-disks.sh
# ==================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Root check
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run this script with sudo${NC}"
    exit 1
fi

# Dependency check
if ! command -v smartctl >/dev/null 2>&1; then
    echo -e "${RED}Missing dependency: smartctl${NC}"
    echo "Install with: sudo apt install smartmontools"
    exit 1
fi

if ! command -v nvme >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: nvme-cli not installed (NVMe disks will be skipped)${NC}"
    echo "Install with: sudo apt install nvme-cli"
fi

echo -e "=================================================================="
echo -e "       PHYSICAL DISKS - SMART STATUS AND TEMPERATURE             "
echo -e "==================================================================\n"

# --------------------- SATA / SAS / USB DRIVES ---------------------
for dev in /dev/sd?{,?}; do
    [[ -b "$dev" ]] || continue
    [[ "$dev" =~ [0-9]$ ]] && continue   # Skip partitions

    # Get basic info
    info=$(smartctl -i "$dev" 2>/dev/null)
    [[ $? -ne 0 ]] && continue

    model=$(echo "$info" | grep -E "Device Model|Model:" | cut -d: -f2- | xargs)
    serial=$(echo "$info" | grep "Serial Number" | cut -d: -f2- | xargs)
    smart_status=$(smartctl -H "$dev" 2>/dev/null | grep -i "SMART overall-health" | awk '{print $NF}')

    # Get temperature - more robust method
    # Try different temperature attribute names and extract first number from raw value
    temp=$(smartctl -A "$dev" 2>/dev/null | \
           awk '/Temperature_Celsius|Temperature_Internal|Airflow_Temperature_Cel|Drive_Temperature/ {
               # Extract first number from field 10 (raw value)
               match($10, /^[0-9]+/);
               if (RSTART > 0) {
                   print substr($10, RSTART, RLENGTH);
                   exit;
               }
           }')

    # If no temperature attribute found, try alternative method
    if [[ -z "$temp" ]]; then
        temp=$(smartctl -a "$dev" 2>/dev/null | \
               grep -i "Current Drive Temperature" | \
               grep -oP '\d+(?= C)' | head -1)
    fi

    # Get critical SMART attributes
    reallocated=$(smartctl -A "$dev" 2>/dev/null | awk '/Reallocated_Sector_Ct/ {print $10}')
    pending=$(smartctl -A "$dev" 2>/dev/null | awk '/Current_Pending_Sector/ {print $10}')
    uncorrectable=$(smartctl -A "$dev" 2>/dev/null | awk '/Offline_Uncorrectable/ {print $10}')

    echo -e "${BLUE}SATA/USB Disk:${NC} $dev"
    echo -e "   Model         : ${model:-N/A}"
    echo -e "   Serial        : ${serial:-N/A}"
    echo -n -e "   SMART Status  : "
    if [[ "$smart_status" == "PASSED" ]]; then
        echo -e "${GREEN}PASSED${NC}"
    elif [[ "$smart_status" == "FAILED!" ]]; then
        echo -e "${RED}FAILED${NC}"
    else
        echo -e "${YELLOW}${smart_status:-N/A}${NC}"
    fi

    if [[ -n "$temp" ]]; then
        if [[ $temp -lt 40 ]]; then
            echo -e "   Temperature   : ${GREEN}${temp}°C${NC}"
        elif [[ $temp -lt 50 ]]; then
            echo -e "   Temperature   : ${YELLOW}${temp}°C${NC}"
        else
            echo -e "   Temperature   : ${RED}${temp}°C${NC}"
        fi
    else
        echo -e "   Temperature   : N/A"
    fi

    # Show critical attributes if non-zero
    [[ -n "$reallocated" && "$reallocated" != "0" ]] && \
        echo -e "   ${RED}Reallocated   : $reallocated${NC}"
    [[ -n "$pending" && "$pending" != "0" ]] && \
        echo -e "   ${RED}Pending Sect  : $pending${NC}"
    [[ -n "$uncorrectable" && "$uncorrectable" != "0" ]] && \
        echo -e "   ${RED}Uncorrectable : $uncorrectable${NC}"
    echo
done

# -------------------------- NVMe DRIVES --------------------------
if command -v nvme >/dev/null 2>&1; then
    for dev in /dev/nvme[0-9]*; do
        [[ -b "$dev" ]] || continue
        [[ "$dev" =~ n[0-9]+$ ]] || continue   # Only process namespaces (nvme0n1, nvme1n1, etc.)

        # Basic information
        model=$(nvme id-ctrl "$dev" 2>/dev/null | grep -i "^mn " | cut -d: -f2- | xargs)
        [[ -z "$model" ]] && model=$(nvme id-ctrl "$dev" -H 2>/dev/null | grep -i "model" | head -1 | cut -d: -f2- | xargs)

        serial=$(nvme id-ctrl "$dev" 2>/dev/null | grep -i "^sn " | cut -d: -f2- | xargs)
        [[ -z "$serial" ]] && serial=$(nvme id-ctrl "$dev" -H 2>/dev/null | grep -i "serial" | cut -d: -f2- | xargs)

        # SMART log
        log=$(nvme smart-log "$dev" 2>/dev/null)
        [[ -z "$log" ]] && continue

        # Extract temperature (some tools report in Kelvin, others in Celsius)
        # Use head -1 to get only the first temperature value and strip newlines
        temp=$(echo "$log" | grep -i "^temperature" | head -1 | awk '{print $3}' | tr -d '\n\r')

        # Convert from Kelvin to Celsius if necessary (temps > 100 are likely in Kelvin)
        if [[ -n "$temp" ]] && [[ "$temp" =~ ^[0-9]+$ ]] && [[ $temp -gt 100 ]]; then
            temp=$((temp - 273))
        fi

        # Check critical warning
        critical=$(echo "$log" | grep "critical_warning" | awk '{print $3}')
        status="OK"
        [[ -n "$critical" && $critical -ne 0 ]] && status="WARNING"

        echo -e "${BLUE}NVMe Disk:${NC} $dev"
        echo -e "   Model         : ${model:-N/A}"
        echo -e "   Serial        : ${serial:-N/A}"
        echo -n -e "   SMART Status  : "
        if [[ "$status" == "OK" ]]; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}WARNING${NC}"
        fi

        if [[ -n "$temp" ]] && [[ "$temp" =~ ^[0-9]+$ ]]; then
            if [[ $temp -lt 50 ]]; then
                echo -e "   Temperature   : ${GREEN}${temp}°C${NC}"
            elif [[ $temp -lt 65 ]]; then
                echo -e "   Temperature   : ${YELLOW}${temp}°C${NC}"
            else
                echo -e "   Temperature   : ${RED}${temp}°C${NC}"
            fi
        else
            echo -e "   Temperature   : N/A"
        fi

        [[ -n "$critical" && $critical -ne 0 ]] && \
            echo -e "   ${RED}Critical Warn : $critical (bitmask)${NC}"
        echo
    done
fi

echo -e "=================================================================="
echo -e "Check completed: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "=================================================================="

exit 0
