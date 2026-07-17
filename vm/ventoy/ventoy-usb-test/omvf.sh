# Module-level globals for cleanup traps.
# Must be global (not local) because trap functions run after the calling function returns.
_OVMF_COMPILE_SCRIPT=""
_OVMF_COMPILE_LOG=""
_OVMF_COMPILE_PROGRESS_DIR=""
_OVMF_COMPILE_DIR=""

_ovmf_compile_cleanup() {
    [[ -f "${_OVMF_COMPILE_SCRIPT:-}" ]]       && rm -f  "$_OVMF_COMPILE_SCRIPT"
    [[ -f "${_OVMF_COMPILE_LOG:-}" ]]          && rm -f  "$_OVMF_COMPILE_LOG"
    [[ -d "${_OVMF_COMPILE_PROGRESS_DIR:-}" ]] && rm -rf "$_OVMF_COMPILE_PROGRESS_DIR"
    [[ -d "${_OVMF_COMPILE_DIR:-}" ]]          && rm -rf "$_OVMF_COMPILE_DIR"
    _OVMF_COMPILE_SCRIPT=""; _OVMF_COMPILE_LOG=""
    _OVMF_COMPILE_PROGRESS_DIR=""; _OVMF_COMPILE_DIR=""
}

_OVMF_DOWNLOAD_LOG=""
_OVMF_DOWNLOAD_PROGRESS_DIR=""

_ovmf_download_cleanup() {
    [[ -f "${_OVMF_DOWNLOAD_LOG:-}" ]]          && rm -f  "$_OVMF_DOWNLOAD_LOG"
    [[ -d "${_OVMF_DOWNLOAD_PROGRESS_DIR:-}" ]] && rm -rf "$_OVMF_DOWNLOAD_PROGRESS_DIR"
    _OVMF_DOWNLOAD_LOG=""; _OVMF_DOWNLOAD_PROGRESS_DIR=""
}

