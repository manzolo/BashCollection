# ==============================================================================
# DIALOG UI FUNCTIONS
# ==============================================================================

check_dialog() {
    if ! command -v dialog &> /dev/null; then
        echo "Installing dialog..."
        ${SUDO_CMD} apt-get update && ${SUDO_CMD} apt-get install -y dialog
    fi
    return 0
}

check_requirements() {
    local missing=()
    local required_cmds=(qemu-system-arm qemu-img wget unzip xz fdisk dialog)
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Installing missing dependencies: ${missing[*]}"
        install_dependencies "${missing[@]}"
    fi
    
    return 0
}

install_dependencies() {
    local deps=("$@")
    local apt_packages=""
    
    for dep in "${deps[@]}"; do
        case $dep in
            qemu-system-arm) apt_packages+=" qemu-system-arm qemu-utils" ;;
            xz) apt_packages+=" xz-utils" ;;
            *) apt_packages+=" $dep" ;;
        esac
    done
    
    echo "Installing: $apt_packages"
    ${SUDO_CMD} apt-get update
    ${SUDO_CMD} apt-get install -y $apt_packages
}