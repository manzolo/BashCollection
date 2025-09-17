#!/bin/bash

# Disk Cloner with Proportional Resize and UUID Preservation
# Usage: ./disk_cloner.sh [--dry-run]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${YELLOW}DRY RUN MODE - No actual operations will be performed${NC}"
    echo
fi

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Function to get disk size in bytes
get_disk_size() {
    local disk="$1"
    blockdev --getsize64 "$disk" 2>/dev/null || echo "0"
}

# Function to get partition size in bytes
get_partition_size() {
    local partition="$1"
    blockdev --getsize64 "$partition" 2>/dev/null || echo "0"
}

# Function to get partition type
get_partition_type() {
    local partition="$1"
    lsblk -no FSTYPE "$partition" 2>/dev/null | head -n1 | tr -d ' '
}

# Function to get filesystem UUID
get_filesystem_uuid() {
    local partition="$1"
    blkid -s UUID -o value "$partition" 2>/dev/null || echo ""
}

# Function to get partition UUID (GPT PARTUUID)
get_partition_uuid() {
    local partition="$1"
    blkid -s PARTUUID -o value "$partition" 2>/dev/null || echo ""
}

# Function to get disk UUID (GPT disk identifier)
get_disk_uuid() {
    local disk="$1"
    blkid -s PTUUID -o value "$disk" 2>/dev/null || echo ""
}

# Function to set filesystem UUID
set_filesystem_uuid() {
    local partition="$1"
    local uuid="$2"
    local fs_type="$3"
    
    if [[ -z "$uuid" ]]; then
        print_warning "No UUID to set for $partition"
        return 0
    fi
    
    case "$fs_type" in
        "ext2"|"ext3"|"ext4")
            print_info "Setting ext filesystem UUID: $uuid"
            tune2fs -U "$uuid" "$partition"
            ;;
        "vfat"|"fat32")
            print_info "Setting FAT filesystem UUID: $uuid"
            # FAT UUID è diverso, usa solo i primi 8 caratteri senza trattini
            local fat_uuid=$(echo "$uuid" | tr -d '-' | cut -c1-8 | tr '[:lower:]' '[:upper:]')
            fatlabel "$partition" > /dev/null 2>&1 || true
            # Usa mlabel se disponibile per impostare l'UUID FAT
            if command -v mlabel >/dev/null 2>&1; then
                echo "drive z: file=\"$partition\"" > /tmp/mtools.conf.$$
                MTOOLSRC=/tmp/mtools.conf.$$ mlabel -N "${fat_uuid:0:8}" z: 2>/dev/null || true
                rm -f /tmp/mtools.conf.$$
            else
                print_warning "Cannot set FAT UUID - mlabel not available"
            fi
            ;;
        "ntfs")
            if command -v ntfslabel >/dev/null 2>&1; then
                print_info "NTFS UUID will be set by ntfsclone"
            else
                print_warning "Cannot set NTFS UUID - ntfs-3g not available"
            fi
            ;;
        "swap")
            print_info "Setting swap UUID: $uuid"
            mkswap -U "$uuid" "$partition" >/dev/null
            ;;
        "xfs")
            print_info "Setting XFS UUID: $uuid"
            xfs_admin -U "$uuid" "$partition" 2>/dev/null || true
            ;;
        *)
            print_warning "Cannot set UUID for filesystem type: $fs_type"
            ;;
    esac
}

# Function to set partition UUID using sgdisk
set_partition_uuid() {
    local disk="$1"
    local part_num="$2"
    local part_uuid="$3"
    
    if [[ -z "$part_uuid" ]]; then
        print_warning "No partition UUID to set for partition $part_num"
        return 0
    fi
    
    if command -v sgdisk >/dev/null 2>&1; then
        print_info "Setting partition UUID for partition $part_num: $part_uuid"
        sgdisk --partition-guid="$part_num:$part_uuid" "$disk"
    else
        print_warning "sgdisk not available - cannot set partition UUID"
    fi
}

# Function to set disk UUID
set_disk_uuid() {
    local disk="$1"
    local disk_uuid="$2"
    
    if [[ -z "$disk_uuid" ]]; then
        print_warning "No disk UUID to set"
        return 0
    fi
    
    if command -v sgdisk >/dev/null 2>&1; then
        print_info "Setting disk UUID: $disk_uuid"
        sgdisk --disk-guid="$disk_uuid" "$disk"
    else
        print_warning "sgdisk not available - cannot set disk UUID"
    fi
}