# Compile OVMF interactively
prepare_ovmf_interactive() {
    if ! whiptail --title "OVMF Compilation" --yesno \
        "Compiling OVMF may take 10-30 minutes and requires about 2GB of space.\n\nProceed?" \
        10 50; then
        return
    fi

    if ! install_ovmf_deps; then
        whiptail --title "Installation Canceled" --msgbox \
            "Dependencies were not installed. Unable to proceed." \
            10 50
        return
    fi

    # Allocate temp resources and register cleanup trap
    _OVMF_COMPILE_LOG=$(mktemp)
    _OVMF_COMPILE_PROGRESS_DIR=$(mktemp -d)
    _OVMF_COMPILE_DIR=$(mktemp -d)
    _OVMF_COMPILE_SCRIPT=$(mktemp)
    trap _ovmf_compile_cleanup EXIT

    local temp_log="$_OVMF_COMPILE_LOG"
    local progress_dir="$_OVMF_COMPILE_PROGRESS_DIR"
    local temp_dir="$_OVMF_COMPILE_DIR"
    local compilation_script="$_OVMF_COMPILE_SCRIPT"

    # Build the compilation script.
    # ${temp_log}, ${progress_dir}, ${temp_dir} are expanded NOW (at heredoc creation).
    # \$VAR and \$(...) are escaped so they become variables/commands in the generated script.
    cat > "$compilation_script" << EOF
#!/bin/bash
set -e
exec > >(tee -a "${temp_log}") 2>&1

WORK_DIR="${temp_dir}"
PROGRESS_DIR="${progress_dir}"

# Write percent and message to separate files to avoid read/write race conditions
_progress() { echo "\$1" > "\$PROGRESS_DIR/pct"; echo "\$2" > "\$PROGRESS_DIR/msg"; }

cd "\$WORK_DIR"
echo "=== OVMF Compilation Log ==="
echo "Started at: \$(date)"
echo "Working directory: \$WORK_DIR"
echo

_progress 10 "Cloning EDK2 repository..."
echo "PHASE: Cloning EDK2 repository..."
git clone --depth 1 https://github.com/tianocore/edk2.git \
    || { echo "ERROR: Failed to clone EDK2 repository"; exit 1; }
echo "Repository cloned successfully"

_progress 25 "Initializing Git submodules..."
cd edk2/
echo "PHASE: Initializing submodules..."
git submodule update --init --recursive \
    || { echo "ERROR: Failed to initialize submodules"; exit 1; }
echo "Submodules initialized successfully"

_progress 40 "Setting up build environment..."
echo "PHASE: Setting up build environment..."
source ./edksetup.sh BaseTools \
    || { echo "ERROR: Failed to setup build environment"; exit 1; }
echo "Build environment configured successfully"

_progress 55 "Building BaseTools..."
echo "PHASE: Building BaseTools..."
make -C BaseTools/ \
    || { echo "ERROR: Failed to build BaseTools"; exit 1; }
echo "BaseTools built successfully"

_progress 70 "Building OVMF firmware (this phase takes longer)..."
echo "PHASE: Building OVMF firmware..."
OvmfPkg/build.sh -a X64 -b RELEASE -t GCC5 \
    || { echo "ERROR: Failed to build OVMF"; exit 1; }
echo "OVMF built successfully"

_progress 90 "Installing OVMF to system..."
echo "PHASE: Installing OVMF..."

OVMF_FILE="Build/OvmfX64/RELEASE_GCC5/FV/OVMF.fd"
if [[ -f "\$OVMF_FILE" ]]; then
    echo "OVMF binary found: \$OVMF_FILE (Size: \$(du -h "\$OVMF_FILE" | cut -f1))"
    if sudo mkdir -p /usr/share/OVMF && sudo cp "\$OVMF_FILE" /usr/share/OVMF/OVMF.fd; then
        sudo chown root:root /usr/share/OVMF/OVMF.fd
        sudo chmod 644 /usr/share/OVMF/OVMF.fd
        echo "OVMF installed successfully to /usr/share/OVMF/OVMF.fd"
        echo "SUCCESS" > "\$PROGRESS_DIR/result"
    else
        echo "ERROR: Failed to install OVMF to system directory"; exit 1
    fi
else
    echo "ERROR: OVMF binary not found after compilation"
    echo "Expected: \$OVMF_FILE"
    find Build/ -name "*.fd" -type f 2>/dev/null || echo "No .fd files found"
    exit 1
fi

_progress 100 "Compilation completed successfully!"
echo
echo "=== Compilation completed successfully ==="
echo "Finished at: \$(date)"
EOF

    chmod +x "$compilation_script"

    # Run compilation in background, pipe progress updates to whiptail gauge
    {
        "$compilation_script" &
        local compilation_pid=$!

        while kill -0 "$compilation_pid" 2>/dev/null; do
            local percent message
            percent=$(cat "$progress_dir/pct" 2>/dev/null || echo "5")
            message=$(cat "$progress_dir/msg" 2>/dev/null || echo "Initializing...")

            if [[ "$percent" =~ ^[0-9]+$ ]] && (( percent >= 0 && percent <= 100 )); then
                echo "$percent"
                echo "# $message"
            else
                echo "5"
                echo "# Initializing..."
            fi
            sleep 2
        done

        local exit_status=0
        wait "$compilation_pid" || exit_status=$?

        if [[ $exit_status -eq 0 ]] && [[ -f "$progress_dir/result" ]]; then
            echo "100"; echo "# Compilation completed successfully!"
        else
            echo "100"; echo "# Compilation failed with errors"
        fi
    } | whiptail --gauge "OVMF compilation in progress..." 10 70 0

    # Analyze results
    local final_ovmf_file="/usr/share/OVMF/OVMF.fd"
    if [[ -f "$final_ovmf_file" ]]; then
        local file_size
        file_size=$(stat -c%s "$final_ovmf_file" 2>/dev/null || echo "0")
        if (( file_size > 1000000 )); then
            whiptail --title "Compilation Completed" --msgbox \
                "OVMF compiled and installed successfully!\n\nPath: $final_ovmf_file\nSize: $(du -h "$final_ovmf_file" | cut -f1)" \
                10 60
            DEFAULT_BIOS="$final_ovmf_file"
        else
            whiptail --title "Corrupted File" --msgbox \
                "OVMF was created but appears corrupted.\nSize: $(du -h "$final_ovmf_file" 2>/dev/null | cut -f1 || echo "0")" \
                10 50
        fi
    else
        local error_summary=""
        if [[ -f "$temp_log" ]]; then
            error_summary=$(grep -i "error\|failed\|fatal" "$temp_log" | tail -5 | cut -c1-60)
            [[ -z "$error_summary" ]] && error_summary="Unknown error during compilation"
        else
            error_summary="Compilation log not available"
        fi

        if whiptail --title "Compilation Failed" --yesno \
            "Error during OVMF compilation.\n\nLast errors:\n$error_summary\n\nWould you like to view the full log?" \
            15 70; then
            show_compilation_log "$temp_log"
        fi
    fi

    _ovmf_compile_cleanup
    trap - EXIT
}

