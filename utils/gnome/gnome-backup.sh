#!/bin/bash

# GNOME Settings Backup/Restore/Reset Script per Ubuntu
# Autore: Script per gestione configurazioni GNOME
# Versione: 1.0

set -euo pipefail

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Directory di backup predefinita
DEFAULT_BACKUP_DIR="$HOME/.gnome-backup"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Funzione per stampare messaggi colorati
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Funzione per mostrare l'aiuto
show_help() {
    cat << EOF
GNOME Settings Manager - Backup, Restore e Reset delle impostazioni GNOME

Utilizzo: $0 [OPZIONE] [DIRECTORY]

OPZIONI:
    backup      Crea un backup delle impostazioni GNOME
    restore     Ripristina le impostazioni da un backup
    reset       Reset completo delle impostazioni GNOME
    list        Mostra tutti i backup disponibili
    help        Mostra questo messaggio di aiuto

DIRECTORY:
    Percorso personalizzato per il backup (opzionale)
    Default: $DEFAULT_BACKUP_DIR

ESEMPI:
    $0 backup                           # Backup nella directory predefinita
    $0 backup /path/to/custom/backup    # Backup in directory personalizzata
    $0 restore                          # Restore dall'ultimo backup
    $0 restore /path/to/backup          # Restore da backup specifico
    $0 reset                            # Reset completo delle impostazioni
    $0 list                             # Lista tutti i backup

NOTA: Questo script richiede 'dconf' per funzionare correttamente.
EOF
}

# Verifica che dconf sia installato
check_dependencies() {
    if ! command -v dconf &> /dev/null; then
        print_message $RED "ERRORE: dconf non è installato!"
        print_message $YELLOW "Installa dconf con: sudo apt install dconf-cli"
        exit 1
    fi
}

# Funzione per creare il backup
create_backup() {
    local backup_dir=${1:-$DEFAULT_BACKUP_DIR}
    local backup_path="$backup_dir/gnome-backup-$TIMESTAMP"
    
    print_message $BLUE "Creazione backup delle impostazioni GNOME..."
    
    # Crea la directory di backup se non esiste
    mkdir -p "$backup_path"
    
    # Backup delle impostazioni dconf
    print_message $YELLOW "Backup delle impostazioni dconf..."
    dconf dump / > "$backup_path/dconf-settings.conf"
    
    # Backup delle configurazioni specifiche
    print_message $YELLOW "Backup delle configurazioni desktop..."
    
    # Desktop settings
    if dconf dump /org/gnome/desktop/ > "$backup_path/desktop-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Impostazioni desktop salvate"
    fi
    
    # Shell settings
    if dconf dump /org/gnome/shell/ > "$backup_path/shell-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Impostazioni shell salvate"
    fi
    
    # Terminal settings
    if dconf dump /org/gnome/terminal/ > "$backup_path/terminal-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Impostazioni terminale salvate"
    fi
    
    # Nautilus settings
    if dconf dump /org/gnome/nautilus/ > "$backup_path/nautilus-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Impostazioni Nautilus salvate"
    fi
    
    # Gedit settings
    if dconf dump /org/gnome/gedit/ > "$backup_path/gedit-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Impostazioni Gedit salvate"
    fi
    
    # Settings daemon
    if dconf dump /org/gnome/settings-daemon/ > "$backup_path/settings-daemon.conf" 2>/dev/null; then
        print_message $GREEN "✓ Impostazioni daemon salvate"
    fi
    
    # Salva informazioni sul backup
    cat > "$backup_path/backup-info.txt" << EOF
Backup creato il: $(date)
Sistema: $(lsb_release -d | cut -f2)
Versione GNOME: $(gnome-shell --version 2>/dev/null || echo "Non disponibile")
Utente: $USER
Hostname: $(hostname)
EOF
    
    # Crea link simbolico all'ultimo backup
    ln -sfn "$backup_path" "$backup_dir/latest"
    
    print_message $GREEN "Backup completato con successo!"
    print_message $BLUE "Percorso backup: $backup_path"
}

