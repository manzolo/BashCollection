#!/bin/bash

# Script per avviare una macchina virtuale QEMU per clonare dischi virtuali.
# Rileva automaticamente i formati dei dischi virtuali e supporta modalità MBR e UEFI.
# Ottimizzato per operazioni di clonazione con ISO bootable.

# --- Configurazione Script ---
VM_RAM="4G"                    # RAM predefinita per la VM
VM_CPUS=$(nproc)               # Usa tutti i core CPU disponibili
QEMU_ACCEL_OPTS="-enable-kvm"  # Abilita accelerazione hardware KVM

# --- Inizializzazione Variabili ---
DISK1=""          # Disco sorgente
DISK2=""          # Disco destinazione  
ISO_PATH=""       # ISO bootable per clonazione
BOOT_MODE="mbr"   # Modalità boot predefinita MBR
EXTRA_DISK=""     # Disco aggiuntivo opzionale

# --- Funzioni ---

# Mostra le istruzioni d'uso dello script ed esce.
show_help() {
    echo "Uso: $0 --src <disco_sorgente> --dst <disco_destinazione> --iso <iso_bootable> [opzioni]"
    echo ""
    echo "Argomenti richiesti:"
    echo "  --src <percorso>    Disco virtuale sorgente da clonare"
    echo "  --dst <percorso>    Disco virtuale destinazione per la copia"
    echo "  --iso <percorso>    ISO bootable per clonazione (es. Clonezilla, SystemRescue)"
    echo ""
    echo "Opzioni:"
    echo "  --extra <percorso>  Disco aggiuntivo opzionale (terzo disco)"
    echo "  --mbr              Configura per avvio MBR/BIOS (predefinito)"
    echo "  --uefi             Configura per avvio UEFI"
    echo "  --ram <dimensione> Specifica RAM VM (default: 4G, es: 8G, 2048M)"
    echo "  --cpus <numero>    Numero di CPU virtuali (default: tutti i core)"
    echo "  --help             Mostra questo messaggio di aiuto"
    echo ""
    echo "Formati disco supportati:"
    echo "  - qcow2 (QEMU Copy-On-Write)"
    echo "  - raw (Immagine disco raw)"
    echo "  - vmdk (VMware Virtual Disk)"
    echo "  - vdi (VirtualBox Disk Image)"
    echo "  - vhd/vhdx (Hyper-V Virtual Hard Disk)"
    echo ""
    echo "Esempi:"
    echo "  $0 --src source.qcow2 --dst target.qcow2 --iso clonezilla.iso"
    echo "  $0 --src disk1.raw --dst disk2.raw --iso systemrescue.iso --uefi --ram 8G"
    echo "  $0 --src old.vmdk --dst new.vmdk --extra backup.qcow2 --iso clonezilla.iso"
    echo ""
    echo "Note per la clonazione:"
    echo "  - Il disco sorgente può essere montato read-only per sicurezza"
    echo "  - Il disco destinazione dovrebbe avere spazio sufficiente"
    echo "  - Usa ISO come Clonezilla o SystemRescue per operazioni di clonazione"
    exit 0
}

# Verifica se un comando è installato ed esce con errore se non lo è.
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "Errore: Il comando '$1' non è installato. Installalo con:" >&2
        case "$1" in
            qemu-system-x86_64)
                echo "  Ubuntu/Debian: sudo apt install qemu-system-x86" >&2
                echo "  Fedora/RHEL: sudo dnf install qemu-system-x86" >&2
                echo "  Arch: sudo pacman -S qemu-system-x86" >&2
                ;;
            qemu-img)
                echo "  Ubuntu/Debian: sudo apt install qemu-utils" >&2
                echo "  Fedora/RHEL: sudo dnf install qemu-img" >&2
                echo "  Arch: sudo pacman -S qemu-img" >&2
                ;;
        esac
        exit 1
    fi
}

# Verifica se un file esiste ed esce con errore se non esiste.
check_file_exists() {
    local file=$1
    local description=$2
    if [ ! -f "$file" ]; then
        echo "Errore: $description non trovato in '$file'." >&2
        exit 1
    fi
}

