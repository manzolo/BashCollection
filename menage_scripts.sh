#!/bin/bash

# Codici ANSI per i colori
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Destination directories
INSTALL_DIR="/usr/local/bin"          # For main script symlinks
SCRIPT_BASE_DIR="/usr/local/share/scripts"  # For script directories and subdirectories

# Directory in cui si trova questo script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# File di ignore e mapping nella root
IGNORE_FILE="$SCRIPT_DIR/.manzoloignore"
MAP_FILE="$SCRIPT_DIR/.manzolomap"

# Check if the script is run with root permissions
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use 'sudo'.${NC}"
    exit 1
fi

# Array globali per pattern di esclusione, mapping e file trovati
declare -a IGNORE_PATTERNS
declare -A NAME_MAPPINGS
declare -a INCLUDED_FILES
declare -a EXCLUDED_FILES

# Funzione per caricare i pattern di esclusione dal file .manzoloignore
load_ignore_patterns() {
    local debug_mode="${1:-false}"
    IGNORE_PATTERNS=()
    
    if [ "$debug_mode" = "true" ]; then
        echo -e "${YELLOW}>> Loading ignore patterns from: $IGNORE_FILE${NC}"
    fi
    
    if [ -f "$IGNORE_FILE" ]; then
        while IFS= read -r line; do
            # Ignora righe vuote e commenti
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
                IGNORE_PATTERNS+=("$line")
                if [ "$debug_mode" = "true" ]; then
                    echo -e "   ${CYAN}→ Pattern: $line${NC}"
                fi
            fi
        done < "$IGNORE_FILE"
        
        if [ "$debug_mode" = "true" ]; then
            echo -e "${YELLOW}>> Total ignore patterns loaded: ${#IGNORE_PATTERNS[@]}${NC}"
        fi
    else
        if [ "$debug_mode" = "true" ]; then
            echo -e "${YELLOW}>> No .manzoloignore file found, no exclusions applied${NC}"
        fi
    fi
}