# Function to check if partition is EFI
is_efi_partition() {
    local partition="$1"
    local part_num="${partition##*[a-z]}"
    local disk_path="${partition%$part_num}"
    
    # Check partition type with fdisk
    local part_type=$(fdisk -l "$disk_path" 2>/dev/null | grep "^$partition" | grep -i "EFI\|ef00" || true)
    local fs_type=$(get_partition_type "$partition")
    
    # Check if it's marked as EFI System partition or has vfat filesystem in typical EFI location
    if [[ -n "$part_type" ]] || [[ "$fs_type" == "vfat" && "$part_num" == "1" ]]; then
        # Additional check for EFI content if mounted
        if mount | grep -q "$partition"; then
            local mount_point=$(mount | grep "$partition" | awk '{print $3}' | head -n1)
            [[ -d "$mount_point/EFI" ]]
        else
            # Try to mount temporarily to check
            local temp_mount="/tmp/efi_check_$$"
            mkdir -p "$temp_mount"
            if mount "$partition" "$temp_mount" 2>/dev/null; then
                local is_efi=false
                [[ -d "$temp_mount/EFI" ]] && is_efi=true
                umount "$temp_mount" 2>/dev/null || true
                rmdir "$temp_mount" 2>/dev/null || true
                $is_efi
            else
                # Fallback: assume first vfat partition is EFI
                [[ "$fs_type" == "vfat" && "$part_num" == "1" ]]
            fi
        fi
    else
        false
    fi
}

# Function to list available disks
list_disks() {
    print_info "Available disks:"
    lsblk -dpno NAME,SIZE,MODEL | grep -v loop | while read -r line; do
        echo "  $line"
    done
}

# Function to select disk
select_disk() {
    local prompt="$1"
    local disk
    
    while true; do
        read -p "$prompt: " disk
        
        # Normalize and clean up the input
        local normalized_disk
        if [[ "$disk" =~ ^/dev/ ]]; then
            normalized_disk="$disk"
        else
            normalized_disk="/dev/$disk"
        fi
        
        if [[ ! -b "$normalized_disk" ]]; then
            print_error "Invalid disk: $normalized_disk"
            continue
        fi
        
        if [[ "$normalized_disk" =~ [0-9]$ ]]; then
            print_error "Please specify the disk device (e.g., /dev/sda), not a partition"
            continue
        fi
        
        printf "%s" "$normalized_disk"
        break
    done
}