# Rileva automaticamente il formato di un'immagine disco.
get_disk_format() {
    local disk_path=$1
    
    # Prova con qemu-img info (più affidabile)
    local format=$(qemu-img info "$disk_path" 2>/dev/null | grep 'file format:' | awk '{print $3}')
    
    if [ -n "$format" ]; then
        echo "$format"
        return 0
    fi
    
    # Fallback su estensione file
    local extension="${disk_path##*.}"
    case "${extension,,}" in
        qcow2) echo "qcow2" ;;
        raw|img) echo "raw" ;;
        vmdk) echo "vmdk" ;;
        vdi) echo "vdi" ;;
        vhd|vhdx) echo "vpc" ;;
        *) 
            echo "raw"  # Default a raw se sconosciuto
            echo "Warning: Formato disco sconosciuto per '$disk_path', usando 'raw'." >&2
            ;;
    esac
}

# Valida le dimensioni della RAM
validate_ram() {
    local ram=$1
    if [[ ! "$ram" =~ ^[0-9]+[GMK]?$ ]]; then
        echo "Errore: Formato RAM non valido '$ram'. Usa formati come: 4G, 2048M, 512K" >&2
        exit 1
    fi
}

# Mostra informazioni sui dischi
show_disk_info() {
    local disk=$1
    local label=$2
    
    if [ -f "$disk" ]; then
        local size=$(qemu-img info "$disk" 2>/dev/null | grep 'virtual size:' | awk '{print $3, $4}')
        echo "  $label: $disk ($size)"
    fi
}

# --- Logica Principale Script ---

# Verifica dipendenze richieste
check_dependency qemu-system-x86_64
check_dependency qemu-img

# Parse argomenti riga di comando
while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)
            DISK1="$2"
            shift 2
            ;;
        --dst)
            DISK2="$2"
            shift 2
            ;;
        --iso)
            ISO_PATH="$2"
            shift 2
            ;;
        --extra)
            EXTRA_DISK="$2"
            shift 2
            ;;
        --ram)
            VM_RAM="$2"
            validate_ram "$VM_RAM"
            shift 2
            ;;
        --cpus)
            VM_CPUS="$2"
            if ! [[ "$VM_CPUS" =~ ^[0-9]+$ ]] || [ "$VM_CPUS" -le 0 ]; then
                echo "Errore: Numero CPU non valido '$VM_CPUS'." >&2
                exit 1
            fi
            shift 2
            ;;
        --mbr)
            BOOT_MODE="mbr"
            shift
            ;;
        --uefi)
            BOOT_MODE="uefi"
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Errore: Opzione non valida '$1'." >&2
            echo "Usa '$0 --help' per vedere le opzioni disponibili." >&2
            exit 1
            ;;
    esac
done

# Valida che tutti i parametri richiesti siano forniti
if [ -z "$DISK1" ] || [ -z "$DISK2" ] || [ -z "$ISO_PATH" ]; then
    echo "Errore: Mancano argomenti richiesti." >&2
    echo "Richiesti: --src, --dst, --iso" >&2
    echo "Usa '$0 --help' per maggiori informazioni." >&2
    exit 1
fi

# Valida che i file forniti esistano
check_file_exists "$ISO_PATH" "File ISO"
check_file_exists "$DISK1" "Disco sorgente"
check_file_exists "$DISK2" "Disco destinazione"
if [ -n "$EXTRA_DISK" ]; then
    check_file_exists "$EXTRA_DISK" "Disco aggiuntivo"
fi

# Rileva formati disco
DISK1_FORMAT=$(get_disk_format "$DISK1")
DISK2_FORMAT=$(get_disk_format "$DISK2")
if [ -n "$EXTRA_DISK" ]; then
    EXTRA_FORMAT=$(get_disk_format "$EXTRA_DISK")
fi

# Assembla opzioni QEMU
QEMU_OPTS=(
    "-m" "$VM_RAM"
    "-smp" "$VM_CPUS"
    "$QEMU_ACCEL_OPTS"
    "-netdev" "user,id=net0"
    "-device" "virtio-net-pci,netdev=net0"
    "-vga" "virtio"
    "-display" "sdl"
    "-usb"
    "-device" "usb-tablet"  # Migliore controllo mouse
)