# Funzione per ripristinare il backup
restore_backup() {
    local backup_source=${1:-"$DEFAULT_BACKUP_DIR/latest"}
    
    # Se è una directory, usa direttamente, altrimenti assumiamo sia nella dir di backup
    if [[ -d "$backup_source" ]]; then
        local backup_path="$backup_source"
    elif [[ -d "$DEFAULT_BACKUP_DIR/$backup_source" ]]; then
        local backup_path="$DEFAULT_BACKUP_DIR/$backup_source"
    else
        print_message $RED "ERRORE: Backup non trovato: $backup_source"
        exit 1
    fi
    
    if [[ ! -f "$backup_path/dconf-settings.conf" ]]; then
        print_message $RED "ERRORE: File di backup non valido!"
        exit 1
    fi
    
    print_message $YELLOW "ATTENZIONE: Questo ripristinerà tutte le impostazioni GNOME!"
    read -p "Continuare? (s/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        print_message $BLUE "Operazione annullata."
        exit 0
    fi
    
    print_message $BLUE "Ripristino backup da: $backup_path"
    
    # Ripristina le impostazioni complete
    print_message $YELLOW "Ripristino impostazioni dconf..."
    dconf load / < "$backup_path/dconf-settings.conf"
    
    # Riavvia GNOME Shell per applicare le modifiche
    print_message $YELLOW "Riavvio GNOME Shell..."
    if [[ "$XDG_SESSION_TYPE" == "wayland" ]]; then
        print_message $YELLOW "Sessione Wayland rilevata. Potrebbe essere necessario riavviare la sessione."
    else
        # X11 session
        nohup gnome-shell --replace &>/dev/null & disown
    fi
    
    print_message $GREEN "Ripristino completato!"
    print_message $BLUE "Le modifiche potrebbero richiedere un riavvio della sessione per essere completamente applicate."
}

# Funzione per reset delle impostazioni
reset_settings() {
    print_message $YELLOW "ATTENZIONE: Questo resetterà TUTTE le impostazioni GNOME ai valori predefiniti!"
    print_message $YELLOW "Questa operazione NON può essere annullata!"
    echo
    read -p "Sei sicuro di voler continuare? (RESET/N): " -r
    echo
    if [[ ! $REPLY == "RESET" ]]; then
        print_message $BLUE "Operazione annullata."
        exit 0
    fi
    
    print_message $BLUE "Reset delle impostazioni GNOME in corso..."
    
    # Reset delle principali configurazioni GNOME
    print_message $YELLOW "Reset impostazioni desktop..."
    dconf reset -f /org/gnome/desktop/
    
    print_message $YELLOW "Reset impostazioni shell..."
    dconf reset -f /org/gnome/shell/
    
    print_message $YELLOW "Reset impostazioni terminale..."
    dconf reset -f /org/gnome/terminal/
    
    print_message $YELLOW "Reset impostazioni Nautilus..."
    dconf reset -f /org/gnome/nautilus/
    
    print_message $YELLOW "Reset impostazioni Gedit..."
    dconf reset -f /org/gnome/gedit/
    
    print_message $YELLOW "Reset impostazioni daemon..."
    dconf reset -f /org/gnome/settings-daemon/
    
    # Riavvia GNOME Shell
    print_message $YELLOW "Riavvio GNOME Shell..."
    if [[ "$XDG_SESSION_TYPE" == "wayland" ]]; then
        print_message $YELLOW "Sessione Wayland rilevata. Riavvia la sessione per applicare completamente i cambiamenti."
    else
        nohup gnome-shell --replace &>/dev/null & disown
    fi
    
    print_message $GREEN "Reset completato!"
    print_message $BLUE "Riavvia la sessione per applicare completamente tutte le modifiche."
}

# Funzione per listare i backup
list_backups() {
    local backup_dir=${1:-$DEFAULT_BACKUP_DIR}
    
    if [[ ! -d "$backup_dir" ]]; then
        print_message $YELLOW "Nessuna directory di backup trovata: $backup_dir"
        return
    fi
    
    print_message $BLUE "Backup disponibili in: $backup_dir"
    echo
    
    local found_backups=false
    for backup in "$backup_dir"/gnome-backup-*; do
        if [[ -d "$backup" ]]; then
            found_backups=true
            local backup_name=$(basename "$backup")
            local backup_date=""
            
            if [[ -f "$backup/backup-info.txt" ]]; then
                backup_date=$(head -n 1 "$backup/backup-info.txt" | cut -d: -f2- | xargs)
            fi
            
            print_message $GREEN "📁 $backup_name"
            if [[ -n "$backup_date" ]]; then
                print_message $YELLOW "   Data: $backup_date"
            fi
            echo
        fi
    done
    
    if [[ "$found_backups" == false ]]; then
        print_message $YELLOW "Nessun backup trovato."
    fi
    
    # Mostra il link all'ultimo backup
    if [[ -L "$backup_dir/latest" ]]; then
        local latest_target=$(readlink "$backup_dir/latest")
        print_message $BLUE "Ultimo backup: $(basename "$latest_target")"
    fi
}

# Funzione principale
main() {
    check_dependencies
    
    case "${1:-}" in
        "backup")
            create_backup "${2:-}"
            ;;
        "restore")
            restore_backup "${2:-}"
            ;;
        "reset")
            reset_settings
            ;;
        "list")
            list_backups "${2:-}"
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        "")
            print_message $RED "ERRORE: Nessuna opzione specificata!"
            echo
            show_help
            exit 1
            ;;
        *)
            print_message $RED "ERRORE: Opzione non riconosciuta: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

# Esegui la funzione principale con tutti gli argomenti
main "$@"