# Function to get partitions info with UUIDs
get_partitions_info() {
    local disk="$1"
    local -n partitions_ref=$2
    
    partitions_ref=()
    
    # Estrai il nome base del disco (es. sdd da /dev/sdd)
    local disk_base=$(basename "$disk")
    
    # Ottieni l'UUID del disco
    local disk_uuid=$(get_disk_uuid "$disk")
    print_info "Source disk UUID: ${disk_uuid:-none}"
    
    # Usa lsblk per ottenere le partizioni
    local partitions_list
    partitions_list=$(lsblk -ln -o NAME "$disk" | grep "^${disk_base}[0-9]")
    
    if [[ -z "$partitions_list" ]]; then
        print_warning "No partitions found on $disk"
        return 1
    fi
    
    while IFS= read -r partition_name; do
        local partition_path="/dev/$partition_name"
        
        # Verifica che la partizione esista
        if [[ ! -b "$partition_path" ]]; then
            print_warning "Partition $partition_path does not exist, skipping"
            continue
        fi
        
        local size=$(get_partition_size "$partition_path")
        local fs_type=$(get_partition_type "$partition_path")
        local fs_uuid=$(get_filesystem_uuid "$partition_path")
        local part_uuid=$(get_partition_uuid "$partition_path")
        local is_efi=false
        
        if is_efi_partition "$partition_path"; then
            is_efi=true
        fi
        
        # Solo aggiungi se la dimensione è > 0
        if [[ $size -gt 0 ]]; then
            # Format: path,size,fs_type,is_efi,fs_uuid,part_uuid,disk_uuid
            partitions_ref+=("$partition_path,$size,$fs_type,$is_efi,$fs_uuid,$part_uuid,$disk_uuid")
            print_info "Found partition: $partition_path ($(numfmt --to=iec --suffix=B $size), $fs_type, EFI: $is_efi)"
            print_info "  FS UUID: ${fs_uuid:-none}, Part UUID: ${part_uuid:-none}"
        fi
    done <<< "$partitions_list"
    
    if [[ ${#partitions_ref[@]} -eq 0 ]]; then
        print_error "No valid partitions found on $disk"
        return 1
    fi
    
    return 0
}

# Function to calculate proportional sizes
calculate_proportional_sizes() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    local -n target_sizes_ref=$4
    
    local source_size=$(get_disk_size "$source_disk")
    local target_size=$(get_disk_size "$target_disk")
    
    target_sizes_ref=()
    
    print_info "Source disk size: $(numfmt --to=iec --suffix=B $source_size)"
    print_info "Target disk size: $(numfmt --to=iec --suffix=B $target_size)"
    
    # Calcola la dimensione totale delle partizioni
    local total_partitions_size=0
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
        total_partitions_size=$((total_partitions_size + size))
    done
    
    print_info "Total partitions size: $(numfmt --to=iec --suffix=B $total_partitions_size)"
    
    # Riserva spazio per la tabella delle partizioni (2MB all'inizio e alla fine)
    local usable_target_size=$((target_size - 4 * 1024 * 1024))
    
    if [[ $total_partitions_size -le $usable_target_size ]]; then
        print_info "Target disk has enough space, keeping original sizes"
        for part_info in "${source_parts_ref[@]}"; do
            IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
            target_sizes_ref+=("$size")
        done
        return
    fi
    
    print_info "Target disk is smaller, calculating proportional sizes..."
    
    local total_efi_size=0
    local total_other_size=0
    
    # Calcola dimensioni EFI e altre
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
        if [[ "$is_efi" == "true" ]]; then
            total_efi_size=$((total_efi_size + size))
        else
            total_other_size=$((total_other_size + size))
        fi
    done
    
    # Verifica che le partizioni EFI entrino
    if [[ $total_efi_size -gt $usable_target_size ]]; then
        print_error "EFI partitions ($(numfmt --to=iec --suffix=B $total_efi_size)) don't fit in target disk"
        exit 1
    fi
    
    local remaining_size=$((usable_target_size - total_efi_size))
    
    # Calcola dimensioni proporzionali
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
        
        if [[ "$is_efi" == "true" ]]; then
            target_sizes_ref+=("$size")
        else
            if [[ $total_other_size -eq 0 ]]; then
                target_sizes_ref+=("$size")
            else
                local new_size=$((size * remaining_size / total_other_size))
                # Allinea a 1MB
                new_size=$(((new_size / 1048576) * 1048576))
                # Assicurati che sia almeno 1MB
                [[ $new_size -lt 1048576 ]] && new_size=1048576
                target_sizes_ref+=("$new_size")
            fi
        fi
    done
}

# Function to show operation plan
show_plan() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    local -n target_sizes_ref=$4
    
    echo
    print_info "OPERATION PLAN:"
    print_warning "Target disk $target_disk will be completely wiped!"
    echo
    
    printf "%-15s %-12s %-12s %-6s -> %-12s %-10s\n" "SOURCE" "SIZE" "FS TYPE" "EFI" "NEW SIZE" "FS UUID"
    echo "--------------------------------------------------------------------------------"
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        local target_size="${target_sizes_ref[$i]}"
        
        printf "%-15s %-12s %-12s %-6s -> %-12s %-10s\n" \
            "$partition" \
            "$(numfmt --to=iec --suffix=B $size)" \
            "${fs_type:-unknown}" \
            "$is_efi" \
            "$(numfmt --to=iec --suffix=B $target_size)" \
            "${fs_uuid:0:8}..."
    done
    echo
}

# Function to create partition table with UUID preservation
create_partitions() {
    local target_disk="$1"
    local -n source_parts_ref=$2
    local -n target_sizes_ref=$3
    
    print_info "Creating GPT partition table on $target_disk"
    
    # Ottieni l'UUID del disco di origine dalla prima partizione
    local source_disk_uuid=""
    if [[ ${#source_parts_ref[@]} -gt 0 ]]; then
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[0]}"
        source_disk_uuid="$disk_uuid"
    fi
    
    if [[ "$DRY_RUN" == "false" ]]; then
        # Pulisci il disco
        wipefs -af "$target_disk" 2>/dev/null || true
        parted "$target_disk" --script mklabel gpt
        
        # Imposta l'UUID del disco se disponibile
        if [[ -n "$source_disk_uuid" ]]; then
            set_disk_uuid "$target_disk" "$source_disk_uuid"
        fi
    else
        echo "  Would run: wipefs -af $target_disk"
        echo "  Would run: parted $target_disk --script mklabel gpt"
        if [[ -n "$source_disk_uuid" ]]; then
            echo "  Would set disk UUID: $source_disk_uuid"
        fi
    fi
    
    # Usa settori invece di MiB per maggiore precisione
    local sector_size=512
    local start_sector=2048  # Inizia dal settore 2048 (1MiB)
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        local target_size="${target_sizes_ref[$i]}"
        local part_num=$((i+1))
        
        # Calcola la dimensione in settori
        local size_sectors=$((target_size / sector_size))

        # Per LUKS, assicurati che la partizione target sia almeno grande quanto la source
        if [[ "$fs_type" == "crypto_LUKS" ]]; then
            local source_sectors=$((size / sector_size))
            if [[ $size_sectors -lt $source_sectors ]]; then
                size_sectors=$source_sectors
                print_info "Adjusting LUKS partition size to match source: $size_sectors sectors"
            fi
        fi

        # Allinea ai confini di 1MiB (2048 settori) ma solo se non è LUKS
        if [[ "$fs_type" != "crypto_LUKS" ]]; then
            size_sectors=$(((size_sectors / 2048) * 2048))
        else
            # Per LUKS, arrotonda sempre per eccesso al prossimo confine 1MiB
            size_sectors=$(((size_sectors + 2047) / 2048 * 2048))
        fi
        
        local end_sector=$((start_sector + size_sectors - 1))
        
        print_info "Creating partition ${part_num} (sectors ${start_sector} to ${end_sector}, size: $(numfmt --to=iec --suffix=B $((size_sectors * sector_size))))"
        
        if [[ "$is_efi" == "true" ]]; then
            if [[ "$DRY_RUN" == "false" ]]; then
                parted "$target_disk" --script mkpart "EFI" fat32 "${start_sector}s" "${end_sector}s"
                parted "$target_disk" --script set $part_num esp on
            else
                echo "  Would run: parted $target_disk --script mkpart EFI fat32 ${start_sector}s ${end_sector}s"
                echo "  Would run: parted $target_disk --script set $part_num esp on"
            fi
        else
            local part_name="partition${part_num}"
            if [[ "$DRY_RUN" == "false" ]]; then
                parted "$target_disk" --script mkpart "$part_name" "${start_sector}s" "${end_sector}s"
            else
                echo "  Would run: parted $target_disk --script mkpart $part_name ${start_sector}s ${end_sector}s"
            fi
        fi
        
        # Aggiorna target_sizes_ref con la dimensione effettiva
        target_sizes_ref[$i]=$((size_sectors * sector_size))
        
        start_sector=$((end_sector + 1))
        # Allinea il prossimo start_sector a 1MiB se necessario
        local remainder=$((start_sector % 2048))
        if [[ $remainder -ne 0 ]]; then
            start_sector=$((start_sector + 2048 - remainder))
        fi
    done
    
    if [[ "$DRY_RUN" == "false" ]]; then
        partprobe "$target_disk"
        sleep 3
        
        # Verifica che le partizioni siano state create
        for i in "${!source_parts_ref[@]}"; do
            local target_partition="${target_disk}$((i+1))"
            local count=0
            while [[ ! -b "$target_partition" && $count -lt 10 ]]; do
                sleep 1
                count=$((count + 1))
                partprobe "$target_disk" 2>/dev/null || true
            done
            
            if [[ ! -b "$target_partition" ]]; then
                print_error "Failed to create partition $target_partition"
                exit 1
            fi
            
            # Imposta l'UUID della partizione se disponibile
            IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
            if [[ -n "$part_uuid" ]]; then
                set_partition_uuid "$target_disk" "$((i+1))" "$part_uuid"
            fi
            
            # Verifica la dimensione effettiva della partizione creata
            local actual_size=$(get_partition_size "$target_partition")
            print_info "Partition $target_partition created with size: $(numfmt --to=iec --suffix=B $actual_size)"
        done
        
        # Aggiorna la tabella delle partizioni dopo aver impostato gli UUID
        partprobe "$target_disk"
        sleep 2
    else
        echo "  Would run: partprobe $target_disk"
        for i in "${!source_parts_ref[@]}"; do
            IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
            if [[ -n "$part_uuid" ]]; then
                echo "  Would set partition UUID for partition $((i+1)): $part_uuid"
            fi
        done
    fi
}

# Function to clone partitions with UUID preservation
clone_partitions() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r source_partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        local target_partition="${target_disk}$((i+1))"
        
        print_info "Cloning $source_partition to $target_partition"
        print_info "Filesystem type: ${fs_type:-unknown}, EFI: $is_efi"
        print_info "FS UUID: ${fs_uuid:-none}"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  Would clone: $source_partition -> $target_partition"
            if [[ -n "$fs_uuid" ]]; then
                echo "  Would preserve FS UUID: $fs_uuid"
            fi
            continue
        fi
        
        # Verifica che entrambe le partizioni esistano
        if [[ ! -b "$source_partition" ]]; then
            print_error "Source partition $source_partition does not exist"
            continue
        fi
        
        if [[ ! -b "$target_partition" ]]; then
            print_error "Target partition $target_partition does not exist"
            continue
        fi
        
        # Ottieni le dimensioni effettive
        local source_size=$(get_partition_size "$source_partition")
        local target_size=$(get_partition_size "$target_partition")
        
        print_info "Source size: $(numfmt --to=iec --suffix=B $source_size)"
        print_info "Target size: $(numfmt --to=iec --suffix=B $target_size)"
        
        # Determina la dimensione da copiare (la più piccola tra le due)
        local copy_size=$source_size
        local size_diff=$((source_size - target_size))
        local tolerance=$((1024 * 1024))  # 1MB tolerance

        if [[ $size_diff -gt $tolerance ]]; then
            copy_size=$target_size
            print_warning "Target partition is significantly smaller, copying only $(numfmt --to=iec --suffix=B $copy_size)"
        elif [[ $target_size -lt $source_size ]]; then
            copy_size=$target_size
            print_info "Target partition slightly smaller due to alignment, copying $(numfmt --to=iec --suffix=B $copy_size)"
        fi
        
        # Calcola il numero di blocchi da copiare (usando blocchi da 1M)
        local block_size=1048576  # 1MB
        local blocks_to_copy=$((copy_size / block_size))
        
        case "$fs_type" in
            "vfat"|"fat32")
                print_info "Using dd for FAT filesystem (copying $blocks_to_copy blocks of 1MB)"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                        print_warning "dd with 1MB blocks failed, trying with 512KB"
                        local small_block_size=524288  # 512KB
                        local small_blocks_to_copy=$((copy_size / small_block_size))
                        dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                    }
                else
                    print_warning "Partition too small, copying sector by sector"
                    dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                fi
                # Imposta l'UUID FAT dopo la copia
                set_filesystem_uuid "$target_partition" "$fs_uuid" "$fs_type"
                ;;
            "ext2"|"ext3"|"ext4")
                print_info "Using e2image for ext filesystem"
                e2fsck -fy "$source_partition" 2>/dev/null || true
                e2image -ra -p "$source_partition" "$target_partition"
                if [[ $target_size -gt $source_size ]]; then
                    resize2fs "$target_partition" 2>/dev/null || true
                fi
                # L'UUID viene preservato automaticamente da e2image
                print_info "UUID preserved by e2image: $fs_uuid"
                ;;
            "ntfs")
                if command -v ntfsclone >/dev/null 2>&1; then
                    print_info "Using ntfsclone for NTFS filesystem"
                    ntfsclone -f --overwrite "$target_partition" "$source_partition"
                    if [[ $target_size -gt $source_size ]]; then
                        ntfsresize -f "$target_partition" 2>/dev/null || true
                    fi
                    # ntfsclone preserva automaticamente l'UUID
                    print_info "UUID preserved by ntfsclone: $fs_uuid"
                else
                    print_warning "ntfsclone not available, using dd with size limit"
                    if [[ $blocks_to_copy -gt 0 ]]; then
                        dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress
                    else
                        dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                    fi
                    print_warning "UUID may not be preserved with dd copy"
                fi
                ;;
            "crypto_LUKS")
                # Per LUKS, verifica che la partizione target sia almeno grande quanto la source
                local source_sectors=$((source_size / 512))
                local target_sectors=$((target_size / 512))
                
                if [[ $source_sectors -gt $target_sectors ]]; then
                    print_error "LUKS partition cannot be truncated: source has $source_sectors sectors, target has $target_sectors"
                    print_error "LUKS containers must be copied completely to avoid corruption"
                    exit 1
                fi
                
                print_info "Using dd with exact sector copy for LUKS container"
                local sectors_to_copy=$source_sectors
                
                # Copia settore per settore per massima precisione
                dd if="$source_partition" of="$target_partition" bs=512 count=$sectors_to_copy status=progress conv=noerror,sync
                
                # Verifica integrità LUKS dopo copia
                if command -v cryptsetup >/dev/null 2>&1; then
                    if cryptsetup luksDump "$target_partition" >/dev/null 2>&1; then
                        print_success "LUKS header verified successfully"
                    else
                        print_error "LUKS header verification failed - partition may be corrupted"
                    fi
                else
                    print_warning "cryptsetup not available - cannot verify LUKS integrity"
                fi
                
                # Per LUKS l'UUID è nel header, preservato con dd
                print_info "LUKS UUID preserved in header: $fs_uuid"
                ;;
            "swap")
                print_info "Creating new swap partition with preserved UUID"
                if [[ -n "$fs_uuid" ]]; then
                    mkswap -U "$fs_uuid" "$target_partition"
                    print_info "Swap UUID set to: $fs_uuid"
                else
                    mkswap "$target_partition"
                    print_info "New swap partition created"
                fi
                ;;
            "xfs")
                print_info "Using dd for XFS filesystem"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                        print_warning "dd with 1MB blocks failed, trying with 512KB"
                        local small_block_size=524288
                        local small_blocks_to_copy=$((copy_size / small_block_size))
                        dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                    }
                else
                    dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                fi
                # Per XFS, l'UUID dovrebbe essere preservato con dd, ma proviamo a impostarlo
                if [[ -n "$fs_uuid" ]]; then
                    set_filesystem_uuid "$target_partition" "$fs_uuid" "$fs_type"
                fi
                ;;
            "")
                print_warning "Unknown filesystem, attempting dd copy with size limit"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                        print_warning "dd with 1MB blocks failed, trying with 512KB"
                        local small_block_size=524288
                        local small_blocks_to_copy=$((copy_size / small_block_size))
                        dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                    }
                else
                    dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                fi
                ;;
            *)
                print_warning "Unsupported filesystem $fs_type, using dd with size limit"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                        print_warning "dd with 1MB blocks failed, trying with 512KB"
                        local small_block_size=524288
                        local small_blocks_to_copy=$((copy_size / small_block_size))
                        dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                    }
                else
                    dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                fi
                # Prova a impostare l'UUID se supportato
                if [[ -n "$fs_uuid" ]]; then
                    set_filesystem_uuid "$target_partition" "$fs_uuid" "$fs_type"
                fi
                ;;
        esac
        
        print_success "Successfully cloned $source_partition to $target_partition"
        
        # Verifica l'UUID dopo la copia
        local new_fs_uuid=$(get_filesystem_uuid "$target_partition")
        if [[ -n "$new_fs_uuid" && "$new_fs_uuid" == "$fs_uuid" ]]; then
            print_success "UUID correctly preserved: $new_fs_uuid"
        elif [[ -n "$new_fs_uuid" ]]; then
            print_warning "UUID changed: $fs_uuid -> $new_fs_uuid"
        else
            print_warning "No UUID found on target partition"
        fi
    done
}

