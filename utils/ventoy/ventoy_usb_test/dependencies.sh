#!/bin/bash

# Check dependencies
check_dependencies() {
    local missing=()
    
    command -v qemu-system-x86_64 >/dev/null || missing+=("qemu-system-x86")
    command -v lsblk >/dev/null || missing+=("util-linux")
    command -v git >/dev/null || missing+=("git")
    command -v whiptail >/dev/null || missing+=("whiptail")
    command -v dialog >/dev/null || missing+=("dialog")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        if whiptail --title "Missing Dependencies" --yesno \
            "The following dependencies are missing:\n\n${missing[*]}\n\nWould you like to install them now?" \
            15 70; then
            
            local pkgs_to_install="${missing[*]}"
            
            # Install dependencies in the background with progress
            {
                echo "10" ; echo "Updating package indices..."
                sudo apt update >/dev/null 2>&1 || true
                
                echo "50" ; echo "Installing packages: ${pkgs_to_install}..."
                sudo apt install -y $pkgs_to_install >/dev/null 2>&1
                
                echo "100" ; echo "Completed."
            } | whiptail --gauge "Installing dependencies..." 8 70 0

            # Re-check dependencies after installation
            local missing_after_install=()
            command -v qemu-system-x86_64 >/dev/null || missing_after_install+=("qemu-system-x86")
            command -v lsblk >/dev/null || missing_after_install+=("util-linux")
            command -v git >/dev/null || missing_after_install+=("git")
            command -v whiptail >/dev/null || missing_after_install+=("whiptail")
            command -v dialog >/dev/null || missing_after_install+=("dialog")
            
            if [[ ${#missing_after_install[@]} -eq 0 ]]; then
                whiptail --title "Installation Successful" --msgbox \
                    "All dependencies have been successfully installed!" 8 50
                return 0
            else
                whiptail --title "Installation Failed" --msgbox \
                    "Failed to install dependencies. Still missing:\n\n${missing_after_install[*]}" 10 70
                return 1
            fi
        else
            return 1 # User canceled
        fi
    fi
    return 0 # No missing dependencies
}

# Verify all dependencies
verify_all_dependencies() {
    local deps_info="DEPENDENCY VERIFICATION\n\n"
    
    local deps=(
        "qemu-system-x86_64:QEMU x86_64"
        "whiptail:Dialog TUI"
        "lsblk:Block utilities"
        "git:Version Control"
        "make:Build tools"
        "fdisk:Disk utilities"
        "free:Memory info"
        "lscpu:CPU info"
    )
    
    for dep in "${deps[@]}"; do
        local cmd="${dep%:*}"
        local desc="${dep#*:}"
        
        if command -v "$cmd" >/dev/null 2>&1; then
            deps_info+="✓ $desc ($cmd)\n"
        else
            deps_info+="✗ $desc ($cmd) - MISSING\n"
        fi
    done
    
    # Additional checks
    deps_info+="\nADDITIONAL CHECKS:\n"
    
    # OVMF
    if [[ -f "$DEFAULT_BIOS" ]]; then
        deps_info+="✓ OVMF present\n"
    else
        deps_info+="⚠ OVMF missing (required for UEFI)\n"
    fi
    
    # KVM Group
    if groups | grep -q kvm; then
        deps_info+="✓ User in KVM group\n"
    else
        deps_info+="⚠ User not in KVM group\n"
    fi
    
    whiptail --title "Dependency Verification" --scrolltext \
        --msgbox "$deps_info" 20 70
}
