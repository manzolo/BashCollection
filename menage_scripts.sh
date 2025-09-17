#!/bin/bash

# Codici ANSI per i colori
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Destination directories
INSTALL_DIR="/usr/local/bin"          # For main script symlinks
SCRIPT_BASE_DIR="/usr/local/share/scripts"  # For script directories and subdirectories

# Determina la directory base dello script
# Se lo script è installato come symlink, trova la directory originale
if [ -L "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
else
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
fi

# File di ignore e mapping nella root
IGNORE_FILE="$SCRIPT_DIR/.manzoloignore"
MAP_FILE="$SCRIPT_DIR/.manzolomap"
SCRIPT_NAME="manage_scripts"

# Check if the script is run with root permissions (only for install/uninstall)
check_root_permissions() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}This operation requires root permissions. Please use 'sudo'.${NC}"
        exit 1
    fi
}

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

# Nuova funzione per il menu interattivo
show_interactive_menu() {
    clear
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║              📜 SCRIPT MANAGER MENU                      ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local options=(
        "🔧 Install Scripts" 
        "🗑️  Uninstall Scripts" 
        "📋 List Available Scripts" 
        "🚀 Run a Script" 
        "🔍 Debug Information" 
        "🔄 Update Scripts from Git"
        "❌ Exit"
    )
    
    local commands=(
        "install_menu"
        "uninstall_menu" 
        "list_menu"
        "run_script_menu"
        "debug_menu"
        "update_menu"
        "exit"
    )
    
    while true; do
        echo -e "${CYAN}Choose an option:${NC}"
        echo ""
        
        for i in "${!options[@]}"; do
            echo -e "  ${YELLOW}$((i+1)).${NC} ${options[i]}"
        done
        echo ""
        
        read -p "$(echo -e "${BOLD}Enter your choice [1-${#options[@]}]:${NC} ")" choice
        
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            echo ""
            case "${commands[$((choice-1))]}" in
                "install_menu")
                    install_menu
                    ;;
                "uninstall_menu")
                    uninstall_menu
                    ;;
                "list_menu")
                    list_menu
                    ;;
                "run_script_menu")
                    run_script_menu
                    ;;
                "debug_menu")
                    debug_menu
                    ;;
                "update_menu")
                    update_menu
                    ;;
                "exit")
                    echo -e "${GREEN}Goodbye! 👋${NC}"
                    exit 0
                    ;;
            esac
        else
            echo -e "${RED}Invalid choice. Please enter a number between 1 and ${#options[@]}.${NC}"
        fi
        
        echo ""
        read -p "$(echo -e "${CYAN}Press Enter to continue...${NC}")" 
        clear
        echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${BLUE}║              📜 SCRIPT MANAGER MENU                      ║${NC}"
        echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
    done
}

# Menu per l'installazione
install_menu() {
    echo -e "${BLUE}🔧 Install Scripts${NC}"
    echo -e "${YELLOW}This will install all executable scripts to your system PATH.${NC}"
    echo ""
    
    read -p "$(echo -e "Do you want ${CYAN}debug output${NC}? [y/N]: ")" debug_choice
    
    if [[ "$debug_choice" =~ ^[Yy]$ ]]; then
        check_root_permissions
        install_scripts "--debug"
    else
        check_root_permissions
        install_scripts
    fi
}

# Menu per la disinstallazione
uninstall_menu() {
    echo -e "${RED}🗑️  Uninstall Scripts${NC}"
    echo -e "${YELLOW}This will remove all installed scripts from your system.${NC}"
    echo ""
    
    read -p "$(echo -e "${RED}Are you sure you want to uninstall all scripts? [y/N]:${NC} ")" confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        read -p "$(echo -e "Do you want ${CYAN}debug output${NC}? [y/N]: ")" debug_choice
        
        if [[ "$debug_choice" =~ ^[Yy]$ ]]; then
            check_root_permissions
            uninstall_scripts "--debug"
        else
            check_root_permissions
            uninstall_scripts
        fi
    else
        echo -e "${GREEN}Operation cancelled.${NC}"
    fi
}

# Menu per listare gli script
list_menu() {
    echo -e "${CYAN}📋 Available Scripts${NC}"
    echo ""
    
    read -p "$(echo -e "Do you want ${CYAN}detailed debug output${NC}? [y/N]: ")" debug_choice
    
    if [[ "$debug_choice" =~ ^[Yy]$ ]]; then
        list_scripts "--debug"
    else
        list_scripts
    fi
}

