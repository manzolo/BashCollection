# Manzolo Chroot

Advanced interactive chroot tool for accessing and working inside physical disks and virtual disk images.

## Overview

**manzolo-chroot** (command: `mchroot`) is a powerful chroot utility that allows you to enter and work inside Linux installations on both physical disks and virtual disk images. It handles all the complex setup automatically, including NBD mounting for virtual disks, LUKS encryption, LVM volumes, and proper bind mounting of system directories.

## Features

### Disk Support
- **Physical Disks**: Chroot into physical disks and partitions (/dev/sda, /dev/nvme0n1, etc.)
- **Virtual Disk Images**: Support for qcow2, vdi, vmdk, and raw image formats
- **Automatic NBD Mapping**: Virtual disk images are automatically mapped via Network Block Device

### Advanced Storage
- **LUKS Encryption**: Automatic detection and unlocking of encrypted partitions
- **LVM Support**: Automatic activation and management of LVM volumes
- **Multiple Partitions**: Support for separate /boot, /boot/efi, and / partitions
- **GPT and MBR**: Works with both partition table types

### Chroot Environment
- **Automatic Bind Mounting**: Properly mounts /dev, /proc, /sys, /dev/pts
- **GUI/X11 Support**: Run graphical applications from chroot with X11 forwarding
- **Custom Shell Selection**: Choose bash, zsh, or other shells
- **User Selection**: Chroot as root or any specific user
- **Environment Preservation**: Optional environment variable preservation

### User Experience
- **Interactive Dialog Interface**: User-friendly TUI with dialog
- **Quiet Mode**: Non-interactive mode for scripting
- **Configuration Files**: Save frequently used configurations
- **Automatic Cleanup**: Proper unmounting and cleanup on exit
- **Debug Mode**: Detailed logging for troubleshooting

## Usage

### Basic Usage

```bash
# Interactive mode (recommended)
sudo manzolo-chroot
# Or using the mapped alias:
sudo mchroot
```

The interactive mode will guide you through:
1. Selecting disk type (physical or virtual)
2. Choosing the disk/image
3. Selecting the root partition
4. Optional boot/EFI partition selection
5. GUI support configuration
6. Entering the chroot environment

### Command Line Options

```bash
# Use a virtual disk image directly
sudo mchroot -v /path/to/disk.qcow2

# Use a configuration file
sudo mchroot -c /path/to/config.conf

# Quiet mode (no dialog)
sudo mchroot -q

# Debug mode
sudo mchroot -d

# Show help
mchroot --help
```

### Common Use Cases

**Rescue a broken system:**
```bash
# Boot from live USB, then chroot into your system
sudo mchroot
# Select your root partition
# Fix your system from inside
```

**Work on a VM disk without booting the VM:**
```bash
sudo mchroot -v /var/lib/libvirt/images/myvm.qcow2
# Make changes to the VM filesystem
# Install packages, edit configs, etc.
```

**Access encrypted system:**
```bash
sudo mchroot
# Select your encrypted partition
# Enter LUKS passphrase when prompted
# Work inside the encrypted system
```

**Run GUI applications from chroot:**
```bash
sudo mchroot
# Enable GUI support when prompted
# Inside chroot: firefox, gparted, etc.
```

## Screenshots

### Main Menu - Disk Type Selection

<img width="762" height="675" alt="Disk type selection menu" src="https://github.com/user-attachments/assets/56798454-85d1-4c34-a9a2-ef6804d88fbd" />

### File Browser - Virtual Disk Selection

<img width="768" height="439" alt="Virtual disk file browser" src="https://github.com/user-attachments/assets/275dc13b-f6fd-4d01-9958-685b68db1577" />

### Partition Selection

<img width="923" height="530" alt="Root partition selection" src="https://github.com/user-attachments/assets/78bc91b9-7b5c-4ae0-ab95-393eb3217038" />

### Boot Partition Selection

<img width="923" height="530" alt="Boot partition selection" src="https://github.com/user-attachments/assets/fce5c910-a081-4c28-87aa-ffe133b88fc9" />

### EFI Partition Selection

<img width="923" height="530" alt="EFI partition selection" src="https://github.com/user-attachments/assets/512ff885-3dc7-4e1f-8535-37a5dcbaad2b" />

### Additional Mount Points

<img width="923" height="530" alt="Additional mount configuration" src="https://github.com/user-attachments/assets/a307c1e5-97dd-4394-8168-a2bd83dc9368" />

### GUI Support Configuration

<img width="923" height="530" alt="GUI support enable" src="https://github.com/user-attachments/assets/7a20c75b-77fa-40fc-8248-9ca2bcd10a30" />

### User Selection

<img width="923" height="530" alt="User selection for chroot" src="https://github.com/user-attachments/assets/4a50c7bc-6738-47a9-b43c-1671adad3fc4" />

### NBD Device Mounting

