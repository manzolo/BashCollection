#!/bin/bash

# Codici ANSI per i colori
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Destination directories
INSTALL_DIR="/usr/local/bin"          # For main script symlinks
SCRIPT_BASE_DIR="/usr/local/share/scripts"  # For script directories and subdirectories

# Directory in cui si trova questo script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Check if the script is run with root permissions
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use 'sudo'.${NC}"
    exit 1
fi

# List of directories to scan for scripts
SCRIPT_DIRS=("backup" "chroot" "cleaner" "docker" "nvidia" "qemu" "utils" "vm")

# Array globale per directory escluse
declare -a EXCLUDED_DIRS

# Funzione per caricare le directory escluse
load_excluded_dirs() {
    local debug_mode="${1:-false}"
    EXCLUDED_DIRS=()
    
    if [ "$debug_mode" = "true" ]; then
        echo -e "${YELLOW}>> Finding directories with .manzoloignore files...${NC}"
    fi
    
    # Trova tutti i file .manzoloignore e ottieni le loro directory padre
    while IFS= read -r ignore_file; do
        if [ -f "$ignore_file" ]; then
            local parent_dir=$(dirname "$ignore_file")
            local relative_parent="${parent_dir#$SCRIPT_DIR/}"
            
            EXCLUDED_DIRS+=("$relative_parent")
            if [ "$debug_mode" = "true" ]; then
        echo -e "   ${RED}✖${NC} Excluding files in directory: $relative_parent (and its subdirectories)"
    fi
        fi
    done < <(find "$SCRIPT_DIR" -name ".manzoloignore" -type f)
    
    if [ "$debug_mode" = "true" ]; then
        echo -e "${YELLOW}>> Total directories with file exclusions: ${#EXCLUDED_DIRS[@]}${NC}"
    fi
}

# Funzione per controllare se un file è in una sottocartella esclusa
is_in_excluded_dir() {
    local file_path="$1"
    local debug_mode="${2:-false}"
    local relative_path
    
    # Calcola il percorso relativo correttamente
    if [[ "$file_path" =~ ^$SCRIPT_BASE_DIR ]]; then
        relative_path="${file_path#$SCRIPT_BASE_DIR/}"
    else
        relative_path="${file_path#$SCRIPT_DIR/}"
    fi
    
    # Controlla se il file è in una directory esclusa o sue sottocartelle
    for excluded_dir in "${EXCLUDED_DIRS[@]}"; do
        # Caso 1: File direttamente nella directory con .manzoloignore (da escludere)
        # Esempio: chroot/manzolo_chroot/mount.sh dove excluded_dir = chroot/manzolo_chroot
        if [[ "$relative_path" == "$excluded_dir"/*.sh ]]; then
            if [ "$debug_mode" = "true" ]; then
                echo -e "   ${RED}✖ EXCLUDED: $relative_path (direct file in excluded dir: $excluded_dir)${NC}" >&2
            fi
            return 0 # È escluso
        fi
        
        # Caso 2: File in sottocartelle della directory con .manzoloignore (da escludere)
        # Esempio: vm/vm_disk_manager/mount/utils.sh dove excluded_dir = vm/vm_disk_manager
        if [[ "$relative_path" == "$excluded_dir"/*/* ]]; then
            if [ "$debug_mode" = "true" ]; then
                echo -e "   ${RED}✖ EXCLUDED: $relative_path (subdirectory of: $excluded_dir)${NC}" >&2
            fi
            return 0 # È escluso
        fi
    done
    
    if [ "$debug_mode" = "true" ]; then
        echo -e "   ${GREEN}✔ INCLUDED: $relative_path${NC}" >&2
    fi
    return 1 # Non è escluso
}

