# nvidia-manager module: container toolkit management
# Sourced by nvidia-manager.sh — do not execute directly.
check_and_install_toolkit() {
    # Check for container runtime (Docker or containerd)
    local runtime=""
    if command -v docker &> /dev/null; then
        runtime="docker"
    elif command -v containerd &> /dev/null; then
        runtime="containerd"
    else
        whiptail --title "Container Toolkit" --msgbox "No supported container runtime (Docker or containerd) found." 10 70
        return
    fi

    # Check if NVIDIA Container Toolkit is functional
    local toolkit_installed=false
    local test_image="nvidia/cuda:12.2.0-base-ubuntu22.04" # Specific version for broader compatibility
    if [ "$runtime" = "docker" ]; then
        # Attempt to pull the image first to avoid transient failures
        if docker pull "$test_image" &> /dev/null; then
            if docker run --rm --gpus all "$test_image" nvidia-smi &> /dev/null; then
                toolkit_installed=true
            fi
        fi
    elif [ "$runtime" = "containerd" ]; then
        if ctr images pull docker.io/"$test_image" && \
           ctr run --rm --gpus 0 docker.io/"$test_image" test nvidia-smi &> /dev/null; then
            toolkit_installed=true
        fi
    fi

    if $toolkit_installed; then
        local version
        version=$(nvidia-container-toolkit --version 2>/dev/null || echo "Unknown")
        whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit is installed (Version: $version) and working." 10 70
        return
    fi

    # Prompt to install or update toolkit
    if whiptail --title "Install Container Toolkit" --yesno "NVIDIA Container Toolkit is not installed or not working. Install/update it?" 10 70; then
        echo "Setting up NVIDIA Container Toolkit repository..."

        # Add NVIDIA Container Toolkit repository
        local repo_url="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"
        local gpg_key="https://nvidia.github.io/libnvidia-container/gpgkey"
        local keyring="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"

        # Check if GPG key exists to avoid overwrite prompt
        if [ -f "$keyring" ]; then
            echo "GPG key already exists at $keyring. Skipping key download."
        else
            if ! curl -fsSL "$gpg_key" | sudo gpg --dearmor -o "$keyring"; then
                whiptail --title "Error" --msgbox "Could not add NVIDIA GPG key. Check your connection." 10 60
                return
            fi
        fi

        # Add repository with proper signed-by syntax
        if ! curl -fsSL "$repo_url" | \
            sed 's|deb |deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] |' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list; then
            whiptail --title "Error" --msgbox "Could not add NVIDIA repository. Check your connection." 10 60
            return
        fi

        # Install or update the toolkit
        echo "Installing NVIDIA Container Toolkit..."
        if apt-get update && apt-get install -y nvidia-container-toolkit; then
            # Configure runtime based on detected runtime
            if [ "$runtime" = "docker" ]; then
                if nvidia-ctk runtime configure --runtime=docker && systemctl restart docker; then
                    whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit installed and configured for Docker." 10 70
                else
                    whiptail --title "Warning" --msgbox "Toolkit installed, but Docker configuration failed. Please check manually." 15 70
                fi
            elif [ "$runtime" = "containerd" ]; then
                if nvidia-ctk runtime configure --runtime=containerd && systemctl restart containerd; then
                    whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit installed and configured for containerd." 10 70
                else
                    whiptail --title "Warning" --msgbox "Toolkit installed, but containerd configuration failed. Please check manually." 15 70
                fi
            fi

            # Suggest reboot if needed
            if [ -f "/var/run/reboot-required" ]; then
                if whiptail --title "Reboot Required" --yesno "A system reboot is required to complete the installation. Reboot now?" 10 60; then
                    reboot
                else
                    whiptail --title "Reboot Required" --msgbox "Please reboot your system manually to complete the installation." 10 60
                fi
            fi
        else
            whiptail --title "Error" --msgbox "Error installing NVIDIA Container Toolkit." 10 60
        fi
    else
        whiptail --title "Container Toolkit" --msgbox "Installation canceled." 10 60
    fi
}

# Troubleshooting NVIDIA
