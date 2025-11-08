# Compile OVMF interactively
prepare_ovmf_interactive() {
    # Ask for confirmation before proceeding
    if ! whiptail --title "OVMF Compilation" --yesno \
        "Compiling OVMF may take 10-30 minutes and requires about 2GB of space.\n\nProceed?" \
        10 50; then
        return
    fi

    # Check and install dependencies
    if ! install_ovmf_deps; then
        whiptail --title "Installation Canceled" --msgbox \
            "Dependencies were not installed. Unable to proceed." \
            10 50
        return
    fi

    # Create temporary files for log and progress
    local temp_log=$(mktemp)
    local temp_progress=$(mktemp)
    local temp_dir=$(mktemp -d)
    local compilation_success=false

    # Create compilation script that reports progress
    local compilation_script=$(mktemp)
    cat > "$compilation_script" << EOF
#!/bin/bash
set -e
exec > >(tee -a "${temp_log}") 2>&1

WORK_DIR="${temp_dir}"
PROGRESS_FILE="${temp_progress}"

cd "\$WORK_DIR"

echo "=== OVMF Compilation Log ===" 
echo "Started at: \$(date)"
echo "Working directory: \$WORK_DIR"
echo

# Phase 1: Clone repository
echo "10" > "\$PROGRESS_FILE"
echo "Cloning EDK2 repository..." >> "\$PROGRESS_FILE"
echo "PHASE: Cloning EDK2 repository..."
if ! git clone --depth 1 https://github.com/tianocore/edk2.git; then
    echo "ERROR: Failed to clone EDK2 repository"
    exit 1
fi
echo "Repository cloned successfully"

# Phase 2: Submodules
echo "25" > "\$PROGRESS_FILE"
echo "Initializing Git submodules..." >> "\$PROGRESS_FILE"
cd edk2/
echo "PHASE: Initializing submodules..."
if ! git submodule update --init --recursive; then
    echo "ERROR: Failed to initialize submodules"
    exit 1
fi
echo "Submodules initialized successfully"

# Phase 3: Setup environment
echo "40" > "\$PROGRESS_FILE"
echo "Setting up build environment..." >> "\$PROGRESS_FILE"
echo "PHASE: Setting up build environment..."
if ! source ./edksetup.sh BaseTools; then
    echo "ERROR: Failed to setup build environment"
    exit 1
fi
echo "Build environment configured successfully"

# Phase 4: Build BaseTools
echo "55" > "\$PROGRESS_FILE"
echo "Building BaseTools..." >> "\$PROGRESS_FILE"
echo "PHASE: Building BaseTools..."
if ! make -C BaseTools/; then
    echo "ERROR: Failed to build BaseTools"
    exit 1
fi
echo "BaseTools built successfully"

# Phase 5: Build OVMF
echo "70" > "\$PROGRESS_FILE"
echo "Building OVMF (this phase takes longer)..." >> "\$PROGRESS_FILE"
echo "PHASE: Building OVMF firmware..."
if ! OvmfPkg/build.sh -a X64 -b RELEASE -t GCC5; then
    echo "ERROR: Failed to build OVMF"
    exit 1
fi
echo "OVMF built successfully"

# Phase 6: Installation
echo "90" > "\$PROGRESS_FILE"
echo "Installing OVMF to system..." >> "\$PROGRESS_FILE"
echo "PHASE: Installing OVMF..."

OVMF_FILE="Build/OvmfX64/RELEASE_GCC5/FV/OVMF.fd"
if [[ -f "\$OVMF_FILE" ]]; then
    echo "OVMF binary found: \$OVMF_FILE"
    echo "Size: \$(du -h "\$OVMF_FILE" | cut -f1)"
    
    if sudo mkdir -p /usr/share/OVMF && sudo cp "\$OVMF_FILE" /usr/share/OVMF/OVMF.fd; then
        sudo chown root:root /usr/share/OVMF/OVMF.fd
        sudo chmod 644 /usr/share/OVMF/OVMF.fd
        echo "OVMF installed successfully to /usr/share/OVMF/OVMF.fd"
        echo "SUCCESS" > "\$PROGRESS_FILE.result"
    else
        echo "ERROR: Failed to install OVMF to system directory"
        exit 1
    fi
else
    echo "ERROR: OVMF binary not found after compilation"
    echo "Expected location: \$OVMF_FILE"
    echo "Directory contents:"
    find Build/ -name "*.fd" -type f 2>/dev/null || echo "No .fd files found"
    exit 1
fi

echo "95" > "\$PROGRESS_FILE"
echo "Cleaning up temporary files..." >> "\$PROGRESS_FILE"

echo "100" > "\$PROGRESS_FILE"
echo "Compilation completed successfully!" >> "\$PROGRESS_FILE"

echo
echo "=== Compilation completed successfully ==="
echo "Finished at: \$(date)"
EOF

    chmod +x "$compilation_script"

    # Run compilation with improved progress bar
    {
        # Start compilation in the background
        "$compilation_script" &
        local compilation_pid=$!
        
        # Monitor progress
        while kill -0 $compilation_pid 2>/dev/null; do
            if [[ -f "$temp_progress" ]]; then
                local percent=$(head -n 1 "$temp_progress" 2>/dev/null || echo "0")
                local message=$(tail -n 1 "$temp_progress" 2>/dev/null || echo "Compilation in progress...")
                
                # Validate progress (must be a number)
                if [[ "$percent" =~ ^[0-9]+$ ]] && [[ $percent -ge 0 ]] && [[ $percent -le 100 ]]; then
                    echo "$percent"
                    echo "# $message"
                fi
            else
                echo "5"
                echo "# Initializing..."
            fi
            sleep 2
        done
        
        # Wait for the process to complete and get exit status
        wait $compilation_pid
        local exit_status=$?
        
        # Final progress update
        if [[ $exit_status -eq 0 ]] && [[ -f "$temp_progress.result" ]]; then
            echo "100"
            echo "# Compilation completed successfully!"
            compilation_success=true
        else
            echo "100"
            echo "# Compilation failed with errors"
            compilation_success=false
        fi
        
    } | whiptail --gauge "OVMF compilation in progress..." 10 70 0

    # Analyze results
    local final_ovmf_file="/usr/share/OVMF/OVMF.fd"
    if [[ -f "$final_ovmf_file" ]]; then
        local file_size=$(stat -c%s "$final_ovmf_file" 2>/dev/null || echo "0")
        if [[ $file_size -gt 1000000 ]]; then
            whiptail --title "Compilation Completed" --msgbox \
                "OVMF compiled and installed successfully!\n\nPath: $final_ovmf_file\nSize: $(du -h $final_ovmf_file | cut -f1)" \
                10 60
            DEFAULT_BIOS="$final_ovmf_file"
        else
            whiptail --title "Corrupted File" --msgbox \
                "OVMF was created but appears corrupted.\nSize: $(du -h $final_ovmf_file 2>/dev/null | cut -f1 || echo "0")" \
                10 50
        fi
    else
        # Compilation failed if file does not exist
        local error_summary=""
        if [[ -f "$temp_log" ]]; then
            error_summary=$(grep -i "error\|failed\|fatal" "$temp_log" | tail -5 | cut -c1-60)
            if [[ -z "$error_summary" ]]; then
                error_summary="Unknown error during compilation"
            fi
        else
            error_summary="Compilation log not available"
        fi
        
        if whiptail --title "Compilation Failed" --yesno \
            "Error during OVMF compilation.\n\nLast errors:\n$error_summary\n\nWould you like to view the full log?" \
            15 70; then
            show_compilation_log "$temp_log"
        fi
    fi

    # Manual cleanup
    log_info "Cleaning up temporary files..."
    [[ -f "$compilation_script" ]] && rm -f "$compilation_script"
    [[ -f "$temp_log" ]] && rm -f "$temp_log"
    [[ -f "$temp_progress" ]] && rm -f "$temp_progress"
    [[ -f "$temp_progress.result" ]] && rm -f "$temp_progress.result"
    [[ -d "$temp_dir" ]] && rm -rf "$temp_dir"
    log_info "Cleanup completed"
}