# Download prebuilt OVMF via package manager
download_ovmf_prebuilt() {
    if ! whiptail --title "Download OVMF" --yesno \
        "Would you like to download a prebuilt OVMF?\n\nThis is faster than compiling from source." \
        10 50; then
        return
    fi

    _OVMF_DOWNLOAD_LOG=$(mktemp)
    _OVMF_DOWNLOAD_PROGRESS_DIR=$(mktemp -d)
    trap _ovmf_download_cleanup EXIT

    local temp_log="$_OVMF_DOWNLOAD_LOG"
    local progress_dir="$_OVMF_DOWNLOAD_PROGRESS_DIR"

    {
        echo "10" > "$progress_dir/pct"
        echo "Detecting package manager..." > "$progress_dir/msg"

        local installed=false

        if command -v apt >/dev/null; then
            echo "20" > "$progress_dir/pct"; echo "Updating apt package database..." > "$progress_dir/msg"
            sudo apt update >"$temp_log" 2>&1 || true
            echo "50" > "$progress_dir/pct"; echo "Installing OVMF with apt..." > "$progress_dir/msg"
            sudo apt install -y ovmf >>"$temp_log" 2>&1 && installed=true

        elif command -v dnf >/dev/null; then
            echo "30" > "$progress_dir/pct"; echo "Installing OVMF with dnf..." > "$progress_dir/msg"
            sudo dnf install -y edk2-ovmf >>"$temp_log" 2>&1 && installed=true

        elif command -v pacman >/dev/null; then
            echo "30" > "$progress_dir/pct"; echo "Installing OVMF with pacman..." > "$progress_dir/msg"
            sudo pacman -S edk2-ovmf --noconfirm >>"$temp_log" 2>&1 && installed=true

        elif command -v zypper >/dev/null; then
            echo "30" > "$progress_dir/pct"; echo "Installing OVMF with zypper..." > "$progress_dir/msg"
            sudo zypper install -y ovmf >>"$temp_log" 2>&1 && installed=true

        else
            echo "ERROR: No supported package manager found" >>"$temp_log"
        fi

        echo "90" > "$progress_dir/pct"; echo "Searching for OVMF files..." > "$progress_dir/msg"
        echo "100" > "$progress_dir/pct"; echo "Completed" > "$progress_dir/msg"

        if [[ "$installed" == true ]]; then
            echo "SUCCESS" > "$progress_dir/result"
        else
            echo "FAILED" > "$progress_dir/result"
        fi
    } &
    local install_pid=$!

    {
        while kill -0 "$install_pid" 2>/dev/null; do
            local percent message
            percent=$(cat "$progress_dir/pct" 2>/dev/null || echo "0")
            message=$(cat "$progress_dir/msg" 2>/dev/null || echo "Download in progress...")

            if [[ "$percent" =~ ^[0-9]+$ ]]; then
                echo "$percent"; echo "# $message"
            fi
            sleep 1
        done
        wait "$install_pid" || true
        echo "100"; echo "# Download completed"
    } | whiptail --gauge "Downloading OVMF..." 8 60 0

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
        [[ -f "$path" ]] && { found_path="$path"; break; }
    done

    if [[ -n "$found_path" ]]; then
        DEFAULT_BIOS="$found_path"
        whiptail --title "OVMF Found" --msgbox \
            "OVMF is now available!\n\nPath: $found_path\nSize: $(du -h "$found_path" | cut -f1)" \
            10 70
    else
        if [[ -f "$progress_dir/result" ]] && [[ "$(cat "$progress_dir/result")" == "SUCCESS" ]]; then
            whiptail --title "OVMF Installed" --msgbox \
                "Installation succeeded, but the OVMF file was not found in standard paths.\n\nTry searching manually in /usr/share/" \
                12 70
        else
            local error_msg="Installation failed."
            if [[ -f "$temp_log" ]]; then
                local last_error
                last_error=$(grep -v "^$" "$temp_log" | tail -1)
                [[ -n "$last_error" ]] && error_msg="$error_msg\n\nLast error:\n${last_error:0:100}"
            fi
            whiptail --title "Download Failed" --msgbox "$error_msg" 12 70
        fi
    fi

    _ovmf_download_cleanup
    trap - EXIT
}