install_scripts() {
    local debug_mode="false"
    if [ "$1" = "--debug" ]; then
        debug_mode="true"
        echo -e "${BLUE}>>> Installing scripts with debug output${NC}"
    else
        echo -e "${BLUE}>>> Installing scripts into: $SCRIPT_BASE_DIR and $INSTALL_DIR${NC}"
    fi
    
    mkdir -p "$SCRIPT_BASE_DIR"

    # Carica le directory escluse
    load_excluded_dirs "$debug_mode"

    for dir in "${SCRIPT_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            if [ "$debug_mode" = "true" ]; then
                echo -e "  ${YELLOW}Directory $dir not found, skipping.${NC}"
            fi
            continue
        fi

        if [ "$debug_mode" = "true" ]; then
            echo -e "${YELLOW}>> Processing directory: $dir${NC}"
        fi
        cp -r "$dir" "$SCRIPT_BASE_DIR/"
        chmod -R 755 "$SCRIPT_BASE_DIR/$dir"

        while IFS= read -r script_path; do
            if ! is_in_excluded_dir "$script_path" "$debug_mode"; then
                local script_name=$(basename "$script_path" .sh)
                
                # Controlla se esiste già un comando di sistema con lo stesso nome
                if command -v "$script_name" >/dev/null 2>&1 && [ ! -L "$INSTALL_DIR/$script_name" ]; then
                    echo -e "  ${RED}⚠ Warning: '$script_name' conflicts with system command. Skipping.${NC}"
                    continue
                fi
                
                ln -sf "$script_path" "$INSTALL_DIR/$script_name"
                if [ "$debug_mode" = "true" ]; then
                    echo -e "  ${GREEN}✔ Symlink created:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC} -> ${BLUE}$script_path${NC}"
                fi
            else
                if [ "$debug_mode" = "true" ]; then
                    echo -e "  ${YELLOW}→ Skipping excluded script: $(basename "$script_path")${NC}"
                fi
            fi
        done < <(find "$SCRIPT_BASE_DIR/$dir" -type f -name "*.sh")
    done
    echo -e "\n${GREEN}Installation complete!${NC} The scripts are now available in your PATH."
    if [ "$debug_mode" = "false" ]; then
        echo -e "You may need to restart your shell for changes to take effect."
    fi
}

uninstall_scripts() {
    local debug_mode="false"
    if [ "$1" = "--debug" ]; then
        debug_mode="true"
        echo -e "${BLUE}>>> Uninstalling scripts with debug output${NC}"
    else
        echo -e "${BLUE}>>> Uninstalling scripts from: $INSTALL_DIR and $SCRIPT_BASE_DIR${NC}"
    fi
    
    load_excluded_dirs "$debug_mode"

    for dir in "${SCRIPT_DIRS[@]}"; do
        if [ "$debug_mode" = "true" ]; then
            echo -e "${YELLOW}>> Processing directory: $dir${NC}"
        fi
        
        if [ -d "$SCRIPT_BASE_DIR/$dir" ]; then
            while IFS= read -r script_path; do
                if ! is_in_excluded_dir "$script_path" "$debug_mode"; then
                    local script_name=$(basename "$script_path" .sh)
                    if [ -L "$INSTALL_DIR/$script_name" ]; then
                        rm "$INSTALL_DIR/$script_name"
                        if [ "$debug_mode" = "true" ]; then
                            echo -e "  ${RED}✖ Symlink removed:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC}"
                        fi
                    else
                        if [ "$debug_mode" = "true" ]; then
                            echo -e "  ${YELLOW}→ Symlink not found:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC}. Skipping."
                        fi
                    fi
                fi
            done < <(find "$SCRIPT_BASE_DIR/$dir" -type f -name "*.sh")
        fi
        
        if [ -d "$SCRIPT_BASE_DIR/$dir" ]; then
            rm -rf "$SCRIPT_BASE_DIR/$dir"
            if [ "$debug_mode" = "true" ]; then
                echo -e "  ${RED}✖ Directory removed:${NC} ${YELLOW}$SCRIPT_BASE_DIR/$dir${NC}"
            fi
        fi
    done
    rmdir "$SCRIPT_BASE_DIR" 2>/dev/null && [ "$debug_mode" = "true" ] && echo -e "  ${RED}✖ Base directory removed:${NC} ${YELLOW}$SCRIPT_BASE_DIR${NC}"
    echo -e "\n${GREEN}Uninstallation complete!${NC}"
}

