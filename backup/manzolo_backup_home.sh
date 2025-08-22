#!/bin/bash

# Script di backup di directory multiple con rsync (con supporto sudo per file root)
# Uso: sudo ./backup_multi.sh /percorso/disco/destinazione [username]

set -e # Esci in caso di errore

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzione per mostrare l'uso
show_usage() {
    echo -e "${BLUE}Uso:${NC} sudo $0 <disco_destinazione> [username]"
    echo -e "${BLUE}Esempio:${NC} sudo $0 /media/backup"
    echo -e "${BLUE}Esempio:${NC} sudo $0 /mnt/usb_backup $USER"
    echo ""
    echo -e "${YELLOW}Opzioni disponibili:${NC}"
    echo "  -h, --help       Mostra questo messaggio di aiuto"
    echo "  -n, --dry-run    Esegui una simulazione senza copiare i file"
    echo "  -v, --verbose    Output dettagliato"
    echo ""
    echo -e "${RED}NOTA: Questo script deve essere eseguito con sudo per gestire i file di root${NC}"
    exit 1
}

# Funzione per eseguire il backup di una singola directory
perform_backup() {
    local source_dir="$1"
    local dest_dir="$2"
    local log_file="$3"
    local dry_run_mode="$4"
    local rsync_options="$5"
    local exclude_file="$6"

    # Crea la directory di destinazione se non esiste
    mkdir -p "$dest_dir"

    # Aggiungi backup incrementale se esiste un backup precedente
    local link_dest_option=""
    local previous_backup=$(find "$(dirname "$dest_dir")" -maxdepth 1 -name "$(basename "$dest_dir")" -type d 2>/dev/null | head -1)
    if [ -n "$previous_backup" ] && [ -d "$previous_backup" ]; then
        link_dest_option="--link-dest=$previous_backup"
        echo -e "${GREEN}Trovato backup precedente per $source_dir, verrà utilizzato per il backup incrementale${NC}"
    fi

    echo -e "${YELLOW}Avvio backup di ${source_dir} con privilegi di root...${NC}"

    if rsync $rsync_options $link_dest_option "$source_dir/" "$dest_dir/" 2>&1 | tee "$log_file"; then
        if [ "$dry_run_mode" = false ]; then
            echo -e "${GREEN}✓ Backup completato con successo per ${source_dir}!${NC}"
        else
            echo -e "${YELLOW}✓ Simulazione completata per ${source_dir}${NC}"
        fi
        return 0
    else
        echo -e "${RED}✗ Errore durante il backup di ${source_dir}${NC}"
        return 1
    fi
}

# Verifica che lo script sia eseguito con sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Errore:${NC} Questo script deve essere eseguito con sudo per gestire i file di root"
    echo -e "${YELLOW}Usa:${NC} sudo $0 $*"
    exit 1
fi

# Determina l'utente reale (quello che ha chiamato sudo)
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    echo -e "${RED}Errore:${NC} Impossibile determinare l'utente reale. Specifica l'username come secondo parametro."
    exit 1
fi

# Variabili predefinite
DRY_RUN=false
VERBOSE=false
BACKUP_DIRS=("/etc" "/opt") # Array di directory da backuppare, /etc come esempio
EXCLUDE_FILE="/tmp/rsync_exclude_$$"

# Parse degli argomenti
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -*)
            echo -e "${RED}Opzione sconosciuta:${NC} $1"
            show_usage
            ;;
        *)
            if [ -z "$DEST_DISK" ]; then
                DEST_DISK="$1"
            elif [ -z "$OVERRIDE_USER" ]; then
                OVERRIDE_USER="$1"
                REAL_USER="$1"
            else
                echo -e "${RED}Troppi argomenti.${NC}"
                show_usage
            fi
            shift
            ;;
    esac
done

# Verifica che sia stato specificato il disco di destinazione
if [ -z "$DEST_DISK" ]; then
    echo -e "${RED}Errore:${NC} Specifica il percorso del disco di destinazione"
    show_usage
fi