# Aggiungi i dischi in ordine specifico per il boot
if [ "$BOOT_MODE" = "uefi" ]; then
    # Per UEFI: ISO deve essere il PRIMO drive per avere priorità
    QEMU_OPTS+=("-drive" "file=$ISO_PATH,format=raw,media=cdrom,readonly=on,if=none,id=cd0")
    QEMU_OPTS+=("-device" "ide-cd,drive=cd0,bootindex=0")  # CD-ROM su IDE primary master
    
    # Dischi con controller SATA per evitare conflitti IDE
    QEMU_OPTS+=("-drive" "file=$DISK1,format=$DISK1_FORMAT,media=disk,if=none,id=hd0")
    QEMU_OPTS+=("-device" "ahci,id=ahci")  # Controller AHCI/SATA
    QEMU_OPTS+=("-device" "ide-hd,drive=hd0,bus=ahci.0,bootindex=1")  # Primo disco su SATA
    QEMU_OPTS+=("-drive" "file=$DISK2,format=$DISK2_FORMAT,media=disk,if=none,id=hd1")
    QEMU_OPTS+=("-device" "ide-hd,drive=hd1,bus=ahci.1,bootindex=2")  # Secondo disco su SATA
else
    # Per MBR: ordine tradizionale
    QEMU_OPTS+=("-drive" "file=$ISO_PATH,format=raw,media=cdrom,readonly=on")
    QEMU_OPTS+=("-drive" "file=$DISK1,format=$DISK1_FORMAT,media=disk")
    QEMU_OPTS+=("-drive" "file=$DISK2,format=$DISK2_FORMAT,media=disk")
fi

# Aggiungi disco aggiuntivo se specificato
if [ -n "$EXTRA_DISK" ]; then
    if [ "$BOOT_MODE" = "uefi" ]; then
        QEMU_OPTS+=("-drive" "file=$EXTRA_DISK,format=$EXTRA_FORMAT,media=disk,if=none,id=hd2")
        QEMU_OPTS+=("-device" "ide-hd,drive=hd2,bus=ahci.2,bootindex=3")  # Terzo disco su SATA
    else
        QEMU_OPTS+=("-drive" "file=$EXTRA_DISK,format=$EXTRA_FORMAT,media=disk")
    fi
fi

# Configura modalità boot
if [ "$BOOT_MODE" = "uefi" ]; then
    # Cerca firmware UEFI in percorsi comuni
    OVMF_PATHS=(
        "/usr/share/ovmf/OVMF.fd"
        "/usr/share/OVMF/OVMF.fd"
        "/usr/share/edk2-ovmf/OVMF.fd"
        "/usr/share/qemu/OVMF.fd"
    )
    
    OVMF_PATH=""
    for path in "${OVMF_PATHS[@]}"; do
        if [ -f "$path" ]; then
            OVMF_PATH="$path"
            break
        fi
    done
    
    if [ -z "$OVMF_PATH" ]; then
        echo "Errore: Firmware OVMF non trovato. Installa il pacchetto ovmf:" >&2
        echo "  Ubuntu/Debian: sudo apt install ovmf" >&2
        echo "  Fedora/RHEL: sudo dnf install edk2-ovmf" >&2
        echo "Percorsi cercati: ${OVMF_PATHS[*]}" >&2
        exit 1
    fi
    
    QEMU_OPTS+=("-bios" "$OVMF_PATH")
    # Per UEFI, l'ordine di boot è già gestito dai bootindex
else # MBR
    QEMU_OPTS+=("-boot" "order=d,menu=on,strict=on")  # Boot SOLO da CD con menu
fi

# Mostra informazioni di avvio
echo "=== Avvio VM QEMU per Clonazione Dischi ==="
echo "Configurazione:"
echo "  RAM: $VM_RAM"
echo "  CPU: $VM_CPUS core"
echo "  Modalità boot: $BOOT_MODE"
echo "  ISO bootable: $ISO_PATH"
echo ""
echo "Dischi configurati:"
show_disk_info "$DISK1" "Sorgente"
show_disk_info "$DISK2" "Destinazione"
if [ -n "$EXTRA_DISK" ]; then
    show_disk_info "$EXTRA_DISK" "Disco aggiuntivo"
fi
if [ "$BOOT_MODE" = "uefi" ]; then
    echo "  Firmware UEFI: $OVMF_PATH"
fi
echo ""
echo "AVVERTENZA: Assicurati di avere backup dei tuoi dati prima di procedere."
echo "Premere ESC durante il boot per accedere al menu di avvio."
echo ""

# Avvia QEMU
echo "Avvio QEMU..."
qemu-system-x86_64 "${QEMU_OPTS[@]}"

# Verifica errori di avvio QEMU
if [ $? -ne 0 ]; then
    echo "Errore: Impossibile avviare QEMU." >&2
    exit 1
fi

echo "Sessione QEMU terminata."
exit 0