<img width="923" height="530" alt="NBD device mapping" src="https://github.com/user-attachments/assets/418a6c33-7d51-4a6a-9426-de3330877caa" />

### LUKS Partition Handling

<img width="923" height="530" alt="LUKS encrypted partition" src="https://github.com/user-attachments/assets/9f0ce6d9-b80e-4ab2-85a5-03a8a2762d15" />

### LVM Volume Detection

<img width="923" height="530" alt="LVM volume activation" src="https://github.com/user-attachments/assets/b38d7365-7153-4dec-b0d9-2e919f1124d6" />

### Successful Chroot Entry

<img width="923" height="530" alt="Inside chroot environment" src="https://github.com/user-attachments/assets/51517bc1-bfd0-4965-9c50-d537b46b60c0" />

## Requirements

### Required
- bash >= 4.0
- dialog (interactive TUI)
- qemu-utils (qemu-nbd for virtual disk support)
- util-linux (mount, umount, etc.)
- Root/sudo privileges

### Recommended
- cryptsetup (LUKS encryption support)
- lvm2 (LVM volume support)
- kpartx (partition mapping)

### Optional
- xhost (GUI/X11 support)

### Installation of Dependencies

```bash
# Ubuntu/Debian
sudo apt install dialog qemu-utils util-linux cryptsetup lvm2 kpartx x11-xserver-utils

# Fedora/RHEL
sudo dnf install dialog qemu-img util-linux cryptsetup lvm2 kpartx xorg-x11-server-utils
```

## How It Works

### For Physical Disks

1. User selects the physical disk or partition
2. Script identifies partition type (LUKS, LVM, regular)
3. Opens LUKS containers if encrypted
4. Activates LVM volumes if present
5. Mounts the root filesystem to `/mnt/chroot`
6. Optionally mounts /boot and /boot/efi partitions
7. Bind mounts system directories (/dev, /proc, /sys, /dev/pts)
8. Optionally configures X11 forwarding for GUI apps
9. Executes chroot and drops into a shell
10. On exit, unmounts everything in reverse order and cleans up

### For Virtual Disk Images

1. User selects a virtual disk image file
2. Script connects the image to an NBD device using qemu-nbd
3. Scans the NBD device for partitions
4. Continues with steps 3-10 from physical disk workflow

### Modular Architecture

The script uses a modular design with helper modules:

```
chroot/
├── manzolo-chroot.sh          # Main script
└── manzolo-chroot/            # Helper modules
    ├── checks.sh              # System requirements and validation
    ├── chroot.sh              # Core chroot functionality
    ├── cleanup.sh             # Cleanup and unmounting
    ├── config.sh              # Configuration file handling
    ├── debug.sh               # Debug and logging
    ├── device.sh              # Device detection and handling
    ├── gui.sh                 # X11/GUI support
    ├── help.sh                # Help text
    ├── interactive_mode.sh    # Dialog TUI interface
    ├── log.sh                 # Logging functions
    ├── mount.sh               # Mounting operations
    ├── nbd.sh                 # NBD device management
    ├── process.sh             # Process management
    ├── storage.sh             # Storage operations
    ├── sudo.sh                # Sudo handling
    └── virtual_disk.sh        # Virtual disk operations
```

## Configuration Files

You can save frequently used configurations to avoid interactive prompts:

**Example config file (`chroot.conf`):**
```bash
ROOT_DEVICE="/dev/sda2"
BOOT_PART="/dev/sda1"
EFI_PART=""
ENABLE_GUI_SUPPORT=true
CHROOT_USER="root"
CUSTOM_SHELL="/bin/bash"
```

**Usage:**
```bash
sudo mchroot -c chroot.conf
```

## Common Use Cases

### 1. System Rescue and Recovery

**Scenario**: Your system won't boot and you need to fix it.

```bash
# Boot from live USB
sudo mchroot

# Inside chroot:
# - Reinstall bootloader: grub-install /dev/sda
# - Update initramfs: update-initramfs -u
# - Fix broken packages: apt --fix-broken install
# - Edit configuration files
# - Check logs: journalctl
```

### 2. VM Disk Maintenance

**Scenario**: Install software or configure a VM without booting it.

```bash
sudo mchroot -v /var/lib/libvirt/images/server.qcow2

# Inside chroot:
apt update && apt install nginx
systemctl enable nginx
# Edit configs, etc.
```

### 3. Password Reset

**Scenario**: Forgotten password on a system.

```bash
sudo mchroot

# Inside chroot:
passwd username
```

### 4. Encrypted System Access

**Scenario**: Access LUKS-encrypted system from live environment.

```bash
sudo mchroot
# Select encrypted partition
# Enter LUKS passphrase
# Access encrypted files
```

### 5. Backup Before Reinstall

**Scenario**: Access files before wiping a disk.

```bash
sudo mchroot
# Browse and copy important files
# Check configurations
```

### 6. Cross-Distribution Testing

**Scenario**: Test software on different distributions without rebooting.