# Aggiungi la home dell'utente all'elenco delle directory da backuppare
REAL_USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [ ! -d "$REAL_USER_HOME" ]; then
    echo -e "${RED}Errore:${NC} La directory home '$REAL_USER_HOME' per l'utente '$REAL_USER' non esiste"
    exit 1
fi
BACKUP_DIRS+=("$REAL_USER_HOME")

# Crea file di esclusione per rsync
cat > "$EXCLUDE_FILE" << EOF
.cache/
.local/share/Trash/
.thumbnails/
Downloads/
.gvfs
.mozilla/firefox/*/Cache/
.mozilla/firefox/*/cache2/
.config/google-chrome/*/Cache/
.config/chromium/*/Cache/
node_modules/
.npm/
.gradle/cache/
__pycache__/
*.tmp
*.temp
.DS_Store
Thumbs.db
EOF

# Funzione di cleanup
cleanup() {
    rm -f "$EXCLUDE_FILE"
}
trap cleanup EXIT

echo -e "${BLUE}=== BACKUP MULTIPLE DIRECTORY (CON SUDO) ===${NC}"
echo -e "${BLUE}Utente:${NC} $REAL_USER"
echo -e "${BLUE}Data/Ora:${NC} $(date)"

# Verifica che il disco di destinazione esista e sia scrivibile
if [ ! -d "$DEST_DISK" ]; then
    echo -e "${RED}Errore:${NC} Il disco di destinazione '$DEST_DISK' non esiste o non è montato"
    exit 1
fi

if [ ! -w "$DEST_DISK" ]; then
    echo -e "${RED}Errore:${NC} Non hai i permessi di scrittura su '$DEST_DISK'"
    exit 1
fi

# Costruisci le opzioni di rsync con preservazione completa dei permessi
RSYNC_OPTIONS="-ahAXS --delete --delete-excluded --exclude-from=$EXCLUDE_FILE"
if [ "$VERBOSE" = true ]; then
    RSYNC_OPTIONS="$RSYNC_OPTIONS --progress --stats"
fi
if [ "$DRY_RUN" = true ]; then
    RSYNC_OPTIONS="$RSYNC_OPTIONS --dry-run"
    echo -e "${YELLOW}MODALITÀ SIMULAZIONE ATTIVATA${NC}"
fi

# Loop per backuppare ogni directory
for SOURCE_DIR in "${BACKUP_DIRS[@]}"; do
    # Crea un nome di directory di destinazione unico basato sul nome della sorgente
    BASE_DIR=$(basename "$SOURCE_DIR")
    DEST_DIR="$DEST_DISK/backup_$(echo $BASE_DIR | sed 's/\//_/g')"
    BACKUP_DATE=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="$DEST_DIR/backup_$BACKUP_DATE.log"

    echo -e "\n${BLUE}--- Backup di ${SOURCE_DIR} ---${NC}"
    echo -e "${BLUE}Sorgente:${NC} $SOURCE_DIR"
    echo -e "${BLUE}Destinazione:${NC} $DEST_DIR"

    # Esegui il backup
    if perform_backup "$SOURCE_DIR" "$DEST_DIR" "$LOG_FILE" "$DRY_RUN" "$RSYNC_OPTIONS" "$EXCLUDE_FILE"; then
        if [ "$DRY_RUN" = false ]; then
            # Imposta i permessi corretti per il log file
            chown "$REAL_USER:$(id -gn "$REAL_USER")" "$LOG_FILE" 2>/dev/null || true
        fi
    fi
done

echo -e "\n${GREEN}=== Tutti i backup terminati alle $(date) ===${NC}"

# Mostra statistiche dello spazio
echo -e "\n${BLUE}Spazio utilizzato dai backup:${NC}"
du -sh "$DEST_DISK"/backup_* 2>/dev/null || echo "Impossibile calcolare lo spazio utilizzato"

# Mostra spazio libero rimanente
echo -e "${BLUE}Spazio libero rimanente su $DEST_DISK:${NC}"
df -h "$DEST_DISK" | tail -1 | awk '{print $4 " disponibili di " $2}'

echo -e "\n${YELLOW}NOTA:${NC} I permessi e la proprietà originali sono stati preservati"
