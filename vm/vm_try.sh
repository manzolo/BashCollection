#!/bin/bash
# Uno script per avviare una macchina virtuale QEMU con dischi virtuali e un ISO di avvio opzionale.
# Supporta sia le modalità di avvio MBR che UEFI e rileva automaticamente i formati dei dischi.

# --- Configurazione Script ---
# Impostazioni predefinite della VM
VM_RAM="4G"                # RAM predefinita per la VM
VM_CPUS=2                  # Usa 2 core CPU
QEMU_ACCEL_OPTS="-enable-kvm"  # Abilita l'accelerazione hardware KVM

# --- Inizializzazione Variabili ---
DISK=""
ISO=""                     # File ISO opzionale
BOOT_MODE="mbr"           # La modalità di avvio predefinita è MBR

# --- Funzioni ---

# Mostra le istruzioni d'uso dello script ed esce.
show_help() {
    echo "Uso: $0 --hd <percorso_disco1> [--iso <percorso_iso>] [--mbr|--uefi]"
    echo ""
    echo "Opzioni:"
    echo "  --hd <percorso> Percorso del disco virtuale (supporta qcow2, raw, vmdk, vdi)"
    echo "  --iso <percorso> Percorso del file ISO da cui avviare (ha priorità di avvio)"
    echo "  --mbr           Configura per la modalità di avvio MBR (predefinito)"
    echo "  --uefi          Configura per la modalità di avvio UEFI"
    echo "  --help          Mostra questo messaggio di aiuto"
    echo ""
    echo "Formati disco supportati:"
    echo "  - qcow2 (QEMU Copy-On-Write)"
    echo "  - raw (Immagine disco raw)"
    echo "  - vmdk (VMware Virtual Disk)"
    echo "  - vdi (VirtualBox Disk Image)"
    echo ""
    echo "Esempi:"
    echo "  $0 --hd /percorso/del/disco.qcow2"
    echo "  $0 --hd /percorso/del/disco.raw --iso /percorso/del/installer.iso"
    echo "  $0 --hd /percorso/del/disco.vmdk --uefi"
    exit 0
}

# Verifica se un comando è installato ed esce con un errore se non lo è.
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        echo "Errore: Il comando richiesto '$1' non è installato. Installalo." >&2
        exit 1
    fi
}

# Verifica se un file esiste ed esce con un errore se non esiste.
check_file_exists() {
    local file=$1
    if [ ! -f "$file" ]; then
        echo "Errore: File non trovato in '$file'." >&2
        exit 1
    fi
}

# Rileva il formato del disco in base all'estensione del file e alle informazioni di qemu-img
detect_disk_format() {
    local disk_file=$1
    local format=""
    
    # Lista dei formati da testare in ordine di priorità
    local formats_to_test=("qcow2" "vmdk" "vdi" "vpc" "vhdx" "qed" "parallels")
    
    # Prima prova con qemu-img (autodetect)
    if command -v qemu-img &> /dev/null; then
        format=$(qemu-img info "$disk_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
        if [ -n "$format" ] && [ "$format" != "raw" ]; then
            echo "$format"
            return 0
        fi
        
        # Prova forzando i formati
        for test_format in "${formats_to_test[@]}"; do
            if qemu-img info -f "$test_format" "$disk_file" &>/dev/null; then
                detected=$(qemu-img info -f "$test_format" "$disk_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
                if [ "$detected" = "$test_format" ]; then
                    echo "$test_format"
                    return 0
                fi
            fi
        done
    fi
    
    if [ -r "$disk_file" ]; then
        # VHDX magic all'inizio: "vhdxfile"
        if head -c 8 "$disk_file" 2>/dev/null | grep -q "vhdxfile"; then
            echo "vhdx"
            return 0
        fi

        # VHD footer: "conectix" negli ultimi 512 byte
        if tail -c 512 "$disk_file" 2>/dev/null | grep -q "conectix"; then
            echo "vpc"
            return 0
        fi

        # QCOW2 magic: "QFI\xfb"
        if head -c 4 "$disk_file" 2>/dev/null | xxd -p | grep -q "^514649fb"; then
            echo "qcow2"
            return 0
        fi

        # VMDK magic: "KDMV"
        if head -c 4 "$disk_file" 2>/dev/null | grep -q "KDMV"; then
            echo "vmdk"
            return 0
        fi

        # VDI magic: "Oracle VM VirtualBox Disk Image"
        if head -c 64 "$disk_file" 2>/dev/null | grep -q "Oracle VM VirtualBox Disk Image"; then
            echo "vdi"
            return 0
        fi
    fi

    if command -v qemu-img &> /dev/null; then
        format=$(qemu-img info "$disk_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
        if [ -n "$format" ] && [ "$format" != "raw" ]; then
            echo "$format"
            return 0
        fi
    fi
    
    # --- Fallback: estensione file ---
    local extension="${disk_file##*.}"
    case "${extension,,}" in
        qcow2) echo "qcow2" ;;
        vmdk)  echo "vmdk"  ;;
        vdi)   echo "vdi"   ;;
        vhd)   echo "vpc"   ;;
        vhdx)  echo "vhdx"  ;;
        raw|img|iso) echo "raw" ;;
        *) echo "raw" ;;
    esac
}