```bash
sudo mchroot -v ubuntu.qcow2
# Test on Ubuntu

sudo mchroot -v fedora.qcow2
# Test on Fedora
```

## Safety Features

- **Automatic Cleanup**: All mounts and NBD devices are cleaned up on exit
- **Lock File**: Prevents multiple instances from running
- **Reverse Order Unmounting**: Unmounts in proper order to prevent issues
- **LUKS and LVM Cleanup**: Properly closes encrypted containers and deactivates volumes
- **Error Handling**: Comprehensive error checking and recovery
- **Logging**: Detailed logs in `/tmp/manzolo-chroot.log`

## Troubleshooting

### NBD Device Busy

**Problem**: NBD device is already in use.

**Solution**:
```bash
# Check NBD devices
lsblk | grep nbd

# Disconnect NBD device
sudo qemu-nbd --disconnect /dev/nbd0

# Try again
sudo mchroot
```

### LUKS Unlock Failed

**Problem**: Cannot unlock encrypted partition.

**Solution**:
- Verify the correct passphrase
- Check if device is a LUKS partition: `sudo cryptsetup isLuks /dev/sdX`
- Try manual unlock: `sudo cryptsetup open /dev/sdX cryptroot`

### GUI Applications Won't Start

**Problem**: X11 errors when running GUI apps from chroot.

**Solution**:
```bash
# On host, allow X11 connections
xhost +local:

# Enable GUI support when running mchroot
sudo mchroot
# Select "Yes" for GUI support
```

### Mount Point Busy

**Problem**: Cannot unmount, device is busy.

**Solution**:
```bash
# Find processes using the mount
sudo lsof /mnt/chroot

# Kill processes if needed
# Or wait for chroot session to end properly
```

### Virtual Disk Image Not Found

**Problem**: Cannot locate virtual disk image.

**Solution**:
- Verify file exists: `ls -lh /path/to/disk.qcow2`
- Use absolute path
- Check file permissions
- Check file format: `qemu-img info disk.qcow2`

## Advanced Usage

### Nested Chroot

You can chroot into a system that's inside a virtual disk on an encrypted partition:

```bash
sudo mchroot
# Select encrypted physical partition
# Select virtual disk image stored on that partition
# Chroot into the VM inside the encrypted disk
```

### Custom Mount Points

For complex setups with separate /home, /var, etc.:

```bash
sudo mchroot
# Select root partition
# Add additional mount points when prompted
# Specify /dev/sdX3 for /home, /dev/sdX4 for /var, etc.
```

### Running Services in Chroot

Be cautious when running services:

```bash
# Inside chroot
systemctl start service_name  # Won't work (no systemd in chroot)

# Instead, run directly:
/usr/sbin/nginx
/usr/bin/mysqld
```

## Tips and Best Practices

1. **Always backup** before making changes to system files
2. **Use read-only mode** for virtual disks when just inspecting: `qemu-nbd -r`
3. **Exit cleanly** - don't kill the script abruptly to ensure proper cleanup
4. **Check logs** if something fails: `cat /tmp/manzolo-chroot.log`
5. **Test in VM** first before using on production systems
6. **Use snapshots** for virtual disks before making changes
7. **Verify unmounting** after exit: `mount | grep chroot` should return nothing

## Comparison with Standard Chroot

| Feature | Standard chroot | manzolo-chroot |
|---------|----------------|----------------|
| Virtual disk support | ❌ | ✅ |
| LUKS support | Manual | ✅ Automatic |
| LVM support | Manual | ✅ Automatic |
| NBD mounting | Manual | ✅ Automatic |
| Bind mounts | Manual | ✅ Automatic |
| GUI/X11 support | Manual | ✅ One-click |
| Interactive interface | ❌ | ✅ Dialog TUI |
| Automatic cleanup | ❌ | ✅ Trap-based |
| Multi-partition | Manual | ✅ Interactive |

## Exit Codes

- `0` - Success
- `1` - General error
- `2` - Missing dependencies
- `3` - Permission denied
- `4` - Device/file not found
- `5` - Mount failed
- `6` - Another instance running

## Logs

All operations are logged to `/tmp/manzolo-chroot.log`. Check this file for debugging:

```bash
# View log in real-time
tail -f /tmp/manzolo-chroot.log

# Search for errors
grep -i error /tmp/manzolo-chroot.log
```

## Security Considerations

- Requires root privileges (be careful what you run)
- GUI support exposes X11 server (use xhost restrictions)
- Virtual disks are mounted read-write (use snapshots for safety)
- LUKS passphrases are not logged or stored
- Environment isolation is not complete (it's chroot, not containerization)

## See Also

- [VM Disk Manager](../vm/README.md) - For VM disk operations
- [Disk Cloner](../disk-cloner/README.md) - For disk cloning operations
- Standard Linux commands: `chroot(1)`, `mount(8)`, `qemu-nbd(8)`, `cryptsetup(8)`