# Nuovo menu per eseguire script
run_script_menu() {
    echo -e "${GREEN}🚀 Run a Script${NC}"
    echo ""
    
    # Carica i dati degli script
    load_ignore_patterns
    load_name_mappings
    find_executable_scripts
    
    if [ ${#INCLUDED_FILES[@]} -eq 0 ]; then
        echo -e "${RED}No executable scripts found.${NC}"
        return
    fi
    
    # Crea array di script disponibili con nomi e percorsi
    declare -a script_names
    declare -a script_paths
    
    for script_path in "${INCLUDED_FILES[@]}"; do
        local script_name=$(get_command_name "$script_path")
        local relative_path="${script_path#$SCRIPT_DIR/}"
        
        script_names+=("$script_name")
        script_paths+=("$script_path")
    done
    
    echo -e "${CYAN}Available scripts:${NC}"
    echo ""
    
    for i in "${!script_names[@]}"; do
        local relative_path="${script_paths[i]#$SCRIPT_DIR/}"
        echo -e "  ${YELLOW}$((i+1)).${NC} ${GREEN}${script_names[i]}${NC} ${BLUE}($relative_path)${NC}"
    done
    
    echo ""
    read -p "$(echo -e "${BOLD}Select script to run [1-${#script_names[@]}] or 'q' to quit:${NC} ")" choice
    
    if [[ "$choice" = "q" ]] || [[ "$choice" = "Q" ]]; then
        echo -e "${GREEN}Operation cancelled.${NC}"
        return
    fi
    
    if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#script_names[@]}" ]; then
        local selected_script="${script_paths[$((choice-1))]}"
        local script_name="${script_names[$((choice-1))]}"
        
        echo ""
        echo -e "${GREEN}Running: ${BOLD}$script_name${NC}"
        echo -e "${CYAN}Script path: ${selected_script#$SCRIPT_DIR/}${NC}"
        echo -e "${YELLOW}─────────────────────────────────────────${NC}"
        echo ""
        
        # Chiedi se passare argomenti
        read -p "$(echo -e "Enter arguments for the script (or press Enter for none): ")" args
        
        echo ""
        echo -e "${CYAN}Executing...${NC}"
        echo ""
        
        # Esegui lo script
        if [ -n "$args" ]; then
            bash "$selected_script" $args
        else
            bash "$selected_script"
        fi
        
        local exit_code=$?
        echo ""
        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}Script completed successfully! (Exit code: $exit_code)${NC}"
        else
            echo -e "${RED}Script exited with code: $exit_code${NC}"
        fi
    else
        echo -e "${RED}Invalid choice.${NC}"
    fi
}

# Menu per il debug
debug_menu() {
    echo -e "${MAGENTA}🔍 Debug Information${NC}"
    echo ""
    debug_exclusions
}

# Menu per l'aggiornamento
update_menu() {
    echo -e "${BLUE}🔄 Update Scripts${NC}"
    echo -e "${YELLOW}This will pull the latest changes from git and reinstall scripts.${NC}"
    echo ""
    
    read -p "$(echo -e "Do you want to update scripts from git? [y/N]: ")" confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        check_root_permissions
        update_scripts
    else
        echo -e "${GREEN}Operation cancelled.${NC}"
    fi
}

# Funzione per auto-installare il manager script stesso
install_self() {
    echo -e "${BLUE}🔧 Installing script manager...${NC}"
    
    # Copia questo script nella directory di sistema
    local self_script="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    local target_script="$INSTALL_DIR/$SCRIPT_NAME"
    
    if [ -f "$self_script" ]; then
        # Crea il symlink per il manager stesso
        ln -sf "$self_script" "$target_script"
        chmod +x "$target_script"
        echo -e "${GREEN}✔ Script manager installed as '${SCRIPT_NAME}'${NC}"
        echo -e "${CYAN}You can now run '${SCRIPT_NAME}' from anywhere to access the menu.${NC}"
    else
        echo -e "${RED}✖ Could not find script file for installation.${NC}"
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
    
    # Auto-installa il manager script stesso
    install_self
    
    echo -e "\n${GREEN}Installation complete!${NC} ${#INCLUDED_FILES[@]} scripts are now available in your PATH."
    if [ "$debug_mode" = "false" ]; then
        echo -e "You may need to restart your shell for changes to take effect."
        echo -e "Run '${BOLD}${SCRIPT_NAME}${NC}' to access the interactive menu."
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
    
    # Rimuovi il symlink del manager script
    if [ -L "$INSTALL_DIR/$SCRIPT_NAME" ]; then
        rm "$INSTALL_DIR/$SCRIPT_NAME"
        if [ "$debug_mode" = "true" ]; then
            echo -e "  ${RED}✖ Script manager removed:${NC} ${YELLOW}$SCRIPT_NAME${NC}"
        fi
    fi
    
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

# Funzione principale per gestire gli argomenti
main() {
    case "$1" in
        install)
            check_root_permissions
            install_scripts "$2"
            ;;
        uninstall)
            check_root_permissions
            uninstall_scripts "$2"
            ;;
        list)
            list_scripts "$2"
            ;;
        run)
            if [ -n "$2" ]; then
                # Modalità diretta: esegui lo script specificato
                run_script_direct "$2" "${@:3}"
            else
                # Modalità interattiva: mostra menu di selezione
                run_script_menu
            fi
            ;;
        debug)
            debug_exclusions
            ;;
        update)
            check_root_permissions
            update_scripts
            ;;
        menu|"")
            # Modalità menu interattivo (default)
            show_interactive_menu
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

