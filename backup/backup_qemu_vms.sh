#!/bin/bash

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root."
    exit 1
fi

# Check if a backup directory is provided as a parameter
if [ -z "$1" ]; then
    echo "Usage: $0 <backup_directory>"
    exit 1
fi

#Example
#BACKUP_DIR="/media/manzolo/GoogleBackup/qemu/storage"
BACKUP_DIR="$1"
XML_DIR="$BACKUP_DIR/xml"
VHD_DIR="$BACKUP_DIR/hd"

# Create backup directories if they don't exist
mkdir -p "$XML_DIR"
mkdir -p "$VHD_DIR"

# Arrays to keep track of copied files
src_files=()
dst_files=()

# Get the list of all VMs
VMS=$(virsh list --all | awk 'NR>2 && $2 != "-" {print $2}')

# Loop through each VM
for vm in $VMS; do
    echo "Backing up $vm..."
    
    # Check if VM is running, and if so, shut it down
    vm_state=$(virsh domstate "$vm")
    if [ "$vm_state" == "running" ]; then
        echo "VM $vm is running. Shutting it down..."
        virsh shutdown "$vm" --graceful --timeout 120 &>/dev/null
    fi
    
    # Wait for the VM to be powered off
    while [ "$(virsh domstate "$vm")" == "running" ]; do
        sleep 5
    done
    echo "VM $vm is powered off."

    # Dump the VM XML configuration
    if ! virsh dumpxml "$vm" > "$XML_DIR/$vm.xml"; then
        echo "Error: Failed to dump XML for $vm. Skipping this VM."
        continue
    fi

    # Loop through the VM's virtual hard disks
    while read -r vm_disk_path; do
        if [ -z "$vm_disk_path" ]; then
            continue
        fi

        echo "Disk: $vm_disk_path"
        if [ -f "$vm_disk_path" ]; then
            if ! cp "$vm_disk_path" "$VHD_DIR"; then
                echo "Error: Failed to copy $vm_disk_path. Skipping."
                continue
            fi
            src_files+=("$vm_disk_path")
            dst_files+=("$VHD_DIR/$(basename "$vm_disk_path")")
        else
            echo "File or directory $vm_disk_path not found. Skipping..."
        fi
    done < <(virsh domblklist "$vm" | awk 'NR>2 {print $2}')
    
    # Optional: Start the VM again after backup
    # echo "Starting VM $vm..."
    # virsh start "$vm" &>/dev/null
done

---

## Integrity Check

The script now includes an integrity check using MD5 checksums to verify that the copied files are identical to the originals.



```bash
# MD5 checksum verification
echo "Starting MD5 checksum verification..."
for ((i=0; i<${#src_files[@]}; i++)); do
    echo "Verifying ${src_files[$i]}..."
    src_md5=$(md5sum "${src_files[$i]}" | awk '{print $1}')
    dst_md5=$(md5sum "${dst_files[$i]}" | awk '{print $1}')
    
    if [ "$src_md5" == "$dst_md5" ]; then
        echo "Checksum MD5 for ${src_files[$i]} and ${dst_files[$i]} match. ✅"
    else
        echo "Checksum MD5 for ${src_files[$i]} and ${dst_files[$i]} do not match. ❌"
    fi
done

echo "Backup and verification process completed."
