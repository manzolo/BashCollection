# VM Management Scripts

Comprehensive collection of tools for managing QEMU/KVM virtual machines and disk images.

## Table of Contents

- [vm-disk-manager](#vm-disk-manager) - Advanced disk image operations
- [vm-create-disk](#vm-create-disk) - Create new virtual disks
- [vm-clone](#vm-clone) - Clone VM images
- [vm-iso-manager](#vm-iso-manager) - ISO editing and building
- [vm-helper](#vm-helper) - VM utility functions
- [vm-try](#vm-try) - Quick VM testing

---

## vm-disk-manager

**Comprehensive virtual disk management tool with interactive TUI interface**

The most powerful tool in this collection for managing QEMU/KVM virtual disk images with an advanced text-based interface.

### Features

- **Disk Operations**
  - Create, resize, and convert virtual disk images
  - Format conversion (qcow2 ↔ raw ↔ vdi ↔ vmdk)
  - Disk image optimization and compression
  - Snapshot management and operations

- **Advanced Access**
  - NBD (Network Block Device) mounting for direct filesystem access
  - Interactive file browser for image contents
  - Mount and explore filesystems without booting the VM

- **Partition Management**
  - View and manage partitions
  - GParted integration for graphical partition editing
  - Resize partitions and filesystems
  - Support for MBR and GPT partition tables

- **Encryption & LVM**
  - LUKS encryption support
  - LVM volume management
  - Encrypted partition handling

- **VM Testing**
  - Test disk images with QEMU
  - UEFI and BIOS boot support
  - Enhanced UEFI with persistent NVRAM storage
  - Cross-distribution OVMF firmware detection

### Usage

```bash
sudo vm-disk-manager
```

The script will:
1. Check and install dependencies
2. Present a file browser to select a disk image
3. Show the main menu with available operations

### Screenshots

**Main Menu and File Browser:**

<img width="1416" height="664" alt="Main menu interface" src="https://github.com/user-attachments/assets/8045a3e3-ed5b-4653-9cd8-21b568b7c004" />

**Disk Information and Operations:**

<img width="1416" height="664" alt="Disk operations menu" src="https://github.com/user-attachments/assets/69550569-ef86-49b6-8c88-920756369d4e" />

**NBD Mounting and File Access:**

<img width="1416" height="664" alt="NBD mounting interface" src="https://github.com/user-attachments/assets/a4d15e67-9aa5-40e0-b684-6ee131013765" />

**Partition Management:**

<img width="1416" height="664" alt="Partition management" src="https://github.com/user-attachments/assets/c056f891-ca43-4c91-b4d1-8b7f36e1acec" />

**GParted Integration:**

<img width="1416" height="664" alt="GParted integration" src="https://github.com/user-attachments/assets/dc4179d5-6586-4ef1-a5d4-73830aa4501e" />

**Format Conversion:**

<img width="1416" height="664" alt="Format conversion" src="https://github.com/user-attachments/assets/d5dab6e9-e16e-4dd8-ad6b-6ec632a83f2f" />

**Snapshot Management:**

<img width="1416" height="664" alt="Snapshot operations" src="https://github.com/user-attachments/assets/5c94ccf8-75b5-4c4f-911c-2e684c92e1c9" />

**Disk Optimization:**

<img width="1416" height="664" alt="Disk optimization" src="https://github.com/user-attachments/assets/b4806afb-3ff7-46cf-8c26-5fc4e3ad7d47" />

**File Browser in Mounted Image:**

<img width="1416" height="664" alt="File browser" src="https://github.com/user-attachments/assets/3e15eba3-4647-4a3a-aa06-8d9bda53bdda" />

**LUKS Encryption Support:**

<img width="1416" height="664" alt="LUKS support" src="https://github.com/user-attachments/assets/a7c1d292-8f05-4b1b-8938-5f7d6d296000" />

**LVM Management:**

<img width="1416" height="664" alt="LVM management" src="https://github.com/user-attachments/assets/cb1a1387-1ab3-43ad-8175-0d80465f2491" />

**QEMU Testing - UEFI Boot:**

<img width="1416" height="664" alt="UEFI boot testing" src="https://github.com/user-attachments/assets/d7bcb3c6-1669-4c1f-b565-bc9928e0093d" />

**QEMU Testing - BIOS Boot:**

<img width="1416" height="664" alt="BIOS boot testing" src="https://github.com/user-attachments/assets/bb6eba42-5a02-4ad8-83c9-1faf9ff35f5a" />

**Resize Operations:**

<img width="1416" height="664" alt="Resize operations" src="https://github.com/user-attachments/assets/2cc2350b-aa79-4509-9523-271e3151376f" />

**Advanced Options:**

<img width="1416" height="664" alt="Advanced options" src="https://github.com/user-attachments/assets/256066bd-1279-4000-bfcb-93dda4352d4b" />

**Compression Settings:**

<img width="1416" height="664" alt="Compression settings" src="https://github.com/user-attachments/assets/e4eb3405-f0b2-44d7-af10-d62ea2e2ee85" />

**Filesystem Operations:**

<img width="1416" height="664" alt="Filesystem operations" src="https://github.com/user-attachments/assets/4ee42089-3ad1-480e-bdc3-4e4383540c68" />

**Disk Analysis:**

<img width="1416" height="664" alt="Disk analysis" src="https://github.com/user-attachments/assets/4907e8d1-00e8-4bfc-8915-41cb4f448d08" />

**Status and Progress:**

<img width="1416" height="664" alt="Status display" src="https://github.com/user-attachments/assets/890b5d8b-30e3-4d8f-9046-2f1e6f82d63e" />

**Cleanup Operations:**

<img width="1416" height="664" alt="Cleanup operations" src="https://github.com/user-attachments/assets/5901b872-6eaf-4254-8bb5-b102c865d103" />

**Error Handling:**

<img width="1416" height="664" alt="Error handling" src="https://github.com/user-attachments/assets/e139bd18-8e65-4cd1-9176-174b8e396ea9" />

**Success Messages:**

<img width="1416" height="664" alt="Success confirmation" src="https://github.com/user-attachments/assets/102b31ec-6eae-42ab-afaf-347a4be6cf50" />

**Final Menu:**

<img width="1416" height="664" alt="Final menu" src="https://github.com/user-attachments/assets/c4e7d798-a43c-45b8-a8d4-436ac63445fd" />

### Requirements

**Required:**
- bash >= 4.0
- qemu-utils (qemu-img, qemu-nbd)
- whiptail (TUI interface)
- Root privileges

**Recommended:**
- qemu-system-x86 (for VM testing)
- gparted (graphical partition editor)
- libguestfs-tools (advanced filesystem operations)
- cryptsetup (LUKS support)
- lvm2 (LVM support)

### Installation of Dependencies

```bash
# Ubuntu/Debian
sudo apt install qemu-utils whiptail qemu-system-x86 gparted libguestfs-tools cryptsetup lvm2

# Fedora/RHEL
sudo dnf install qemu-img whiptail qemu-system-x86 gparted libguestfs-tools cryptsetup lvm2
```

### Modular Architecture

The script uses a modular design with helper modules in `vm-disk-manager/`:
- File browser and selection
- NBD device management
- Partition operations
- Mount/unmount operations
- LUKS and LVM handling
- QEMU testing functions
- Cleanup and error handling

### Safety Features

- Automatic cleanup on exit
- Proper unmounting in reverse order
- NBD device management
- LUKS/LVM cleanup
- Backup prompts before destructive operations
- Detailed logging to `/tmp/vm_image_manager_log_*.txt`

---

## vm-create-disk

**Interactive virtual disk creation wizard**

User-friendly tool for creating QEMU virtual disk images with guided configuration.

### Screenshot

<img width="1713" height="906" alt="VM Create Disk interface" src="https://github.com/user-attachments/assets/bac31c61-e0ad-4968-b04a-fb9fc2605167" />

### Features

- Multiple format support (qcow2, raw, vdi, vmdk)
- MBR and GPT partition table support
- Automatic partition creation and formatting
- Interactive and batch modes
- NBD mounting for direct access
- Filesystem creation (ext4, btrfs, xfs, NTFS, FAT32)
- Preallocation options for performance
- Guided wizard interface

### Usage

```bash
# Interactive mode
vm-create-disk

# Batch mode (example)
vm-create-disk --name mydisk.qcow2 --size 20G --format qcow2 --partitions "ext4:10G,swap:2G"
```

### Wizard Steps

1. **Disk Configuration**
   - Name and location
   - Size specification
   - Format selection

2. **Partition Setup**
   - Partition table type (MBR/GPT)
   - Number of partitions
   - Size allocation

3. **Filesystem Creation**
   - Filesystem type per partition
   - Labels and options
   - Format and finalize

### Supported Filesystems

- ext2, ext3, ext4
- btrfs
- xfs
- NTFS
- FAT32/VFAT
- swap

### Requirements

- qemu-utils
- Root privileges
- parted (partition management)

---

## vm-clone

**Clone and test QEMU virtual machines**

Tool for cloning virtual machines and testing with different boot media.

### Features

- Clone between different disk formats
- MBR and UEFI boot mode support
- Bootable ISO integration for cloning
- KVM hardware acceleration
- Support for multiple disk formats (qcow2, raw, vmdk, vdi, vhd)
- Configurable RAM and CPU allocation
- Three-disk support (source, destination, extra)

### Usage

```bash
# Basic cloning with Clonezilla
vm-clone --src source.qcow2 --dst target.qcow2 --iso clonezilla.iso

# UEFI mode with more RAM
vm-clone --src disk1.raw --dst disk2.raw --iso systemrescue.iso --uefi --ram 8G

# With extra disk
vm-clone --src old.vmdk --dst new.vmdk --extra backup.qcow2 --iso clonezilla.iso
```

### Parameters

**Required:**
- `--src <path>`: Source virtual disk to clone
- `--dst <path>`: Destination virtual disk
- `--iso <path>`: Bootable ISO (Clonezilla, SystemRescue, etc.)

**Optional:**
- `--extra <path>`: Additional third disk
- `--mbr`: Configure for MBR/BIOS boot (default)
- `--uefi`: Configure for UEFI boot
- `--ram <size>`: VM RAM (default: 4G)
- `--cpus <number>`: Virtual CPUs (default: all cores)
- `--verbose`: Show detailed disk format information

### Recommended ISOs for Cloning

- **Clonezilla Live**: Popular disk cloning tool
- **SystemRescue**: System rescue and cloning
- **GParted Live**: Partition management
- Any other bootable cloning ISO

### Requirements

- qemu-system-x86
- qemu-utils (qemu-img)
- KVM support (optional, for acceleration)

---

## vm-iso-manager

**Interactive ISO image editor and builder**

Tool for editing and building bootable ISO images with UEFI and BIOS support.

### Features

- Extract and modify ISO contents
- Rebuild bootable ISOs
- Interactive file browser for ISO contents
- UEFI and BIOS boot support preservation
- Custom kernel and initrd support
- Squashfs filesystem handling
- Ubuntu/Debian ISO support
- Windows ISO support

### Usage

```bash
sudo vm-iso-manager
```

The script will:
1. Present a file browser to select an ISO
2. Extract the ISO contents
3. Detect boot type (UEFI/BIOS)
4. Allow modifications
5. Rebuild the bootable ISO

### Supported ISO Types

- Ubuntu/Debian (GRUB2 boot)
- Windows (Boot Manager)
- Generic ISOLINUX/SYSLINUX
- UEFI boot images
- Hybrid BIOS/UEFI ISOs

### Requirements

- whiptail (TUI interface)
- xorriso (ISO creation)
- squashfs-tools (filesystem handling)
- genisoimage (recommended)
- isolinux (recommended)
- Root privileges

### Use Cases

- Customize Ubuntu installer ISOs
- Add drivers to rescue ISOs
- Modify boot parameters
- Create custom live systems
- Inject files into bootable media

---

## vm-helper

**VM utility functions**

Helper script providing common VM-related functions used by other scripts in the collection.

### Features

- Disk format detection
- Size calculations
- Path validation
- Common VM operations
- Shared utility functions

### Usage

This script is sourced by other VM management tools and not typically run directly.

---

## vm-try

**Quick VM testing tool**

Launch virtual machines quickly for testing purposes with minimal configuration.

### Features

- Rapid VM launching
- Multiple disk support
- ISO boot support
- UEFI/BIOS mode selection
- Configurable resources
- Testing-oriented defaults

### Usage

```bash
vm-try <disk_image> [options]
```

### Common Options

- `--iso <path>`: Boot from ISO
- `--uefi`: Use UEFI boot
- `--ram <size>`: Set RAM amount
- `--snapshot`: Run without modifying disk

---

## General Requirements

All VM management scripts require:

**Base Requirements:**
- Bash 4+
- Root/sudo access (for most operations)
- qemu-utils package

**Recommended Packages:**
```bash
sudo apt install qemu-system-x86 qemu-utils whiptail gparted \
                 libguestfs-tools cryptsetup lvm2 parted \
                 xorriso squashfs-tools
```

## Tips and Best Practices

1. **Always backup** your VM images before performing operations
2. **Use snapshots** when testing potentially destructive operations
3. **NBD mounting** provides direct access without booting the VM
4. **GParted integration** offers a graphical way to resize partitions
5. **LUKS support** allows working with encrypted VM disks
6. **Format conversion** can optimize storage (e.g., raw → qcow2 for compression)
7. **Check logs** in /tmp/ if operations fail

## Troubleshooting

**NBD Device Busy:**
- Ensure previous mounts are cleaned up
- Check `lsblk` for active NBD devices
- Run cleanup: `qemu-nbd --disconnect /dev/nbd0`

**UEFI Boot Fails:**
- Install OVMF: `sudo apt install ovmf`
- Check firmware path detection

**Permission Denied:**
- Run with sudo
- Check file permissions on disk images

**GParted Won't Launch:**
- Install: `sudo apt install gparted`
- Ensure X11 forwarding if SSH

## Architecture

Most scripts follow the modular pattern:
```
vm/
├── vm-disk-manager.sh          # Main script
└── vm-disk-manager/            # Helper modules
    ├── core.sh
    ├── nbd.sh
    ├── partition.sh
    ├── ui.sh
    └── ...
```

This allows for maintainable code and easy extension.