# Funzione per caricare le mappature dei nomi dal file .manzolomap
load_name_mappings() {
    local debug_mode="${1:-false}"
    NAME_MAPPINGS=()
    
    if [ "$debug_mode" = "true" ]; then
        echo -e "${YELLOW}>> Loading name mappings from: $MAP_FILE${NC}"
    fi
    
    if [ -f "$MAP_FILE" ]; then
        while IFS= read -r line; do
            # Ignora righe vuote e commenti
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
                # Nuovo formato: file_path#new_name
                if [[ "$line" =~ ^([^#]+)#(.+)$ ]]; then
                    local file_path="${BASH_REMATCH[1]}"
                    local new_name="${BASH_REMATCH[2]}"
                    NAME_MAPPINGS["$file_path"]="$new_name"
                    if [ "$debug_mode" = "true" ]; then
                        echo -e "   ${CYAN}→ Mapping: $file_path -> $new_name${NC}"
                    fi
                # Mantieni compatibilità con il vecchio formato: file_path new_name
                elif [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
                    local file_path="${BASH_REMATCH[1]}"
                    local new_name="${BASH_REMATCH[2]}"
                    NAME_MAPPINGS["$file_path"]="$new_name"
                    if [ "$debug_mode" = "true" ]; then
                        echo -e "   ${CYAN}→ Mapping (old format): $file_path -> $new_name${NC}"
                    fi
                fi
            fi
        done < "$MAP_FILE"
        
        if [ "$debug_mode" = "true" ]; then
            echo -e "${YELLOW}>> Total name mappings loaded: ${#NAME_MAPPINGS[@]}${NC}"
        fi
    else
        if [ "$debug_mode" = "true" ]; then
            echo -e "${YELLOW}>> No .manzolomap file found, using default names${NC}"
        fi
    fi
}

# Funzione per ottenere il nome del comando per un file
get_command_name() {
    local script_path="$1"
    local relative_path="${script_path#$SCRIPT_DIR/}"
    
    # Controlla se esiste una mappatura personalizzata
    if [ -n "${NAME_MAPPINGS[$relative_path]}" ]; then
        echo "${NAME_MAPPINGS[$relative_path]}"
    else
        # Usa il nome del file senza estensione
        basename "$script_path" .sh
    fi
}

# Funzione per ottenere il nome di default (senza mappatura)
get_default_command_name() {
    local script_path="$1"
    basename "$script_path" .sh
}

is_file_excluded() {
    local file_path="$1"
    local relative_path="${file_path#$SCRIPT_DIR/}"
    
    # Se non ci sono pattern, il file non è escluso
    if [ ${#IGNORE_PATTERNS[@]} -eq 0 ]; then
        return 1
    fi
    
    for pattern in "${IGNORE_PATTERNS[@]}"; do
        # Controlla se il pattern corrisponde
        if [[ "$relative_path" == $pattern ]]; then
            return 0 # È escluso
        fi
        
        # Se il pattern termina con /* controlla se il file è nella directory
        if [[ "$pattern" == */ ]] && [[ "$relative_path" == $pattern* ]]; then
            return 0 # È escluso
        fi
        
        # Se il pattern termina con /* controlla se il file è nella directory
        if [[ "$pattern" == */* ]] && [[ "$relative_path" == $pattern ]]; then
            return 0 # È escluso
        fi
    done
    
    return 1 # Non è escluso
}

# Funzione per trovare tutti i file .sh eseguibili
find_executable_scripts() {
    local debug_mode="${1:-false}"
    INCLUDED_FILES=()
    EXCLUDED_FILES=()
    
    if [ "$debug_mode" = "true" ]; then
        echo -e "${YELLOW}>> Scanning for executable .sh files...${NC}"
    fi
    
    # Trova tutti i file .sh nelle sottocartelle (esclusa la root)
    while IFS= read -r script_path; do
        # Controlla se il file è eseguibile
        if [ -x "$script_path" ]; then
            if is_file_excluded "$script_path"; then
                EXCLUDED_FILES+=("$script_path")
                if [ "$debug_mode" = "true" ]; then
                    echo -e "   ${RED}✖ EXCLUDED: ${script_path#$SCRIPT_DIR/}${NC}"
                fi
            else
                INCLUDED_FILES+=("$script_path")
                if [ "$debug_mode" = "true" ]; then
                    echo -e "   ${GREEN}✔ INCLUDED: ${script_path#$SCRIPT_DIR/}${NC}"
                fi
            fi
        else
            # File .sh senza permessi di esecuzione
            EXCLUDED_FILES+=("$script_path")
            if [ "$debug_mode" = "true" ]; then
                echo -e "   ${YELLOW}⚠ NOT EXECUTABLE: ${script_path#$SCRIPT_DIR/}${NC}"
            fi
        fi
    done < <(find "$SCRIPT_DIR" -mindepth 2 -type f -name "*.sh")
    
    if [ "$debug_mode" = "true" ]; then
        echo -e "${YELLOW}>> Found ${#INCLUDED_FILES[@]} executable scripts and ${#EXCLUDED_FILES[@]} excluded/non-executable files${NC}"
    fi
}

install_scripts() {
    local debug_mode="false"
    if [ "$1" = "--debug" ]; then
        debug_mode="true"
        echo -e "${BLUE}>>> Installing scripts with debug output${NC}"
    else
        echo -e "${BLUE}>>> Installing executable scripts into: $SCRIPT_BASE_DIR and $INSTALL_DIR${NC}"
    fi
    
    mkdir -p "$SCRIPT_BASE_DIR"

    # Carica i pattern di esclusione, mappature e trova i file
    load_ignore_patterns "$debug_mode"
    load_name_mappings "$debug_mode"
    find_executable_scripts "$debug_mode"
    
    if [ "$debug_mode" = "true" ]; then
        print_file_summary
    fi
    
    # Copia tutte le sottocartelle mantenendo la struttura
    while IFS= read -r dir; do
        local relative_dir="${dir#$SCRIPT_DIR/}"
        if [ "$debug_mode" = "true" ]; then
            echo -e "${YELLOW}>> Copying directory: $relative_dir${NC}"
        fi
        cp -r "$dir" "$SCRIPT_BASE_DIR/"
        chmod -R 755 "$SCRIPT_BASE_DIR/$relative_dir"
    done < <(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type d)
    
    # Crea i symlink per i file inclusi
    for script_path in "${INCLUDED_FILES[@]}"; do
        local script_name=$(get_command_name "$script_path")
        local default_name=$(get_default_command_name "$script_path")
        local target_path="$SCRIPT_BASE_DIR/${script_path#$SCRIPT_DIR/}"
        local relative_path="${script_path#$SCRIPT_DIR/}"
        local has_mapping="${NAME_MAPPINGS[$relative_path]:+1}"
        
        # Crea il symlink principale (mappato o di default)
        # Controlla se esiste già un comando di sistema con lo stesso nome
        if command -v "$script_name" >/dev/null 2>&1 && [ ! -L "$INSTALL_DIR/$script_name" ]; then
            echo -e "  ${RED}⚠ Warning: '$script_name' conflicts with system command. Skipping.${NC}"
        else
            ln -sf "$target_path" "$INSTALL_DIR/$script_name"
            if [ "$debug_mode" = "true" ]; then
                if [ -n "$has_mapping" ]; then
                    echo -e "  ${GREEN}✔ Symlink created:${NC} ${YELLOW}$script_name${NC} ${CYAN}(mapped)${NC} -> ${BLUE}$relative_path${NC}"
                else
                    echo -e "  ${GREEN}✔ Symlink created:${NC} ${YELLOW}$script_name${NC} -> ${BLUE}$relative_path${NC}"
                fi
            fi
        fi
        
        # Se esiste una mappatura, crea anche il symlink con il nome originale (se diverso)
        if [ -n "$has_mapping" ] && [ "$script_name" != "$default_name" ]; then
            if command -v "$default_name" >/dev/null 2>&1 && [ ! -L "$INSTALL_DIR/$default_name" ]; then
                if [ "$debug_mode" = "true" ]; then
                    echo -e "  ${RED}⚠ Warning: '$default_name' conflicts with system command. Skipping original name.${NC}"
                fi
            else
                ln -sf "$target_path" "$INSTALL_DIR/$default_name"
                if [ "$debug_mode" = "true" ]; then
                    echo -e "  ${GREEN}✔ Symlink created:${NC} ${YELLOW}$default_name${NC} ${CYAN}(original)${NC} -> ${BLUE}$relative_path${NC}"
                fi
            fi
        fi
    done
    
    echo -e "\n${GREEN}Installation complete!${NC} ${#INCLUDED_FILES[@]} scripts are now available in your PATH."
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
    
    # Carica i pattern di esclusione, mappature e trova i file
    load_ignore_patterns "$debug_mode"
    load_name_mappings "$debug_mode"
    find_executable_scripts "$debug_mode"
    
    if [ "$debug_mode" = "true" ]; then
        print_file_summary
    fi
    
    # Rimuovi i symlink per i file inclusi
    for script_path in "${INCLUDED_FILES[@]}"; do
        local script_name=$(get_command_name "$script_path")
        local default_name=$(get_default_command_name "$script_path")
        local relative_path="${script_path#$SCRIPT_DIR/}"
        local has_mapping="${NAME_MAPPINGS[$relative_path]:+1}"
        
        # Rimuovi il symlink principale
        if [ -L "$INSTALL_DIR/$script_name" ]; then
            rm "$INSTALL_DIR/$script_name"
            if [ "$debug_mode" = "true" ]; then
                echo -e "  ${RED}✖ Symlink removed:${NC} ${YELLOW}$script_name${NC}"
            fi
        else
            if [ "$debug_mode" = "true" ]; then
                echo -e "  ${YELLOW}→ Symlink not found:${NC} ${YELLOW}$script_name${NC}. Skipping."
            fi
        fi
        
        # Rimuovi anche il symlink con nome originale se diverso
        if [ -n "$has_mapping" ] && [ "$script_name" != "$default_name" ]; then
            if [ -L "$INSTALL_DIR/$default_name" ]; then
                rm "$INSTALL_DIR/$default_name"
                if [ "$debug_mode" = "true" ]; then
                    echo -e "  ${RED}✖ Symlink removed:${NC} ${YELLOW}$default_name${NC} ${CYAN}(original)${NC}"
                fi
            else
                if [ "$debug_mode" = "true" ]; then
                    echo -e "  ${YELLOW}→ Symlink not found:${NC} ${YELLOW}$default_name${NC} ${CYAN}(original)${NC}. Skipping."
                fi
            fi
        fi
    done
    
    # Rimuovi la directory base
    if [ -d "$SCRIPT_BASE_DIR" ]; then
        rm -rf "$SCRIPT_BASE_DIR"
        if [ "$debug_mode" = "true" ]; then
            echo -e "  ${RED}✖ Directory removed:${NC} ${YELLOW}$SCRIPT_BASE_DIR${NC}"
        fi
    fi
    
    echo -e "\n${GREEN}Uninstallation complete!${NC}"
}

list_scripts() {
    local debug_mode="false"
    if [ "$1" = "--debug" ]; then
        debug_mode="true"
    fi
    
    # Carica i pattern di esclusione, mappature e trova i file
    load_ignore_patterns "$debug_mode"
    load_name_mappings "$debug_mode"
    find_executable_scripts "$debug_mode"
    
    if [ "$debug_mode" = "true" ]; then
        print_file_summary
    fi
    
    echo -e "${BLUE}>>> Available commands:${NC}"
    
    if [ ${#INCLUDED_FILES[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No executable scripts found.${NC}"
    else
        for script_path in "${INCLUDED_FILES[@]}"; do
            local script_name=$(get_command_name "$script_path")
            local default_name=$(get_default_command_name "$script_path")
            local relative_path="${script_path#$SCRIPT_DIR/}"
            local has_mapping="${NAME_MAPPINGS[$relative_path]:+1}"
            
            if [ -n "$has_mapping" ]; then
                if [ "$script_name" != "$default_name" ]; then
                    echo -e "  ${GREEN}•${NC} ${YELLOW}$script_name${NC} ${CYAN}(mapped from $default_name)${NC} ${BLUE}($relative_path)${NC}"
                    echo -e "  ${GREEN}•${NC} ${YELLOW}$default_name${NC} ${CYAN}(original name)${NC} ${BLUE}($relative_path)${NC}"
                else
                    echo -e "  ${GREEN}•${NC} ${YELLOW}$script_name${NC} ${BLUE}($relative_path)${NC}"
                fi
            else
                echo -e "  ${GREEN}•${NC} ${YELLOW}$script_name${NC} ${BLUE}($relative_path)${NC}"
            fi
        done
        
        # Calcola il numero totale di comandi (includendo i duplicati per i mapping)
        local total_commands=0
        for script_path in "${INCLUDED_FILES[@]}"; do
            local script_name=$(get_command_name "$script_path")
            local default_name=$(get_default_command_name "$script_path")
            local relative_path="${script_path#$SCRIPT_DIR/}"
            local has_mapping="${NAME_MAPPINGS[$relative_path]:+1}"
            
            if [ -n "$has_mapping" ] && [ "$script_name" != "$default_name" ]; then
                total_commands=$((total_commands + 2))
            else
                total_commands=$((total_commands + 1))
            fi
        done
        
        echo -e "\n${GREEN}Total:${NC} ${YELLOW}$total_commands commands${NC} (${#INCLUDED_FILES[@]} unique scripts)."
    fi
}

# Funzione per stampare il riepilogo dei file in modalità debug
print_file_summary() {
    echo -e "\n${CYAN}=== FILE SUMMARY ===${NC}"
    
    echo -e "${GREEN}>>> INCLUDED FILES (${#INCLUDED_FILES[@]}):${NC}"
    if [ ${#INCLUDED_FILES[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No files included${NC}"
    else
        for file in "${INCLUDED_FILES[@]}"; do
            echo -e "  ${GREEN}✔${NC} ${file#$SCRIPT_DIR/}"
        done
    fi
    
    echo -e "\n${RED}>>> EXCLUDED FILES (${#EXCLUDED_FILES[@]}):${NC}"
    if [ ${#EXCLUDED_FILES[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No files excluded${NC}"
    else
        for file in "${EXCLUDED_FILES[@]}"; do
            if [ ! -x "$file" ]; then
                echo -e "  ${YELLOW}⚠${NC} ${file#$SCRIPT_DIR/} ${YELLOW}(not executable)${NC}"
            else
                echo -e "  ${RED}✖${NC} ${file#$SCRIPT_DIR/} ${RED}(ignored pattern)${NC}"
            fi
        done
    fi
    echo -e "${CYAN}=====================${NC}\n"
}

# Funzione per debug completo
debug_exclusions() {
    echo -e "${BLUE}>>> Debug: Complete analysis${NC}"
    load_ignore_patterns "true"
    load_name_mappings "true"
    find_executable_scripts "true"
    print_file_summary
    
    if [ ${#NAME_MAPPINGS[@]} -gt 0 ]; then
        echo -e "${CYAN}>>> NAME MAPPINGS:${NC}"
        for file_path in "${!NAME_MAPPINGS[@]}"; do
            echo -e "  ${BLUE}$file_path${NC} -> ${YELLOW}${NAME_MAPPINGS[$file_path]}${NC}"
        done
        echo ""
    fi
    
    echo -e "${CYAN}>>> Pattern Testing Examples:${NC}"
    test_patterns=(
        "vm_my_script/*"
        "vm_my_script/my_script.sh"
        "*/test.sh"
        "chroot/old_scripts/*"
    )
    
    for pattern in "${test_patterns[@]}"; do
        echo -e "${BLUE}Pattern: $pattern${NC}"
        echo -e "  Would match files like:"
        case "$pattern" in
            *"/*")
                echo -e "    ${YELLOW}→ All files in directory: ${pattern%/*}/${NC}"
                ;;
            *"/")
                echo -e "    ${YELLOW}→ All files in directory: $pattern${NC}"
                ;;
            *)
                echo -e "    ${YELLOW}→ Exact file: $pattern${NC}"
                ;;
        esac
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
        echo "  install    Install all executable scripts to system PATH"
        echo "  uninstall  Remove all installed scripts"
        echo "  list       Show available scripts (clean output)"
        echo "  debug      Show detailed debug information"
        echo "  update     Update scripts from git and reinstall"
        echo ""
        echo "Options:"
        echo "  --debug    Show detailed output for install/uninstall/list commands"
        echo ""
        echo "File Selection Rules:"
        echo "  • Only executable .sh files in subdirectories are included"
        echo "  • Exclusions are defined in .manzoloignore in the script root"
        echo "  • Custom names are defined in .manzolomap in the script root"
        echo "  • When a mapping exists, BOTH the mapped name AND original name are created"
        echo "  • Pattern examples (.manzoloignore):"
        echo "    - 'vm_my_script/*' excludes all files in vm_my_script/"
        echo "    - 'vm_my_script/my_script.sh' excludes specific file"
        echo "    - Lines starting with # are comments"
        echo "  • Mapping examples (.manzolomap):"
        echo "    - 'vm_my_script/myscript.sh#manzolo_script' maps to 'manzolo_script'"
        echo "    - 'utils/backup.sh#backup_tool' maps to 'backup_tool'"
        echo "    - Creates both 'manzolo_script' AND 'myscript' symlinks"
        echo ""
        echo "Examples:"
        echo "  sudo $0 list           # Clean list of available scripts"
        echo "  sudo $0 list --debug   # Detailed list with inclusion/exclusion info"
        echo "  sudo $0 install --debug # Install with detailed output"
        exit 1
        ;;
esac