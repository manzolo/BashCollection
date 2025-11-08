# QEMU and Windows Disk Management Reference

## Disk Image Conversion with qemu-img

### Basic Conversions

#### VHD to RAW
```bash
qemu-img convert -p -O raw Windows11.vhd Windows11.raw
```

#### QCOW2 to VHD (Fixed)
```bash
qemu-img convert -f qcow2 -O vpc -o subformat=fixed ubuntu.qcow2 /media/manzolo/Ventoy/BOOTIMG/ubuntu.vhd
```

#### RAW to VHD (Fixed)
```bash
# Basic conversion
qemu-img convert -f raw -O vpc -o subformat=fixed Windows.raw /media/manzolo/Ventoy/BOOTIMG/Windows.vhd

# With force_size option (useful for compatibility)
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size Windows.vhd /media/manzolo/Ventoy/BOOTIMG/Windows.vhd
```

### Disk Information
```bash
qemu-img info -f vpc Windows.vhd
```

## Partition Table Management

### Convert MBR to GPT using NBD
```bash
# Load NBD module
sudo modprobe nbd max_part=8

# Connect VHD to NBD device
sudo qemu-nbd -f vpc --connect=/dev/nbd0 Windows.vhd

# Convert to GPT
sudo sgdisk --zap-all /dev/nbd0
sudo sgdisk --mbrtogpt /dev/nbd0

# Disconnect
sudo qemu-nbd --disconnect /dev/nbd0
```

### Convert MBR to GPT (Windows Method)
```bash
mbr2gpt /validate /disk:0 /allowFullOS
```

## VM Management Commands

### Boot with WinPE
```bash
# UEFI mode
vm_try --hd /media/manzolo/Ventoy/BOOTIMG/Windows.vhd --iso /home/manzolo/Workspaces/qemu/storage/Iso/WinPE.iso --uefi

# Legacy mode
vm_try --hd /media/manzolo/Ventoy/BOOTIMG/Windows.vhd --iso /home/manzolo/Workspaces/qemu/storage/Iso/WinPE.iso
```

### Windows 11 Recovery/Installation
```bash
# Legacy mode
vm_try --hd /media/manzolo/Ventoy/BOOTIMG/Windows.vhd --iso /home/manzolo/Workspaces/qemu/storage/Iso/Windows11.iso

# UEFI mode
vm_try --hd /media/manzolo/Ventoy/BOOTIMG/Windows.vhd --iso /home/manzolo/Workspaces/qemu/storage/Iso/Windows11.iso --uefi
```

### Disk Cloning with WinPE
```bash
# Legacy mode
vm_clone --iso ~/Workspaces/qemu/storage/Iso/WinPE.iso --src /media/manzolo/Dati/vm/Machines/Ventoy/Windows11_ventoy/Windows.vhd --dst /media/manzolo/Ventoy/BOOTIMG/Windows.vhd

# UEFI mode
vm_clone --iso ~/Workspaces/qemu/storage/Iso/WinPE.iso --src /media/manzolo/Dati/vm/Machines/Ventoy/Windows11_ventoy/Windows.vhd --dst /media/manzolo/Ventoy/BOOTIMG/Windows.vhd --uefi
```

## Windows Boot Repair

### UEFI Boot Repair

#### Partition Setup
```cmd
diskpart
sel disk 0

# EFI System Partition (ESP) - FAT32
sel part 1
format quick fs=fat32
assign letter=s

# Windows Partition
sel part 3
assign letter=c
exit
```

#### Boot Configuration
```cmd
# Rebuild UEFI boot configuration
bcdboot c:\Windows /s S: /f UEFI
```

#### Manual EFI Partition Creation
```cmd
diskpart
sel disk 0

# Create EFI partition (100MB)
create partition EFI size=100 offset=1
format quick fs=fat32 label="System"
assign letter=S

# Create MSR partition (128MB)
create partition msr size=128 offset=103424
exit
```

### MBR/Legacy Boot Repair

#### Standard Boot Repair Commands
```cmd
bootrec /fixmbr
bootrec /fixboot
bootrec /scanos
bootrec /rebuildbcd
```

#### Alternative Method (if bootrec /fixboot fails with "access denied")
```cmd
diskpart
sel disk 0

# System partition - FAT32
sel part 1
format quick fs=fat32
assign letter=s

# Windows partition
sel part 3
assign letter=c
exit

# Rebuild boot configuration for all firmware types
bcdboot C:\Windows /s S: /f ALL
```

## Tips and Troubleshooting

### Common Issues
- **bootrec /fixboot access denied**: Use the alternative bcdboot method shown above
- **VHD compatibility**: Use `subformat=fixed,force_size` options for better compatibility with different virtualization platforms
- **Partition alignment**: When creating partitions manually, ensure proper offset alignment for optimal performance

### Best Practices
- Always backup disk images before performing conversions or repairs
- Use progress indicator (`-p`) with qemu-img for long operations
- Verify disk integrity with `qemu-img info` after conversions
- Test boot functionality in both UEFI and Legacy modes when applicable