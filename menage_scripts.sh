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

# Funzione per caricare le regole di inclusione ed esclusione da file
load_rules() {
    local ignore_file="$SCRIPT_DIR/.manzoloignore"
    local include_file="$SCRIPT_DIR/.manzoloinclude"

    # Carica le esclusioni
    EXCLUSIONS=()
    if [ -f "$ignore_file" ]; then
        while read -r line; do
            if [[ ! -z "$line" && ! "$line" =~ ^# ]]; then
                EXCLUSIONS+=("$line")
            fi
        done < "$ignore_file"
    fi
    # Aggiungi le esclusioni dalle sottocartelle
    while read -r sub_ignore_file; do
        local parent_dir=$(dirname "$sub_ignore_file")
        EXCLUSIONS+=("${parent_dir#$SCRIPT_DIR/}/")
    done < <(find "$SCRIPT_DIR" -type f -name ".manzoloignore")
    
    # Carica le inclusioni
    INCLUSIONS=()
    if [ -f "$include_file" ]; then
        while read -r line; do
            if [[ ! -z "$line" && ! "$line" =~ ^# ]]; then
                INCLUSIONS+=("$line")
            fi
        done < "$include_file"
    fi
}

# Funzione per controllare se un file deve essere ignorato
is_ignored() {
    local relative_path="$1"
    
    # Priorità: inclusione
    for include_rule in "${INCLUSIONS[@]}"; do
        if [[ "$relative_path" =~ ^$include_rule$ ]]; then
            return 1 # Non ignorare
        fi
    done

    # Se non c'è una regola di inclusione, controlla se c'è una di esclusione
    for exclusion_rule in "${EXCLUSIONS[@]}"; do
        if [[ "$relative_path" == "$exclusion_rule"* ]]; then
            return 0 # Ignora
        fi
    done

    # Se non ci sono regole, non ignorare
    return 1
}

install_scripts() {
    echo -e "${BLUE}>>> Installing scripts into: $SCRIPT_BASE_DIR and $INSTALL_DIR${NC}"
    
    mkdir -p "$SCRIPT_BASE_DIR"

    # Carica le regole una sola volta
    load_rules

    for dir in "${SCRIPT_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            echo -e "  ${YELLOW}Directory $dir not found, skipping.${NC}"
            continue
        fi

        echo -e "${YELLOW}>> Processing directory: $dir${NC}"
        cp -r "$dir" "$SCRIPT_BASE_DIR/"
        chmod -R 755 "$SCRIPT_BASE_DIR/$dir"

        while read -r script_path; do
            local relative_path="${script_path#$SCRIPT_BASE_DIR/}"
            
            if ! is_ignored "$relative_path"; then
                local script_name=$(basename "$script_path" .sh)
                ln -sf "$script_path" "$INSTALL_DIR/$script_name"
                echo -e "  ${GREEN}✔ Symlink created:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC} -> ${BLUE}$script_path${NC}"
            fi
        done < <(find "$SCRIPT_BASE_DIR/$dir" -type f -name "*.sh")
    done
    echo -e "\n${GREEN}Installation complete!${NC} The scripts are now available in your PATH."
    echo -e "You may need to restart your shell for changes to take effect."
}

uninstall_scripts() {
    echo -e "${BLUE}>>> Uninstalling scripts from: $INSTALL_DIR and $SCRIPT_BASE_DIR${NC}"
    
    load_rules

    for dir in "${SCRIPT_DIRS[@]}"; do
        echo -e "${YELLOW}>> Processing directory: $dir${NC}"
        
        if [ -d "$SCRIPT_BASE_DIR/$dir" ]; then
            while read -r script_path; do
                local relative_path="${script_path#$SCRIPT_BASE_DIR/}"

                if ! is_ignored "$relative_path"; then
                    local script_name=$(basename "$script_path" .sh)
                    if [ -L "$INSTALL_DIR/$script_name" ]; then
                        rm "$INSTALL_DIR/$script_name"
                        echo -e "  ${RED}✖ Symlink removed:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC}"
                    else
                        echo -e "  ${YELLOW}→ Symlink not found:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC}. Skipping."
                    fi
                fi
            done < <(find "$SCRIPT_BASE_DIR/$dir" -type f -name "*.sh")
        fi
        
        if [ -d "$SCRIPT_BASE_DIR/$dir" ]; then
            rm -rf "$SCRIPT_BASE_DIR/$dir"
            echo -e "  ${RED}✖ Directory removed:${NC} ${YELLOW}$SCRIPT_BASE_DIR/$dir${NC}"
        fi
    done
    rmdir "$SCRIPT_BASE_DIR" 2>/dev/null && echo -e "  ${RED}✖ Base directory removed:${NC} ${YELLOW}$SCRIPT_BASE_DIR${NC}"
    echo -e "\n${GREEN}Uninstallation complete!${NC}"
}

list_scripts() {
    echo -e "${BLUE}>>> Available commands:${NC}"
    local count=0
    
    load_rules

    for dir in "${SCRIPT_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            continue
        fi

        while read -r script_path; do
            local relative_path="${script_path#$SCRIPT_DIR/}"
            
            if ! is_ignored "$relative_path"; then
                local script_name=$(basename "$script_path" .sh)
                echo -e "  ${GREEN}•${NC} ${YELLOW}$script_name${NC} ${BLUE}(from $dir)${NC}"
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
        install_scripts
        ;;
    uninstall)
        uninstall_scripts
        ;;
    list)
        list_scripts
        ;;
    update)
        update_scripts
        ;;
    *)
        echo "Usage: sudo $0 {install|uninstall|list|update}"
        exit 1
        ;;
esac