# Improved function to download prebuilt OVMF
download_ovmf_prebuilt() {
    if whiptail --title "Download OVMF" --yesno \
        "Would you like to download a prebuilt OVMF?\n\nThis is faster than compiling from source." \
        10 50; then
        
        local temp_log=$(mktemp)
        local install_success=false
        local progress_file=$(mktemp)

        # Cleanup
        cleanup_download() {
            rm -f "$temp_log" "$progress_file" 2>/dev/null
        }
        trap cleanup_download EXIT

        # Improved installation script
        {
            echo "10" > "$progress_file"
            echo "# Detecting package manager..." >> "$progress_file"
            
            # Detect package manager and install
            if command -v apt >/dev/null; then
                echo "20" > "$progress_file"
                echo "# Updating apt package database..." >> "$progress_file"
                sudo apt update >"$temp_log" 2>&1
                
                echo "50" > "$progress_file"
                echo "# Installing OVMF with apt..." >> "$progress_file"
                if sudo apt install -y ovmf >>"$temp_log" 2>&1; then
                    install_success=true
                fi
                
            elif command -v dnf >/dev/null; then
                echo "30" > "$progress_file"
                echo "# Installing OVMF with dnf..." >> "$progress_file"
                if sudo dnf install -y edk2-ovmf >>"$temp_log" 2>&1; then
                    install_success=true
                fi
                
            elif command -v pacman >/dev/null; then
                echo "30" > "$progress_file"
                echo "# Installing OVMF with pacman..." >> "$progress_file"
                if sudo pacman -S edk2-ovmf --noconfirm >>"$temp_log" 2>&1; then
                    install_success=true
                fi
                
            elif command -v zypper >/dev/null; then
                echo "30" > "$progress_file"
                echo "# Installing OVMF with zypper..." >> "$progress_file"
                if sudo zypper install -y ovmf >>"$temp_log" 2>&1; then
                    install_success=true
                fi
            else
                echo "ERROR: No supported package manager found"
            fi

            echo "80" > "$progress_file"
            echo "# Searching for OVMF files..." >> "$progress_file"
            
            echo "100" > "$progress_file"
            echo "# Completed" >> "$progress_file"
            
            # Report result
            if [[ "$install_success" == true ]]; then
                echo "SUCCESS" > "$progress_file.result"
            else
                echo "FAILED" > "$progress_file.result"
            fi
            
        } &
        local install_pid=$!
        
        # Monitor progress
        {
            while kill -0 $install_pid 2>/dev/null; do
                if [[ -f "$progress_file" ]]; then
                    local percent=$(head -n 1 "$progress_file" 2>/dev/null || echo "0")
                    local message=$(tail -n 1 "$progress_file" 2>/dev/null || echo "Download in progress...")
                    
                    if [[ "$percent" =~ ^[0-9]+$ ]]; then
                        echo "$percent"
                        echo "# $message"
                    fi
                fi
                sleep 1
            done
            
            wait $install_pid
            echo "100"
            echo "# Download completed"
            
        } | whiptail --gauge "Downloading OVMF..." 8 60 0
        
        # Check result and locate OVMF
        local found_path=""
        local ovmf_paths=(
            "/usr/share/OVMF/OVMF_CODE.fd"
            "/usr/share/ovmf/OVMF.fd" 
            "/usr/share/edk2-ovmf/OVMF_CODE.fd"
            "/usr/share/edk2/ovmf/OVMF_CODE.fd"
            "/usr/share/qemu/OVMF.fd"
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
        )
        
        for path in "${ovmf_paths[@]}"; do
            if [[ -f "$path" ]]; then
                found_path="$path"
                break
            fi
        done

        if [[ -n "$found_path" ]]; then
            DEFAULT_BIOS="$found_path"
            local file_size=$(du -h "$found_path" | cut -f1)
            whiptail --title "OVMF Found" --msgbox \
                "OVMF is now available!\n\nPath: $found_path\nSize: $file_size" \
                10 70
        else
            if [[ -f "$progress_file.result" ]] && [[ "$(cat "$progress_file.result")" == "SUCCESS" ]]; then
                whiptail --title "OVMF Installed" --msgbox \
                    "Installation succeeded, but the OVMF file was not found in standard paths.\n\nTry searching manually in /usr/share/" \
                    12 70
            else
                local error_msg="Installation failed."
                if [[ -f "$temp_log" ]]; then
                    local last_error=$(tail -3 "$temp_log" | grep -v "^$" | tail -1)
                    if [[ -n "$last_error" ]]; then
                        error_msg="$error_msg\n\nLast error:\n${last_error:0:100}"
                    fi
                fi
                
                whiptail --title "Download Failed" --msgbox "$error_msg" 12 70
            fi
        fi
    fi
}

# Function to check and install OVMF dependencies
install_ovmf_deps() {
    local missing=()
    command -v gcc >/dev/null || missing+=("build-essential")
    command -v nasm >/dev/null || missing+=("nasm")
    command -v iasl >/dev/null || missing+=("acpica-tools")
    command -v uuid >/dev/null || missing+=("uuid-dev")
    command -v uuid >/dev/null || missing+=("uuid")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        if whiptail --title "Missing Dependencies" --yesno \
            "The following dependencies are missing for OVMF compilation:\n\n${missing[*]}\n\nWould you like to install them now?" \
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
            command -v gcc >/dev/null || missing_after_install+=("build-essential")
            command -v nasm >/dev/null || missing_after_install+=("nasm")
            command -v iasl >/dev/null || missing_after_install+=("acpica-tools")
            command -v uuid >/dev/null || missing_after_install+=("uuid-dev")
            command -v uuid >/dev/null || missing_after_install+=("uuid")
            
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