# Esempio di utilizzo con output verboso
detect_disk_format_verbose() {
    local disk_file=$1
    local format
    
    echo "Rilevo il formato per: $disk_file" >&2
    
    format=$(detect_disk_format "$disk_file")
    
    echo "Formato rilevato: $format" >&2
    
    if is_format_supported "$format"; then
        echo "Il formato $format è supportato da qemu-img" >&2
    else
        echo "Avviso: Il formato $format potrebbe non essere completamente supportato" >&2
    fi
    
    echo "$format"
}

# Valida che il formato del disco sia supportato
validate_disk_format() {
    local format=$1
    case "$format" in
        qcow2|raw|vmdk|vdi|vpc|qed|vhdx)
            return 0
            ;;
        *)
            echo "Avviso: Il formato del disco '$format' potrebbe non essere completamente supportato." >&2
            echo "Procedo comunque..." >&2
            return 0
            ;;
    esac
}

# --- Logica Principale Script ---

# Verifica delle dipendenze richieste
check_dependency qemu-system-x86_64

# Analisi degli argomenti della riga di comando
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hd)
            DISK="$2"
            shift 2
            ;;
        --iso)
            ISO="$2"
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
            show_help
            ;;
    esac
done

# Valida che tutti i parametri richiesti siano forniti
if [ -z "$DISK" ]; then
    echo "Errore: Manca l'argomento richiesto: --hd" >&2
    show_help
fi

# Valida che i file forniti esistano
check_file_exists "$DISK"
if [ -n "$ISO" ]; then
    check_file_exists "$ISO"
fi

# Rileva il formato del disco
DISK_FORMAT=$(detect_disk_format "$DISK")
validate_disk_format "$DISK_FORMAT"

# Assembla le opzioni di QEMU
QEMU_OPTS=(
    "-m" "$VM_RAM"
    "-smp" "$VM_CPUS"
    "$QEMU_ACCEL_OPTS"
    "-netdev" "user,id=net0"
    "-device" "virtio-net-pci,netdev=net0"
    "-vga" "virtio"
    "-display" "sdl"
    "-usb"
    "-device" "usb-tablet"  # Migliore controllo del mouse
)

# Configura il disco e l'ISO in base alla modalità di avvio per una corretta priorità di avvio
if [ "$BOOT_MODE" = "uefi" ] && [ -n "$ISO" ]; then
    # Modalità UEFI con ISO: usa bootindex esplicito per garantire la priorità all'ISO
    QEMU_OPTS+=("-drive" "file=$ISO,format=raw,media=cdrom,readonly=on,if=none,id=cd0")
    QEMU_OPTS+=("-device" "ide-cd,drive=cd0,bootindex=0")  # L'ISO ha la priorità più alta
    QEMU_OPTS+=("-drive" "file=$DISK,format=$DISK_FORMAT,media=disk,if=none,id=hd0")
    QEMU_OPTS+=("-device" "ahci,id=ahci")  # Controller SATA
    QEMU_OPTS+=("-device" "ide-hd,drive=hd0,bus=ahci.0,bootindex=1")  # Disco su SATA
else
    # Modalità MBR o UEFI senza ISO: configurazione tradizionale
    QEMU_OPTS+=("-drive" "file=$DISK,format=$DISK_FORMAT,media=disk")
    if [ -n "$ISO" ]; then
        QEMU_OPTS+=("-drive" "file=$ISO,format=raw,media=cdrom,readonly=on")
    fi
fi

# Configura la modalità di avvio in base alla selezione dell'utente
if [ "$BOOT_MODE" = "uefi" ]; then
    # Controlla il firmware UEFI (prova i percorsi comuni)
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
        echo "Errore: Firmware OVMF non trovato. Installa il pacchetto ovmf." >&2
        echo "Cercato in: ${OVMF_PATHS[*]}" >&2
        exit 1
    fi
    
    QEMU_OPTS+=("-bios" "$OVMF_PATH")
    # Per UEFI, l'ordine di avvio è gestito da bootindex (se l'ISO è presente) o dal metodo tradizionale
    if [ -z "$ISO" ]; then
        QEMU_OPTS+=("-boot" "order=c")  # Avvia solo dal disco rigido
    fi
    # Se l'ISO è presente, il bootindex gestisce già l'ordine
else # MBR
    # Imposta l'ordine di avvio: prima l'ISO se fornito, poi il disco rigido
    if [ -n "$ISO" ]; then
        QEMU_OPTS+=("-boot" "order=d,menu=on")  # Avvia da CD-ROM con menu
    else
        QEMU_OPTS+=("-boot" "order=c")
    fi
fi

# Mostra le informazioni di avvio
echo "Avvio della VM QEMU con la seguente configurazione:"
echo "  RAM: $VM_RAM"
echo "  CPU: $VM_CPUS"
echo "  Modalità di avvio: $BOOT_MODE"
echo "  Disco rigido: $DISK (formato: $DISK_FORMAT)"
if [ -n "$ISO" ]; then
    echo "  ISO: $ISO (dispositivo di avvio primario)"
else
    echo "  Dispositivo di avvio: Disco rigido"
fi
if [ "$BOOT_MODE" = "uefi" ]; then
    echo "  Firmware UEFI: $OVMF_PATH"
fi
echo ""

# Avvia QEMU
echo "Avvio QEMU..."
qemu-system-x86_64 "${QEMU_OPTS[@]}"

# Controlla gli errori di avvio di QEMU
if [ $? -ne 0 ]; then
    echo "Errore: Impossibile avviare QEMU." >&2
    exit 1
fi

echo "Sessione QEMU terminata."
exit 0