# Check and install OVMF build dependencies
install_ovmf_deps() {
    local missing=()
    command -v gcc  >/dev/null || missing+=("gcc")
    command -v nasm >/dev/null || missing+=("nasm")
    command -v iasl >/dev/null || missing+=("iasl")
    [[ -f /usr/include/uuid/uuid.h ]] || missing+=("uuid-dev")

    [[ ${#missing[@]} -eq 0 ]] && return 0

    local pkg_manager=""
    if   command -v apt    >/dev/null; then pkg_manager="apt"
    elif command -v dnf    >/dev/null; then pkg_manager="dnf"
    elif command -v pacman >/dev/null; then pkg_manager="pacman"
    elif command -v zypper >/dev/null; then pkg_manager="zypper"
    fi

    if ! whiptail --title "Missing Dependencies" --yesno \
        "The following dependencies are missing for OVMF compilation:\n\n${missing[*]}\n\nWould you like to install them now?" \
        15 70; then
        return 1
    fi

    {
        echo "10"; echo "Updating package indices..."
        case "$pkg_manager" in
            apt)
                sudo apt update >/dev/null 2>&1 || true
                echo "50"; echo "Installing packages..."
                sudo apt install -y build-essential nasm acpica-tools uuid-dev >/dev/null 2>&1
                ;;
            dnf)
                echo "50"; echo "Installing packages..."
                sudo dnf install -y gcc nasm acpica-tools libuuid-devel >/dev/null 2>&1
                ;;
            pacman)
                echo "50"; echo "Installing packages..."
                sudo pacman -S --noconfirm base-devel nasm acpica >/dev/null 2>&1
                ;;
            zypper)
                echo "50"; echo "Installing packages..."
                sudo zypper install -y gcc nasm acpica libuuid-devel >/dev/null 2>&1
                ;;
            *)
                echo "100"; echo "No supported package manager found."
                ;;
        esac
        echo "100"; echo "Completed."
    } | whiptail --gauge "Installing dependencies..." 8 70 0

    local still_missing=()
    command -v gcc  >/dev/null || still_missing+=("gcc")
    command -v nasm >/dev/null || still_missing+=("nasm")
    command -v iasl >/dev/null || still_missing+=("iasl")
    [[ -f /usr/include/uuid/uuid.h ]] || still_missing+=("uuid-dev")

    if [[ ${#still_missing[@]} -eq 0 ]]; then
        whiptail --title "Installation Successful" --msgbox \
            "All dependencies have been successfully installed!" 8 50
        return 0
    else
        whiptail --title "Installation Failed" --msgbox \
            "Failed to install dependencies. Still missing:\n\n${still_missing[*]}" 10 70
        return 1
    fi
}
