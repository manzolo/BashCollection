install_dependency() {
    local cmd=$1
    local pkg=$2
    if ! whiptail --yesno "The command '$cmd' is missing. Do you want to install it with:\nsudo apt-get install $pkg ?" 12 60; then
        error "Please install '$cmd' manually:\nsudo apt-get install $pkg"
    fi
    sudo apt-get update
    sudo apt-get install -y "$pkg" || error "Installation of $pkg failed"
}

check_dependencies() {
    local deps=("whiptail:whiptail" "7z:p7zip-full" "file:file" "isoinfo:genisoimage")
    
    # Check for xorriso first (preferred)
    if ! command -v xorriso &>/dev/null; then
        install_dependency "xorriso" "xorriso"
    fi
    
    # Check other dependencies
    for dep in "${deps[@]}"; do
        local cmd=${dep%%:*}
        local pkg=${dep##*:}
        if ! command -v "$cmd" &>/dev/null; then
            install_dependency "$cmd" "$pkg"
        fi
    done
}