list_scripts() {
    local debug_mode="false"
    if [ "$1" = "--debug" ]; then
        debug_mode="true"
    fi
    
    echo -e "${BLUE}>>> Available commands:${NC}"
    local count=0
    
    load_excluded_dirs "$debug_mode"

    for dir in "${SCRIPT_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            continue
        fi

        while IFS= read -r script_path; do            
            if ! is_in_excluded_dir "$script_path" "$debug_mode"; then
                local script_name=$(basename "$script_path" .sh)
                local relative_path="${script_path#$SCRIPT_DIR/}"
                echo -e "  ${GREEN}•${NC} ${YELLOW}$script_name${NC} ${BLUE}($relative_path)${NC}"
                count=$((count + 1))
            fi
        done < <(find "$dir" -type f -name "*.sh")
    done

    if [ "$count" -eq 0 ]; then
        echo -e "  ${YELLOW}No scripts found.${NC}"
    else
        echo -e "\n${GREEN}Total:${NC} ${YELLOW}$count commands.${NC}"
    fi
}

# Funzione per debug
debug_exclusions() {
    echo -e "${BLUE}>>> Debug: Checking directory exclusions${NC}"
    load_excluded_dirs
    
    echo -e "\n${YELLOW}>> Testing specific files:${NC}"
    test_files=(
        "chroot/manzolo_chroot/mount.sh"
        "chroot/manzolo_chroot/sudo.sh" 
        "chroot/manzolo_chroot.sh"
        "vm/vm_disk_manager/mount/utils.sh"
        "vm/vm_disk_manager.sh"
    )
    
    for test_file in "${test_files[@]}"; do
        if [ -f "$test_file" ]; then
            echo -e "\n${BLUE}Testing: $test_file${NC}"
            if is_in_excluded_dir "$SCRIPT_DIR/$test_file"; then
                echo -e "${RED}Result: EXCLUDED (in subdirectory)${NC}"
            else
                echo -e "${GREEN}Result: INCLUDED${NC}"
            fi
        fi
    done
}

update_scripts() {
    echo -e "${BLUE}>>> Updating scripts...${NC}"

    if [ "$(id -u)" -eq 0 ]; then
        USER_NAME=$(logname)
        echo -e "${YELLOW}>> Running git pull as user: ${USER_NAME}...${NC}"
        sudo -u "$USER_NAME" git -C "$SCRIPT_DIR" pull
        PULL_RESULT=$?
    else
        echo -e "${YELLOW}>> Running git pull as your user...${NC}"
        git -C "$SCRIPT_DIR" pull
        PULL_RESULT=$?
    fi
    
    if [ $PULL_RESULT -eq 0 ]; then
        echo -e "${GREEN}✔ Git pull successful!${NC}"
        echo -e "${YELLOW}>> Re-running installation to update scripts...${NC}"
        install_scripts
    else
        echo -e "${RED}✖ Git pull failed. Please check your network connection or repository status.${NC}"
        exit 1
    fi
}

case "$1" in
    install)
        install_scripts "$2"
        ;;
    uninstall)
        uninstall_scripts "$2"
        ;;
    list)
        list_scripts "$2"
        ;;
    debug)
        debug_exclusions
        ;;
    update)
        update_scripts
        ;;
    *)
        echo "Usage: sudo $0 {install|uninstall|list|debug|update} [--debug]"
        echo ""
        echo "Commands:"
        echo "  install    Install all scripts to system PATH"
        echo "  uninstall  Remove all installed scripts"
        echo "  list       Show available scripts (clean output)"
        echo "  debug      Show detailed debug information"
        echo "  update     Update scripts from git and reinstall"
        echo ""
        echo "Options:"
        echo "  --debug    Show detailed output for install/uninstall/list commands"
        echo ""
        echo "Examples:"
        echo "  sudo $0 list           # Clean list of available scripts"
        echo "  sudo $0 list --debug   # Detailed list with exclusion info"
        echo "  sudo $0 install --debug # Install with detailed output"
        exit 1
        ;;
esac