# Funzione per eseguire direttamente uno script by name
run_script_direct() {
    local target_name="$1"
    shift
    local args="$@"
    
    # Carica i dati degli script
    load_ignore_patterns
    load_name_mappings
    find_executable_scripts
    
    if [ ${#INCLUDED_FILES[@]} -eq 0 ]; then
        echo -e "${RED}No executable scripts found.${NC}"
        return 1
    fi
    
    # Cerca lo script per nome
    local found_script=""
    for script_path in "${INCLUDED_FILES[@]}"; do
        local script_name=$(get_command_name "$script_path")
        local default_name=$(get_default_command_name "$script_path")
        
        if [ "$script_name" = "$target_name" ] || [ "$default_name" = "$target_name" ]; then
            found_script="$script_path"
            break
        fi
    done
    
    if [ -n "$found_script" ]; then
        echo -e "${GREEN}Running: ${BOLD}$target_name${NC}"
        echo -e "${CYAN}Script path: ${found_script#$SCRIPT_DIR/}${NC}"
        echo ""
        
        # Esegui lo script
        if [ -n "$args" ]; then
            bash "$found_script" $args
        else
            bash "$found_script"
        fi
        
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}Script completed successfully! (Exit code: $exit_code)${NC}"
        else
            echo -e "${RED}Script exited with code: $exit_code${NC}"
        fi
        return $exit_code
    else
        echo -e "${RED}Script '$target_name' not found.${NC}"
        echo ""
        echo -e "${CYAN}Available scripts:${NC}"
        for script_path in "${INCLUDED_FILES[@]}"; do
            local script_name=$(get_command_name "$script_path")
            local relative_path="${script_path#$SCRIPT_DIR/}"
            echo -e "  ${GREEN}•${NC} ${YELLOW}$script_name${NC} ${BLUE}($relative_path)${NC}"
        done
        return 1
    fi
}

# Funzione per mostrare l'help
show_help() {
    echo -e "${BOLD}${BLUE}📜 Script Manager Help${NC}"
    echo ""
    echo "Usage: $SCRIPT_NAME [COMMAND] [OPTIONS] [ARGUMENTS]"
    echo ""
    echo -e "${CYAN}COMMANDS:${NC}"
    echo "  menu             Show interactive menu (default if no command given)"
    echo "  install          Install all executable scripts to system PATH"
    echo "  uninstall        Remove all installed scripts"
    echo "  list             Show available scripts"
    echo "  run [SCRIPT]     Run a specific script or show selection menu"
    echo "  debug            Show detailed debug information"
    echo "  update           Update scripts from git and reinstall"
    echo "  help             Show this help message"
    echo ""
    echo -e "${CYAN}OPTIONS:${NC}"
    echo "  --debug          Show detailed output for install/uninstall/list commands"
    echo ""
    echo -e "${CYAN}EXAMPLES:${NC}"
    echo "  $SCRIPT_NAME                    # Show interactive menu"
    echo "  $SCRIPT_NAME menu               # Show interactive menu"
    echo "  $SCRIPT_NAME install --debug    # Install with debug output"
    echo "  $SCRIPT_NAME list               # List available scripts"
    echo "  $SCRIPT_NAME run                # Show script selection menu"
    echo "  $SCRIPT_NAME run myscript       # Run 'myscript' directly"
    echo "  $SCRIPT_NAME run backup --help  # Run 'backup' script with --help"
    echo ""
    echo -e "${CYAN}FILE SELECTION RULES:${NC}"
    echo "  • Only executable .sh files in subdirectories are included"
    echo "  • Exclusions are defined in .manzoloignore in the script root"
    echo "  • Custom names are defined in .manzolomap in the script root"
    echo "  • When a mapping exists, BOTH the mapped name AND original name are created"
    echo ""
    echo -e "${CYAN}PATTERN EXAMPLES (.manzoloignore):${NC}"
    echo "    - 'vm_my_script/*' excludes all files in vm_my_script/"
    echo "    - 'vm_my_script/my_script.sh' excludes specific file"
    echo "    - Lines starting with # are comments"
    echo ""
    echo -e "${CYAN}MAPPING EXAMPLES (.manzolomap):${NC}"
    echo "    - 'vm_my_script/myscript.sh#manzolo_script' maps to 'manzolo_script'"
    echo "    - 'utils/backup.sh#backup_tool' maps to 'backup_tool'"
    echo "    - Creates both 'manzolo_script' AND 'myscript' symlinks"
}

# Esegui la funzione principale con tutti gli argomenti
main "$@"