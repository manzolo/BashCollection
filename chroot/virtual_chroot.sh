#!/bin/bash

# Script per montare immagini disco virtuali e fare chroot
# Supporta vhd, qcow2, img, raw, vmdk

set -e

# Variabili globali
NBD_DEVICE=""
MOUNT_POINTS=()
BIND_MOUNTS=()
CHROOT_DIR=""

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzione per logging
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Funzione per cleanup al termine o in caso di errore
cleanup() {
    log "Pulizia in corso..."
    
    # Smonta i bind mounts al contrario
    for ((i=${#BIND_MOUNTS[@]}-1; i>=0; i--)); do
        local mount_point="${BIND_MOUNTS[i]}"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Smonto bind mount: $mount_point"
            sudo umount "$mount_point" || warning "Errore nello smontare $mount_point"
        fi
    done
    
    # Smonta i mount points al contrario
    for ((i=${#MOUNT_POINTS[@]}-1; i>=0; i--)); do
        local mount_point="${MOUNT_POINTS[i]}"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Smonto: $mount_point"
            sudo umount "$mount_point" || warning "Errore nello smontare $mount_point"
        fi
    done
    
    # Rimuovi directory temporanee
    for mount_point in "${MOUNT_POINTS[@]}"; do
        if [[ "$mount_point" == /tmp/disk_mount_* ]]; then
            log "Rimuovo directory: $mount_point"
            rmdir "$mount_point" 2>/dev/null || true
        fi
    done
    
    # Disconnetti NBD
    if [[ -n "$NBD_DEVICE" ]]; then
        log "Disconnetto NBD device: $NBD_DEVICE"
        sudo qemu-nbd -d "$NBD_DEVICE" || warning "Errore nella disconnessione di $NBD_DEVICE"
    fi
    
    success "Cleanup completato"
}

# Trap per cleanup automatico
trap cleanup EXIT INT TERM

# Verifica dipendenze
check_dependencies() {
    local deps=("qemu-nbd" "fdisk" "lsblk" "file")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "Dipendenza mancante: $dep"
            exit 1
        fi
    done
    
    # Verifica modulo nbd
    if ! lsmod | grep -q nbd; then
        log "Carico modulo nbd..."
        sudo modprobe nbd max_part=16 || {
            error "Impossibile caricare il modulo nbd"
            exit 1
        }
    fi
}

# Trova un NBD device disponibile
find_available_nbd() {
    for i in {0..15}; do
        local nbd_dev="/dev/nbd$i"
        # Check if the device file exists
        if [[ -e "$nbd_dev" ]]; then
            # Verify if it's currently connected using qemu-nbd's status command
            if ! sudo qemu-nbd -c -d "$nbd_dev" 2>/dev/null; then
                NBD_DEVICE="$nbd_dev"
                log "NBD device disponibile trovato: $NBD_DEVICE"
                return 0
            fi
        fi
    done
    
    error "Nessun NBD device disponibile"
    return 1
}

# Connetti immagine a NBD
# Connetti immagine a NBD
connect_nbd() {
    local image_file="$1"
    
    log "Connetto $image_file a $NBD_DEVICE..."
    
    # Determina il formato dell'immagine
    local file_type=$(file "$image_file")
    local format=""
    
    if [[ "$image_file" == *.vhd ]]; then
        format="vpc" # Explicitly specify 'vpc' for .vhd files
    elif [[ "$file_type" == *"QEMU QCOW"* ]]; then
        format="qcow2"
    elif [[ "$file_type" == *"VDI disk image"* ]]; then
        format="vdi"
    elif [[ "$file_type" == *"DOS/MBR boot sector"* ]] || [[ "$image_file" == *.img ]] || [[ "$image_file" == *.raw ]]; then
        format="raw"
    elif [[ "$image_file" == *.vmdk ]]; then
        format="vmdk"
    else
        format="raw"  # Default fallback
    fi
    
    log "Formato rilevato: $format"
    
    # Use -f to explicitly specify the format and prevent the warning
    sudo qemu-nbd -c "$NBD_DEVICE" -f "$format" "$image_file"
    
    # Aspetta che il device sia pronto
    sleep 2
    
    # Rileggi la tabella delle partizioni
    sudo partprobe "$NBD_DEVICE" 2>/dev/null || true
    sleep 1
}

# Mostra partizioni disponibili
show_partitions() {
    log "Partizioni trovate:"
    
    # Usa fdisk per mostrare le partizioni
    sudo fdisk -l "$NBD_DEVICE" | grep "^$NBD_DEVICE"
    
    echo ""
    log "Dettagli filesystem:"
    
    # Mostra dettagli delle partizioni
    for part in "$NBD_DEVICE"p*; do
        if [[ -e "$part" ]]; then
            local fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null || echo "unknown")
            local label=$(sudo blkid -o value -s LABEL "$part" 2>/dev/null || echo "")
            local size=$(lsblk -no SIZE "$part" 2>/dev/null || echo "unknown")
            
            echo "  $part: $fs_type, Size: $size, Label: $label"
        fi
    done
}

# Rileva partizioni Linux e EFI
detect_partitions() {
    local linux_part=""
    local efi_part=""
    
    for part in "$NBD_DEVICE"p*; do
        if [[ -e "$part" ]]; then
            local fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null)
            
            case "$fs_type" in
                "ext4"|"ext3"|"ext2"|"btrfs"|"xfs")
                    linux_part="$part"
                    ;;
                "vfat")
                    # Verifica se è una partizione EFI
                    local part_type=$(sudo blkid -o value -s PTTYPE "$NBD_DEVICE" 2>/dev/null)
                    if [[ "$part_type" == "gpt" ]]; then
                        local gpt_type=$(sudo sgdisk -i "${part##*p}" "$NBD_DEVICE" 2>/dev/null | grep "Partition GUID code" | cut -d' ' -f4)
                        if [[ "$gpt_type" == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ]] || 
                           [[ "$gpt_type" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
                            efi_part="$part"
                        fi
                    else
                        # Per MBR, cerca partizioni FAT32 piccole (probabilmente EFI)
                        local size_mb=$(lsblk -bno SIZE "$part" 2>/dev/null | awk '{print int($1/1024/1024)}')
                        if [[ $size_mb -lt 1000 ]]; then  # Partizione EFI tipicamente < 1GB
                            efi_part="$part"
                        fi
                    fi
                    ;;
            esac
        fi
    done
    
    echo "$linux_part|$efi_part"
}

# Monta partizione
mount_partition() {
    local partition="$1"
    local mount_point="$2"
    local fs_type="$3"
    
    log "Monto $partition su $mount_point (tipo: $fs_type)"
    
    mkdir -p "$mount_point"
    
    case "$fs_type" in
        "vfat")
            sudo mount -t vfat "$partition" "$mount_point"
            ;;
        *)
            sudo mount "$partition" "$mount_point"
            ;;
    esac
    
    MOUNT_POINTS+=("$mount_point")
}

# Setup bind mounts per chroot
setup_bind_mounts() {
    local chroot_dir="$1"
    
    local bind_dirs=("proc" "sys" "dev" "dev/pts")
    
    for dir in "${bind_dirs[@]}"; do
        local target="$chroot_dir/$dir"
        mkdir -p "$target"
        
        log "Bind mount: /$dir -> $target"
        
        case "$dir" in
            "proc")
                sudo mount -t proc proc "$target"
                ;;
            "sys")
                sudo mount -t sysfs sysfs "$target"
                ;;
            "dev")
                sudo mount --bind /dev "$target"
                ;;
            "dev/pts")
                sudo mount --bind /dev/pts "$target"
                ;;
        esac
        
        BIND_MOUNTS+=("$target")
    done
}

