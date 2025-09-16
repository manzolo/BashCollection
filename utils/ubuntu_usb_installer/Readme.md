# Installing Ubuntu on USB Drive from Running System

This guide explains how to install Ubuntu on a USB drive from an already running Ubuntu system (not from a live USB). This creates a full, bootable Ubuntu installation on the USB drive.

## Prerequisites

- Running Ubuntu system with root access
- USB drive (minimum 8GB recommended)
- Internet connection for package downloads

## Step 1: Identify and Partition the USB Drive

```bash
# List all block devices to identify your USB drive
lsblk

# Partition the USB drive (replace /dev/sdc with your USB device)
sudo fdisk /dev/sdc
```

### Fdisk commands:
```
n          # Create new partition
[Enter]    # Accept default (primary)
[Enter]    # Accept default (partition 1)
[Enter]    # Accept default (first sector)
+512M      # Set size to 512MB for EFI partition

t          # Change partition type
1          # Select EFI System type

n          # Create second partition
[Enter]    # Accept defaults for remaining space
[Enter]
[Enter]
[Enter]

w          # Write changes and exit
```

## Step 2: Format the Partitions

```bash
# Format EFI partition (FAT32)
sudo mkfs.fat -F32 /dev/sdc1

# Format root partition (ext4)
sudo mkfs.ext4 /dev/sdc2
```

## Step 3: Mount Partitions and Install Base System

```bash
# Mount root partition
sudo mount /dev/sdc2 /mnt

# Create and mount EFI directory
sudo mkdir -p /mnt/boot/efi
sudo mount /dev/sdc1 /mnt/boot/efi

# Install debootstrap if not already installed
sudo apt install debootstrap

# Install Ubuntu base system (Noble Numbat - 24.04 LTS)
sudo debootstrap noble /mnt http://archive.ubuntu.com/ubuntu/
```

## Step 4: Prepare for Chroot Environment

```bash
# Remount partitions (in case they were unmounted)
sudo mount /dev/sdc2 /mnt
sudo mount /dev/sdc1 /mnt/boot/efi

# Mount necessary filesystems for chroot
sudo mount --bind /dev /mnt/dev
sudo mount --bind /dev/pts /mnt/dev/pts  # Important for terminal functionality
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys

# Enter chroot environment
sudo chroot /mnt
```

## Step 5: Configure the System (Inside Chroot)

```bash
# Update package list
apt update

# Install essential packages
apt install linux-image-generic grub-efi initramfs-tools grub-efi-amd64 \
            grub2-common os-prober sudo nano network-manager

# Set hostname
echo "ubuntu-usb" > /etc/hostname

# Create user account
adduser manzolo
usermod -aG sudo manzolo
```

## Step 6: Configure Filesystem Table

```bash
# Get partition UUIDs
blkid

# Edit fstab file
nano /etc/fstab
```

### Sample /etc/fstab content:
```
# /etc/fstab: static file system information.
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>

# Root partition (replace UUID with your actual UUID from blkid)
/dev/disk/by-uuid/6d7ecf98-2a4b-48c7-b95b-99796fc48637 / ext4 defaults 0 1

# EFI partition (replace UUID with your actual UUID from blkid)
/dev/disk/by-uuid/E23B-AD74 /boot/efi vfat defaults 0 1
```

## Step 7: Install and Configure Bootloader

```bash
# Install GRUB for UEFI systems
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable

# Generate GRUB configuration
update-grub

# Generate initial ramdisk
update-initramfs -c -k all

# Update GRUB again (to ensure everything is properly configured)
update-grub

# Reinstall GRUB (redundant but ensures proper installation)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable

# Exit chroot environment
exit
```

## Step 8: Cleanup and Finalize

```bash
# Unmount all mounted filesystems
sudo umount -R /mnt
```

## Important Notes

- **Replace `/dev/sdc`** with your actual USB device identifier from `lsblk`
- **Replace UUIDs** in `/etc/fstab` with the actual UUIDs from your `blkid` output
- The `--removable` flag in grub-install ensures the USB drive is bootable on different machines
- The `/dev/pts` bind mount is crucial for proper terminal functionality in the chroot environment
- This process creates a full Ubuntu installation, not just a live USB

## Troubleshooting

- If boot fails, check that the EFI partition is properly formatted and mounted
- Ensure UEFI boot is enabled in target machine's BIOS/UEFI settings
- Verify that all UUIDs in `/etc/fstab` match the output of `blkid`
- If networking doesn't work, ensure NetworkManager is installed and enabled

## Next Steps

After successful installation, you can boot from the USB drive and complete the Ubuntu setup:
- Configure network settings
- Install additional software
- Set up desktop environment if needed