# Function to verify cloning results with UUID check
verify_clone() {
    local target_disk="$1"
    local -n source_parts_ref=$2
    
    print_info "Verifying clone results..."
    
    echo
    printf "%-15s %-12s %-12s %-36s %-36s\n" "PARTITION" "SIZE" "FS TYPE" "ORIGINAL UUID" "NEW UUID"
    echo "---------------------------------------------------------------------------------------------------"
    
    local uuid_mismatch=false
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r source_partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        local target_partition="${target_disk}$((i+1))"
        
        if [[ ! -b "$target_partition" ]]; then
            print_error "Target partition $target_partition not found"
            continue
        fi
        
        local target_size=$(get_partition_size "$target_partition")
        local new_fs_uuid=$(get_filesystem_uuid "$target_partition")
        local new_part_uuid=$(get_partition_uuid "$target_partition")
        
        printf "%-15s %-12s %-12s %-36s %-36s\n" \
            "$target_partition" \
            "$(numfmt --to=iec --suffix=B $target_size)" \
            "${fs_type:-unknown}" \
            "${fs_uuid:-none}" \
            "${new_fs_uuid:-none}"
        
        # Verifica filesystem per partizioni non criptate
        if [[ "$fs_type" != "crypto_LUKS" && "$fs_type" != "" ]]; then
            local new_fs_type=$(get_partition_type "$target_partition")
            if [[ -n "$new_fs_type" ]]; then
                print_info "  Filesystem detected: $new_fs_type"
            else
                print_warning "  No filesystem detected on $target_partition"
            fi
        fi
        
        # Controlla gli UUID
        if [[ -n "$fs_uuid" && "$fs_uuid" != "$new_fs_uuid" ]]; then
            uuid_mismatch=true
            print_warning "  Filesystem UUID mismatch!"
        fi
        
        if [[ -n "$part_uuid" && "$part_uuid" != "$new_part_uuid" ]]; then
            print_warning "  Partition UUID mismatch: $part_uuid -> $new_part_uuid"
        fi
    done
    
    echo
    
    # Verifica UUID del disco
    local new_disk_uuid=$(get_disk_uuid "$target_disk")
    local source_disk_uuid=""
    if [[ ${#source_parts_ref[@]} -gt 0 ]]; then
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[0]}"
        source_disk_uuid="$disk_uuid"
    fi
    
    if [[ -n "$source_disk_uuid" ]]; then
        if [[ "$source_disk_uuid" == "$new_disk_uuid" ]]; then
            print_success "Disk UUID preserved: $new_disk_uuid"
        else
            print_warning "Disk UUID changed: $source_disk_uuid -> $new_disk_uuid"
        fi
    fi
    
    if [[ "$uuid_mismatch" == "true" ]]; then
        echo
        print_warning "Some filesystem UUIDs could not be preserved!"
        print_info "You may need to update /etc/fstab and bootloader configuration"
        print_info "Consider running: blkid to see all current UUIDs"
    else
        print_success "All UUIDs successfully preserved!"
    fi
}

# Function to show UUID preservation tips
show_uuid_tips() {
    echo
    print_info "UUID PRESERVATION NOTES:"
    echo "• ext2/3/4: UUIDs preserved automatically by e2image"
    echo "• NTFS: UUIDs preserved automatically by ntfsclone (if available)"
    echo "• FAT32/VFAT: UUID preservation requires mtools (install with: apt-get install mtools)"
    echo "• LUKS: UUIDs preserved in encrypted header"
    echo "• XFS: UUIDs preserved by dd copy and xfs_admin"
    echo "• SWAP: New swap created with original UUID"
    echo
    print_warning "After cloning, you may need to:"
    echo "1. Update /etc/fstab if filesystem UUIDs changed"
    echo "2. Update bootloader configuration (GRUB) if boot partition UUID changed"
    echo "3. Update /etc/crypttab for LUKS partitions"
    echo
    print_info "To check current UUIDs: blkid"
    print_info "To update GRUB: update-grub (on Ubuntu/Debian)"
}

# Main function
main() {
    print_info "Disk Cloner with Proportional Resize and UUID Preservation"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        check_root
    fi
    
    show_uuid_tips
    
    # Select source disk
    echo
    list_disks
    echo
    local source_disk=$(select_disk "Enter source disk (e.g., /dev/sda)")
    
    # Show source disk details
    echo
    print_info "Selected source disk details:"
    lsblk "$source_disk"
    
    # Select target disk
    while true; do
        echo
        list_disks
        echo
        local target_disk=$(select_disk "Enter target disk (e.g., /dev/sdb)")
        
        if [[ "$source_disk" == "$target_disk" ]]; then
            print_error "Source and target disks cannot be the same"
            continue
        fi
        
        echo
        print_info "Selected target disk details:"
        lsblk "$target_disk"
        
        break
    done
    
    # Get partitions info with UUIDs
    local source_partitions=()
    if ! get_partitions_info "$source_disk" source_partitions; then
        print_error "Failed to get partition information from $source_disk"
        exit 1
    fi
    
    print_info "Found ${#source_partitions[@]} partitions on source disk"
    
    # Calculate target sizes
    local target_sizes=()
    calculate_proportional_sizes "$source_disk" "$target_disk" source_partitions target_sizes
    
    # Show plan
    show_plan "$source_disk" "$target_disk" source_partitions target_sizes
    
    # Confirm operation
    if [[ "$DRY_RUN" == "false" ]]; then
        echo -n "Are you sure you want to proceed? This will DESTROY all data on $target_disk [yes/NO]: "
        read -r confirm
        
        if [[ "$confirm" != "yes" ]]; then
            print_info "Operation cancelled"
            exit 0
        fi
    fi
    
    # Create partitions with UUID preservation
    create_partitions "$target_disk" source_partitions target_sizes
    
    # Clone partitions with UUID preservation
    clone_partitions "$source_disk" "$target_disk" source_partitions
    
    # Verify results with UUID check
    if [[ "$DRY_RUN" == "false" ]]; then
        verify_clone "$target_disk" source_partitions
        print_success "Disk cloning completed successfully!"
        echo
        print_info "Final partition layout:"
        lsblk "$target_disk"
    else
        print_success "Dry run completed! No actual changes were made."
    fi
}

# Check dependencies including UUID tools
check_dependencies() {
    local missing_deps=()
    local optional_deps=()
    
    command -v lsblk >/dev/null || missing_deps+=("util-linux")
    command -v parted >/dev/null || missing_deps+=("parted")
    command -v blockdev >/dev/null || missing_deps+=("util-linux")
    command -v wipefs >/dev/null || missing_deps+=("util-linux")
    command -v partprobe >/dev/null || missing_deps+=("parted")
    command -v e2image >/dev/null || missing_deps+=("e2fsprogs")
    command -v resize2fs >/dev/null || missing_deps+=("e2fsprogs")
    command -v e2fsck >/dev/null || missing_deps+=("e2fsprogs")
    command -v tune2fs >/dev/null || missing_deps+=("e2fsprogs")
    command -v mkswap >/dev/null || missing_deps+=("util-linux")
    command -v blkid >/dev/null || missing_deps+=("util-linux")
    
    # UUID-related tools
    if ! command -v sgdisk >/dev/null; then
        optional_deps+=("gdisk (for partition UUID preservation)")
    fi
    
    if ! command -v fatlabel >/dev/null; then
        optional_deps+=("dosfstools (for FAT filesystem tools)")
    fi
    
    if ! command -v mlabel >/dev/null; then
        optional_deps+=("mtools (for FAT UUID preservation)")
    fi
    
    if ! command -v xfs_admin >/dev/null; then
        optional_deps+=("xfsprogs (for XFS UUID tools)")
    fi
    
    # Optional dependencies (warn but don't fail)
    if ! command -v ntfsclone >/dev/null; then
        optional_deps+=("ntfs-3g (for NTFS cloning with UUID preservation)")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        print_info "Install with: apt-get install ${missing_deps[*]}"
        exit 1
    fi
    
    if [[ ${#optional_deps[@]} -gt 0 ]]; then
        print_warning "Optional tools not found (UUID preservation may be limited):"
        for dep in "${optional_deps[@]}"; do
            echo "  - $dep"
        done
        echo
        print_info "Install with: apt-get install gdisk dosfstools mtools xfsprogs ntfs-3g"
        echo
    fi
}

# Run the script
check_dependencies
main "$@"