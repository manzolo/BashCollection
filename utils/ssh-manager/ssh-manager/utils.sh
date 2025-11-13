#!/bin/bash
# Utility functions for SSH Manager
# Provides: prerequisite installation, dependency checking

# Install prerequisites
install_prerequisites() {
    print_message "$BLUE" "🔧 Installing prerequisites..."

    if command -v dialog &> /dev/null && command -v yq &> /dev/null; then
        print_message "$GREEN" "✅ Prerequisites already installed"
        return 0
    fi

    local pkg_manager=""
    if command -v apt >/dev/null 2>&1; then
        pkg_manager="apt"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_manager="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        pkg_manager="pacman"
    else
        print_message "$RED" "❌ No supported package manager found (apt/yum/dnf/pacman)"
        return 1
    fi

    case "$pkg_manager" in
        "apt")
            sudo apt update -qq && sudo apt install -qqy dialog wget
            ;;
        "yum")
            sudo yum install -y dialog wget
            ;;
        "dnf")
            sudo dnf install -y dialog wget
            ;;
        "pacman")
            sudo pacman -Syu --noconfirm dialog wget
            ;;
    esac || {
        print_message "$RED" "❌ Error installing dialog and wget"
        return 1
    }

    if ! command -v yq &> /dev/null; then
        local arch
        arch=$(uname -m)
        local yq_url
        case "$arch" in
            x86_64) yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" ;;
            aarch64) yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64" ;;
            *) print_message "$RED" "❌ Unsupported architecture: $arch"; return 1 ;;
        esac
        sudo wget -q "$yq_url" -O /usr/local/bin/yq || {
            print_message "$RED" "❌ Error downloading yq"
            return 1
        }
        sudo chmod +x /usr/local/bin/yq
    fi

    print_message "$GREEN" "✅ Prerequisites installed successfully"
    log_message "INFO" "Prerequisites installed"
}

# Check for required packages
check_sshfs_mc() {
    local missing_packages=()

    if ! command -v sshfs &> /dev/null; then
        missing_packages+=("sshfs")
    fi

    if ! command -v mc &> /dev/null; then
        missing_packages+=("mc")
    fi

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        local packages_list=$(printf ", %s" "${missing_packages[@]}")
        packages_list=${packages_list:2}  # Remove leading ", "

        dialog --title "Missing Packages" --yesno \
            "The following packages are required for SSHFS+MC functionality:\n\n$packages_list\n\nWould you like to install them now?" \
            12 60

        if [[ $? -eq 0 ]]; then
            install_sshfs_mc_packages "${missing_packages[@]}"
            return $?
        else
            return 1
        fi
    fi

    return 0
}

# Install SSHFS and MC packages
install_sshfs_mc_packages() {
    local packages=("$@")

    print_message "$BLUE" "🔧 Installing packages: ${packages[*]}..."

    local pkg_manager=""
    if command -v apt >/dev/null 2>&1; then
        pkg_manager="apt"
    elif command -v yum >/dev/null 2>&1; then
        pkg_manager="yum"
    elif command -v dnf >/dev/null 2>&1; then
        pkg_manager="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        pkg_manager="pacman"
    else
        print_message "$RED" "❌ No supported package manager found"
        return 1
    fi

    case "$pkg_manager" in
        "apt")
            sudo apt update -qq && sudo apt install -qqy "${packages[@]}"
            ;;
        "yum")
            sudo yum install -y "${packages[@]}"
            ;;
        "dnf")
            sudo dnf install -y "${packages[@]}"
            ;;
        "pacman")
            sudo pacman -Syu --noconfirm "${packages[@]}"
            ;;
    esac || {
        print_message "$RED" "❌ Error installing packages: ${packages[*]}"
        return 1
    }

    print_message "$GREEN" "✅ Packages installed successfully"
    return 0
}