# Entra in chroot
enter_chroot() {
    local chroot_dir="$1"
    local efi_mount="$2"
    
    CHROOT_DIR="$chroot_dir"
    
    # Monta EFI se presente
    if [[ -n "$efi_mount" ]]; then
        local efi_target="$chroot_dir/boot/efi"
        if [[ -d "$efi_target" ]]; then
            log "Monto partizione EFI in $efi_target"
            sudo mount "$efi_mount" "$efi_target"
            MOUNT_POINTS+=("$efi_target")
        else
            warning "Directory /boot/efi non trovata in chroot, salto montaggio EFI"
        fi
    fi
    
    # Setup bind mounts
    setup_bind_mounts "$chroot_dir"
    
    # Copia resolv.conf per connettività
    if [[ -f /etc/resolv.conf ]]; then
        sudo cp /etc/resolv.conf "$chroot_dir/etc/resolv.conf.backup" 2>/dev/null || true
        sudo cp /etc/resolv.conf "$chroot_dir/etc/resolv.conf"
    fi
    
    success "Ambiente chroot preparato"
    echo ""
    echo "Entrando in chroot... Usa 'exit' per uscire."
    echo "Directory chroot: $chroot_dir"
    echo ""
    
    # Entra in chroot
    sudo chroot "$chroot_dir" /bin/bash --login
    
    # Ripristina resolv.conf
    if [[ -f "$chroot_dir/etc/resolv.conf.backup" ]]; then
        sudo mv "$chroot_dir/etc/resolv.conf.backup" "$chroot_dir/etc/resolv.conf"
    fi
}

# Funzione principale
main() {
    log "Script per montaggio e chroot di immagini disco virtuali"
    echo ""

    # Check for command-line argument
    if [[ -z "$1" ]]; then
        error "Errore: Percorso del file immagine mancante."
        error "Utilizzo: sudo virtual_chroot <percorso_file_immagine>"
        exit 1
    fi
    
    local image_file="$1"

    if [[ ! -f "$image_file" ]]; then
        error "File non trovato: $image_file"
        exit 1
    fi
    
    log "File immagine selezionato: $image_file"
    
    # Verifica dipendenze
    check_dependencies
    
    # Trova NBD disponibile
    find_available_nbd
    
    # Connetti immagine
    connect_nbd "$image_file"
    
    # Mostra partizioni
    show_partitions
    
    # Rileva partizioni
    local partitions
    partitions=$(detect_partitions)
    local linux_part=$(echo "$partitions" | cut -d'|' -f1)
    local efi_part=$(echo "$partitions" | cut -d'|' -f2)
    
    if [[ -z "$linux_part" ]]; then
        error "Nessuna partizione Linux (ext4, ext3, ext2, btrfs, xfs) trovata"
        exit 1
    fi
    
    log "Partizione Linux trovata: $linux_part"
    [[ -n "$efi_part" ]] && log "Partizione EFI trovata: $efi_part"
    
    # Monta partizione Linux
    local linux_fs=$(sudo blkid -o value -s TYPE "$linux_part")
    local linux_mount="/tmp/disk_mount_$(date +%s)"
    mount_partition "$linux_part" "$linux_mount" "$linux_fs"
    
    # Verifica che sia un sistema Linux valido
    if [[ ! -d "$linux_mount/etc" ]] || [[ ! -d "$linux_mount/bin" ]] && [[ ! -d "$linux_mount/usr/bin" ]]; then
        error "Non sembra essere un sistema Linux valido (mancano /etc o /bin)"
        exit 1
    fi
    
    success "Sistema Linux montato in: $linux_mount"
    
    # Entra in chroot
    enter_chroot "$linux_mount" "$efi_part"
}

# Esegui script
main "$@"