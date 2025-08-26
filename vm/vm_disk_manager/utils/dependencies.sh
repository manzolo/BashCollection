#!/bin/bash

# Function to check and install dependencies
check_and_install_dependencies() {
    local missing_essential=()
    local missing_optional=()
    
    # Essential dependencies with packages
    declare -A essential_deps=(
        ["qemu-img"]="qemu-utils"
        ["qemu-nbd"]="qemu-utils"
        ["parted"]="parted"
        ["wget"]="wget"
    )
    
    # Optional dependencies with packages
    declare -A optional_deps=(
        ["guestmount"]="libguestfs-tools"
        ["cryptsetup"]="cryptsetup"
        ["vgs"]="lvm2"
        ["sgdisk"]="gdisk"
        ["ntfsresize"]="ntfs-3g"
        ["e2fsck"]="e2fsprogs"
    )
    
    # Check essential dependencies
    for cmd in "${!essential_deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_essential+=("${essential_deps[$cmd]}")
        fi
    done
    
    # Check optional dependencies
    for cmd in "${!optional_deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_optional+=("${optional_deps[$cmd]}")
        fi
    done
    
    # Install essential dependencies if missing
    if [ ${#missing_essential[@]} -gt 0 ]; then
        local unique_essential=($(printf '%s\n' "${missing_essential[@]}" | sort -u))
        
        if whiptail --title "Missing Dependencies" --yesno "The following essential dependencies are missing: ${unique_essential[*]}\n\nDo you want to install them automatically?" 10 70; then
            (
                echo 0
                echo "# Updating package lists..."
                apt-get update >/dev/null 2>&1
                echo 50
                echo "# Installing essential dependencies..."
                apt-get install -y "${unique_essential[@]}" >/dev/null 2>&1
                echo 100
                echo "# Done!"
                sleep 1
            ) | whiptail --gauge "Installing essential dependencies..." 8 50 0
            if [ $? -eq 0 ]; then
                INSTALLED_PACKAGES+=("${unique_essential[@]}")
                whiptail --msgbox "Essential dependencies installed successfully." 8 60
            else
                whiptail --msgbox "Error installing essential dependencies." 8 60
                exit 1
            fi
        else
            whiptail --msgbox "The following essential dependencies are required: ${unique_essential[*]}\nInstall them manually and restart the script." 10 70
            exit 1
        fi
    fi
    
    # Offer to install optional dependencies
    if [ ${#missing_optional[@]} -gt 0 ]; then
        local unique_optional=($(printf '%s\n' "${missing_optional[@]}" | sort -u))
        
        if whiptail --title "Optional Dependencies" --yesno "The following optional dependencies are missing: ${unique_optional[*]}\n\nDo you want to install them for full functionality?" 12 80; then
            (
                echo 0
                echo "# Installing optional dependencies..."
                apt-get install -y "${unique_optional[@]}" >/dev/null 2>&1
                echo 100
                echo "# Done!"
                sleep 1
            ) | whiptail --gauge "Installing optional dependencies..." 8 50 0
            if [ $? -eq 0 ]; then
                INSTALLED_PACKAGES+=("${unique_optional[@]}")
                whiptail --msgbox "Optional dependencies installed." 8 60
            else
                whiptail --msgbox "Some optional dependencies were not installed." 8 60
            fi
        fi
    fi
}