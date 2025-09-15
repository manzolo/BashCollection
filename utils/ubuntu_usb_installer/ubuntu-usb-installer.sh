#!/bin/bash

# Ubuntu USB Installer Script - Fixed Version
# This script installs Ubuntu on a USB drive with proper GRUB configuration

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
DEVICE=""
EFI_PARTITION=""
ROOT_PARTITION=""
HOSTNAME="ubuntu-usb"
USERNAME="ubuntu"

# Function to print colored output
print_status() {
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

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should NOT be run as root!"
        print_error "It will ask for sudo when needed."
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    local deps=("whiptail" "sgdisk" "mkfs.fat" "mkfs.ext4" "debootstrap" "chroot")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing[*]}"
        print_status "Installing missing packages..."
        sudo apt update
        sudo apt install -y whiptail gdisk dosfstools e2fsprogs debootstrap
    fi
}

# Get list of block devices
get_block_devices() {
    lsblk -dpno NAME,SIZE | grep -E '^/dev/(sd|nvme|vd|hd)' | while read -r device size; do
        # Skip if mounted as root
        if ! lsblk "$device" | grep -q " /$"; then
            echo "$device" "$size"
        fi
    done
}

# Select target device
select_device() {
    local devices=()
    
    print_status "Scanning for available devices..."
    
    while IFS= read -r line; do
        devices+=($line)
    done < <(get_block_devices)
    
    if [ ${#devices[@]} -eq 0 ]; then
        print_error "No suitable devices found!"
        exit 1
    fi
    
    DEVICE=$(whiptail --title "Select Target Device" \
        --menu "Choose the device to install Ubuntu on:\n\nWARNING: ALL DATA WILL BE ERASED!" \
        20 80 10 "${devices[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        print_error "No device selected. Exiting."
        exit 1
    fi
    
    # Final confirmation
    whiptail --title "⚠️  WARNING  ⚠️" \
        --yesno "ALL DATA ON $DEVICE WILL BE PERMANENTLY DESTROYED!\n\nAre you absolutely sure?" \
        10 60
    
    if [ $? -ne 0 ]; then
        print_error "Operation cancelled."
        exit 1
    fi
}

# Partition the device
partition_device() {
    print_status "Partitioning $DEVICE..."
    
    # Unmount any mounted partitions
    sudo umount "${DEVICE}"* 2>/dev/null || true
    
    # Create GPT partition table
    sudo sgdisk --zap-all "$DEVICE"
    sudo sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"EFI System" "$DEVICE"
    sudo sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:"Linux filesystem" "$DEVICE"
    
    # Wait for kernel to recognize new partitions
    sleep 2
    sudo partprobe "$DEVICE"
    sleep 2
    
    # Set partition variables
    if [[ "$DEVICE" == *"nvme"* ]] || [[ "$DEVICE" == *"mmcblk"* ]]; then
        EFI_PARTITION="${DEVICE}p1"
        ROOT_PARTITION="${DEVICE}p2"
    else
        EFI_PARTITION="${DEVICE}1"
        ROOT_PARTITION="${DEVICE}2"
    fi
    
    print_success "Partitions created"
}

# Format partitions
format_partitions() {
    print_status "Formatting partitions..."
    
    sudo mkfs.fat -F32 -n "EFI" "$EFI_PARTITION"
    sudo mkfs.ext4 -F -L "USB_ROOT" "$ROOT_PARTITION"
    
    print_success "Partitions formatted"
}

# Mount partitions
mount_partitions() {
    print_status "Mounting partitions..."
    
    sudo mkdir -p /mnt/usb-install
    sudo mount "$ROOT_PARTITION" /mnt/usb-install
    sudo mkdir -p /mnt/usb-install/boot/efi
    sudo mount "$EFI_PARTITION" /mnt/usb-install/boot/efi
    
    print_success "Partitions mounted"
}

# Install base system
install_base_system() {
    print_status "Installing Ubuntu base system (this will take time)..."
    
    # Get Ubuntu release codename
    local RELEASE=$(whiptail --title "Ubuntu Release" \
        --menu "Choose Ubuntu release:" \
        12 50 4 \
        "noble" "24.04 LTS (Noble)" \
        "jammy" "22.04 LTS (Jammy)" \
        "mantic" "23.10 (Mantic)" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        RELEASE="noble"
    fi
    
    sudo debootstrap --arch=amd64 \
        --include=linux-image-generic,grub-efi-amd64,grub-efi-amd64-signed,shim-signed \
        "$RELEASE" /mnt/usb-install http://archive.ubuntu.com/ubuntu/
    
    print_success "Base system installed"
}

# Setup chroot environment
setup_chroot() {
    print_status "Setting up chroot environment..."
    
    sudo mount --bind /dev /mnt/usb-install/dev
    sudo mount --bind /dev/pts /mnt/usb-install/dev/pts
    sudo mount --bind /proc /mnt/usb-install/proc
    sudo mount --bind /sys /mnt/usb-install/sys
    sudo mount --bind /run /mnt/usb-install/run
    
    # Copy resolv.conf for internet in chroot
    sudo cp -L /etc/resolv.conf /mnt/usb-install/etc/resolv.conf
}

# Get user configuration
get_user_config() {
    HOSTNAME=$(whiptail --title "System Configuration" \
        --inputbox "Enter hostname:" \
        10 50 "ubuntu-usb" 3>&1 1>&2 2>&3) || HOSTNAME="ubuntu-usb"
    
    USERNAME=$(whiptail --title "System Configuration" \
        --inputbox "Enter username:" \
        10 50 "ubuntu" 3>&1 1>&2 2>&3) || USERNAME="ubuntu"
}

# Configure system
configure_system() {
    print_status "Configuring system..."
    
    # Get UUIDs
    local ROOT_UUID=$(sudo blkid -s UUID -o value "$ROOT_PARTITION")
    local EFI_UUID=$(sudo blkid -s UUID -o value "$EFI_PARTITION")
    
    # Create configuration script
    cat > /tmp/chroot_config.sh << CHROOT_SCRIPT
#!/bin/bash

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# Update package lists
apt-get update

# Install essential packages
apt-get install -y \\
    ubuntu-minimal \\
    ubuntu-standard \\
    linux-firmware \\
    initramfs-tools \\
    grub-efi-amd64 \\
    grub-efi-amd64-signed \\
    shim-signed \\
    efibootmgr \\
    os-prober \\
    sudo \\
    nano \\
    vim \\
    network-manager \\
    systemd-resolved \\
    locales \\
    console-setup \\
    keyboard-configuration \\
    usbutils \\
    pciutils \\
    wget \\
    curl \\
    ca-certificates

# Generate locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Set timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Configure hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Create user
useradd -m -s /bin/bash -G sudo,adm,dialout,cdrom,floppy,audio,dip,video,plugdev,netdev "$USERNAME"

# Configure fstab
cat > /etc/fstab << EOF
# /etc/fstab: static file system information.
UUID=$ROOT_UUID /               ext4    errors=remount-ro 0       1
UUID=$EFI_UUID  /boot/efi       vfat    umask=0077      0       1
tmpfs           /tmp            tmpfs   defaults,noatime,mode=1777 0 0
EOF

# Configure initramfs for USB boot
cat > /etc/initramfs-tools/modules << EOF
# USB storage modules
usb_storage
uas
uhci_hcd
ohci_hcd
ehci_hcd
xhci_hcd
EOF

# Update initramfs
update-initramfs -c -k all

# Configure GRUB
cat > /etc/default/grub << EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Ubuntu USB"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=false
EOF

# Install GRUB for UEFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --removable --recheck

# Create BOOT entry for better compatibility
mkdir -p /boot/efi/EFI/BOOT
if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
    cp /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/bootx64.efi
    cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
else
    cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/bootx64.efi
fi

# Update GRUB configuration
update-grub

# Create fallback GRUB config
cat > /boot/efi/EFI/BOOT/grub.cfg << GRUBCFG
set timeout=10
set default=0

# Search for root partition
search --no-floppy --fs-uuid --set=root $ROOT_UUID

# Load modules
insmod gzio
insmod part_gpt
insmod ext2

# Main entry
menuentry "Ubuntu USB" {
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux /boot/vmlinuz root=UUID=$ROOT_UUID ro quiet splash
    initrd /boot/initrd.img
}

# Recovery mode
menuentry "Ubuntu USB (Recovery Mode)" {
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux /boot/vmlinuz root=UUID=$ROOT_UUID ro recovery nomodeset
    initrd /boot/initrd.img
}

# UEFI Firmware Settings
if [ "\\\${grub_platform}" = "efi" ]; then
    menuentry "System Setup" {
        fwsetup
    }
fi
GRUBCFG

# Enable NetworkManager
systemctl enable NetworkManager
systemctl enable systemd-resolved

# Configure networking
cat > /etc/netplan/01-network-manager-all.yaml << EOF
network:
  version: 2
  renderer: NetworkManager
EOF

# Clean apt cache
apt-get clean

echo "System configuration completed"
CHROOT_SCRIPT
    
    # Execute configuration script
    chmod +x /tmp/chroot_config.sh
    sudo cp /tmp/chroot_config.sh /mnt/usb-install/tmp/
    sudo chroot /mnt/usb-install /tmp/chroot_config.sh
    
    print_success "System configured"
}

# Install desktop environment (optional)
install_desktop() {
    whiptail --title "Desktop Environment" \
        --yesno "Install Ubuntu Desktop (GNOME)?\n\nThis will take additional time and ~2GB space." \
        10 60
    
    if [ $? -eq 0 ]; then
        print_status "Installing Ubuntu Desktop..."
        
        cat > /tmp/install_desktop.sh << 'DESKTOP_SCRIPT'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ubuntu-desktop-minimal firefox
systemctl set-default graphical.target
DESKTOP_SCRIPT
        
        chmod +x /tmp/install_desktop.sh
        sudo cp /tmp/install_desktop.sh /mnt/usb-install/tmp/
        sudo chroot /mnt/usb-install /tmp/install_desktop.sh
        
        print_success "Desktop installed"
    else
        print_status "Skipping desktop installation"
    fi
}

# Set passwords
set_passwords() {
    # Set user password
    print_status "Setting password for user: $USERNAME"
    
    local password_set=false
    while [ "$password_set" = false ]; do
        PASSWORD=$(whiptail --title "User Password" \
            --passwordbox "Enter password for $USERNAME:" \
            10 50 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            print_warning "Password is required. Please set a password."
            continue
        fi
        
        PASSWORD_CONFIRM=$(whiptail --title "Confirm Password" \
            --passwordbox "Confirm password:" \
            10 50 3>&1 1>&2 2>&3)
        
        if [ "$PASSWORD" = "$PASSWORD_CONFIRM" ]; then
            echo "$USERNAME:$PASSWORD" | sudo chroot /mnt/usb-install chpasswd
            print_success "User password set"
            password_set=true
        else
            whiptail --title "Error" --msgbox "Passwords don't match!" 8 40
        fi
    done
    
    # Root password (optional)
    whiptail --title "Root Password" \
        --yesno "Set a root password?\n\nIf not, root will be disabled (use sudo)." \
        10 60
    
    if [ $? -eq 0 ]; then
        print_status "Setting root password..."
        local root_set=false
        while [ "$root_set" = false ]; do
            ROOT_PASS=$(whiptail --title "Root Password" \
                --passwordbox "Enter root password:" \
                10 50 3>&1 1>&2 2>&3)
            
            if [ $? -eq 0 ] && [ -n "$ROOT_PASS" ]; then
                echo "root:$ROOT_PASS" | sudo chroot /mnt/usb-install chpasswd
                print_success "Root password set"
                root_set=true
            else
                whiptail --title "Skip?" --yesno "Skip root password?" 8 40
                if [ $? -eq 0 ]; then
                    break
                fi
            fi
        done
    else
        sudo chroot /mnt/usb-install passwd -l root
        print_status "Root account disabled"
    fi
}

# Fix GRUB boot issues
fix_grub_boot() {
    print_status "Applying GRUB boot fixes..."
    
    # Get UUID
    local ROOT_UUID=$(sudo blkid -s UUID -o value "$ROOT_PARTITION")
    
    # Create comprehensive GRUB fix script
    cat > /tmp/fix_grub.sh << 'GRUBFIX'
#!/bin/bash

# Reinstall GRUB packages
apt-get install --reinstall -y grub-efi-amd64 grub-efi-amd64-signed shim-signed

# Ensure all kernel symlinks exist
cd /boot
for kernel in vmlinuz-*; do
    version="${kernel#vmlinuz-}"
    [ -e "vmlinuz" ] || ln -s "$kernel" vmlinuz
    [ -e "initrd.img" ] || ln -s "initrd.img-$version" initrd.img
done

# Reinstall GRUB to all possible locations
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=UBUNTU --removable
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --removable
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BOOT --removable

# Create multiple boot entries for compatibility
mkdir -p /boot/efi/EFI/BOOT
mkdir -p /boot/efi/EFI/ubuntu
mkdir -p /boot/efi/EFI/UBUNTU

# Copy boot files to all locations
for dir in BOOT ubuntu UBUNTU; do
    if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
        cp /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/$dir/bootx64.efi 2>/dev/null || true
        cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/$dir/grubx64.efi 2>/dev/null || true
    else
        cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/$dir/bootx64.efi 2>/dev/null || true
    fi
done

# Update GRUB
update-grub

echo "GRUB fixes applied"
GRUBFIX
    
    chmod +x /tmp/fix_grub.sh
    sudo cp /tmp/fix_grub.sh /mnt/usb-install/tmp/
    sudo chroot /mnt/usb-install /tmp/fix_grub.sh
    
    print_success "GRUB boot fixes applied"
}

# Cleanup
cleanup() {
    print_status "Cleaning up..."
    
    # Remove temp files
    sudo rm -f /mnt/usb-install/tmp/*.sh 2>/dev/null || true
    
    # Unmount filesystems
    sudo umount /mnt/usb-install/run 2>/dev/null || true
    sudo umount /mnt/usb-install/sys 2>/dev/null || true
    sudo umount /mnt/usb-install/proc 2>/dev/null || true
    sudo umount /mnt/usb-install/dev/pts 2>/dev/null || true
    sudo umount /mnt/usb-install/dev 2>/dev/null || true
    sudo umount /mnt/usb-install/boot/efi 2>/dev/null || true
    sudo umount /mnt/usb-install 2>/dev/null || true
    
    sudo rmdir /mnt/usb-install 2>/dev/null || true
    
    print_success "Cleanup completed"
}

# Test with QEMU
test_with_qemu() {
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        whiptail --title "QEMU Not Found" \
            --yesno "Install QEMU for testing?" 10 50
        
        if [ $? -eq 0 ]; then
            sudo apt update
            sudo apt install -y qemu-system-x86 ovmf
        else
            return
        fi
    fi
    
    print_status "Testing with QEMU..."
    
    # Find OVMF
    OVMF=""
    for path in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        if [ -f "$path" ]; then
            OVMF="$path"
            break
        fi
    done
    
    if [ -n "$OVMF" ]; then
        sudo qemu-system-x86_64 \
            -m 2048 \
            -bios "$OVMF" \
            -drive format=raw,file="$DEVICE" \
            -enable-kvm \
            -cpu host
    else
        print_warning "Testing without UEFI"
        sudo qemu-system-x86_64 \
            -m 2048 \
            -drive format=raw,file="$DEVICE" \
            -enable-kvm \
            -cpu host
    fi
}

# Main installation
main() {
    clear
    echo "================================"
    echo "  Ubuntu USB Installer - Fixed  "
    echo "================================"
    echo ""
    
    check_root
    check_dependencies
    
    # Get configuration
    select_device
    get_user_config
    
    # Confirm installation
    whiptail --title "Confirm Installation" \
        --yesno "Ready to install:\n\nDevice: $DEVICE\nHostname: $HOSTNAME\nUsername: $USERNAME\n\nContinue?" \
        12 60
    
    if [ $? -ne 0 ]; then
        print_error "Installation cancelled"
        exit 1
    fi
    
    # Installation steps
    print_status "Starting installation..."
    
    partition_device
    format_partitions
    mount_partitions
    install_base_system
    setup_chroot
    configure_system
    install_desktop
    set_passwords
    fix_grub_boot
    cleanup
    
    # Success message
    whiptail --title "✅ Installation Complete!" \
        --msgbox "Ubuntu successfully installed on $DEVICE!\n\nTo boot:\n1. Restart computer\n2. Access boot menu (F12/F8/ESC)\n3. Select USB device\n4. Choose 'Ubuntu USB' from GRUB\n\nIf you see 'grub>' prompt:\n> configfile (hd0,gpt1)/EFI/BOOT/grub.cfg" \
        18 70
    
    # Offer testing
    whiptail --title "Test Installation" \
        --yesno "Test the installation with QEMU?" \
        8 50
    
    if [ $? -eq 0 ]; then
        test_with_qemu
    fi
    
    print_success "All done! Your USB is ready to boot."
}

# Run main with error handling
set +e  # Disable exit on error for proper error handling
trap cleanup EXIT INT TERM

main "$@"