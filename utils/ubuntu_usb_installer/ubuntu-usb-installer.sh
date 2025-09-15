#!/bin/bash
# Ubuntu USB Installer Script - Batch Configuration Version
# This script installs Ubuntu on a USB drive with all configuration collected upfront

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables - Configuration will be collected upfront
DEVICE=""
EFI_PARTITION=""
ROOT_PARTITION=""
HOSTNAME="ubuntu-usb"
USERNAME="ubuntu"
USER_PASSWORD=""
ROOT_PASSWORD=""
SET_ROOT_PASSWORD=false
UBUNTU_RELEASE="noble"
INSTALL_DESKTOP=false

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

# Collect all configuration upfront
collect_all_configuration() {
    print_status "Collecting full configuration..."
    
    # 1. Select target device
    local devices=()
    
    print_status "Scanning for available devices..."
    
    while IFS= read -r line; do
        devices+=($line)
    done < <(get_block_devices)
    
    if [ ${#devices[@]} -eq 0 ]; then
        print_error "No suitable devices found!"
        exit 1
    fi
    
    DEVICE=$(whiptail --title "1/7 - Select Target Device" \
        --menu "Choose the device to install Ubuntu on:\n\n⚠️  WARNING: ALL DATA WILL BE ERASED!" \
        20 80 10 "${devices[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        print_error "No device selected. Exiting."
        exit 1
    fi
    
    # 2. Final device confirmation
    whiptail --title "⚠️  DEVICE CONFIRMATION  ⚠️" \
        --yesno "ALL DATA ON $DEVICE WILL BE PERMANENTLY DESTROYED!\n\nAre you absolutely sure you want to continue?" \
        10 60
    
    if [ $? -ne 0 ]; then
        print_error "Operation cancelled."
        exit 1
    fi
    
    # 3. Ubuntu release selection
    UBUNTU_RELEASE=$(whiptail --title "2/7 - Ubuntu Version" \
        --menu "Choose the Ubuntu version to install:" \
        15 60 4 \
        "noble" "24.04 LTS (Noble Numbat) - Recommended" \
        "jammy" "22.04 LTS (Jammy Jellyfish)" \
        "mantic" "23.10 (Mantic Minotaur)" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        UBUNTU_RELEASE="noble"
        print_status "Using default version: Ubuntu 24.04 LTS (Noble)"
    fi
    
    # 4. Desktop environment
    whiptail --title "3/7 - Desktop Environment" \
        --yesno "Do you want to install the Ubuntu desktop environment (GNOME)?\n\n• YES: Full system with graphical interface (~2GB additional)\n• NO: Command-line base system only\n\nInstall the desktop?" \
        12 70
    
    if [ $? -eq 0 ]; then
        INSTALL_DESKTOP=true
        print_status "Desktop environment will be installed"
    else
        INSTALL_DESKTOP=false
        print_status "Base system only will be installed"
    fi
    
    # 5. System hostname
    HOSTNAME=$(whiptail --title "4/7 - System Hostname" \
        --inputbox "Enter the system hostname:" \
        10 50 "ubuntu-usb" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$HOSTNAME" ]; then
        HOSTNAME="ubuntu-usb"
        print_status "Using default hostname: ubuntu-usb"
    fi
    
    # 6. Username
    USERNAME=$(whiptail --title "5/7 - Username" \
        --inputbox "Enter the username:" \
        10 50 "ubuntu" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$USERNAME" ]; then
        USERNAME="ubuntu"
        print_status "Using default username: ubuntu"
    fi
    
    # 7. User password
    local password_set=false
    while [ "$password_set" = false ]; do
        USER_PASSWORD=$(whiptail --title "6/7 - User Password" \
            --passwordbox "Enter the password for user $USERNAME:" \
            10 60 3>&1 1>&2 2>&3)
    
        if [ $? -ne 0 ]; then
            print_error "Password is required to continue."
            exit 1
        fi
    
        if [ -z "$USER_PASSWORD" ]; then
            whiptail --title "Error" --msgbox "Password cannot be empty!" 8 40
            continue
        fi
    
        local password_confirm=$(whiptail --title "6/7 - Confirm Password" \
            --passwordbox "Confirm the password for $USERNAME:" \
            10 60 3>&1 1>&2 2>&3)
    
        if [ "$USER_PASSWORD" = "$password_confirm" ]; then
            print_success "User password configured"
            password_set=true
        else
            whiptail --title "Error" --msgbox "Passwords do not match! Please try again." 8 40
        fi
    done
    
    # 8. Root password (optional)
    whiptail --title "7/7 - Root Password" \
        --yesno "Do you want to set a password for the root user?\n\n• YES: You will be able to log in as root\n• NO: Root will be disabled (use sudo)\n\nRecommended: NO for better security\n\nSet root password?" \
        14 70
    
    if [ $? -eq 0 ]; then
        SET_ROOT_PASSWORD=true
        local root_password_set=false
        
        while [ "$root_password_set" = false ]; do
            ROOT_PASSWORD=$(whiptail --title "7/7 - Root Password" \
                --passwordbox "Enter the password for root:" \
                10 60 3>&1 1>&2 2>&3)
        
            if [ $? -ne 0 ]; then
                # User cancelled, ask if they want to skip
                whiptail --title "Skip Root Password?" \
                    --yesno "Do you want to skip setting the root password?\nRoot will be disabled." \
                    10 50
                if [ $? -eq 0 ]; then
                    SET_ROOT_PASSWORD=false
                    break
                else
                    continue
                fi
            fi
        
            if [ -n "$ROOT_PASSWORD" ]; then
                local root_confirm=$(whiptail --title "7/7 - Confirm Root Password" \
                    --passwordbox "Confirm the password for root:" \
                    10 60 3>&1 1>&2 2>&3)
            
                if [ "$ROOT_PASSWORD" = "$root_confirm" ]; then
                    print_success "Root password configured"
                    root_password_set=true
                else
                    whiptail --title "Error" --msgbox "Passwords do not match! Please try again." 8 40
                fi
            else
                whiptail --title "Error" --msgbox "Password cannot be empty!" 8 40
            fi
        done
    else
        SET_ROOT_PASSWORD=false
        print_status "Root will be disabled"
    fi
}

# Show configuration summary and final confirmation
show_configuration_summary() {
    local desktop_text="NO - Base system only"
    if [ "$INSTALL_DESKTOP" = true ]; then
        desktop_text="YES - Ubuntu Desktop (GNOME)"
    fi
    
    local root_text="NO - Root disabled"
    if [ "$SET_ROOT_PASSWORD" = true ]; then
        root_text="YES - Password set"
    fi
    
    # Convert release codename to readable version
    local release_text="$UBUNTU_RELEASE"
    case "$UBUNTU_RELEASE" in
        "noble") release_text="Ubuntu 24.04 LTS (Noble)" ;;
        "jammy") release_text="Ubuntu 22.04 LTS (Jammy)" ;;
        "mantic") release_text="Ubuntu 23.10 (Mantic)" ;;
    esac
    
    whiptail --title "🔍 CONFIGURATION SUMMARY" \
        --yesno "Confirm the selected configuration:\n\n• Device: $DEVICE\n• Version: $release_text\n• Hostname: $HOSTNAME\n• Username: $USERNAME\n• Desktop: $desktop_text\n• Root Password: $root_text\n\n⚠️  The installation will now proceed automatically!\n\nContinue with the installation?" \
        18 70
    
    if [ $? -ne 0 ]; then
        print_error "Installation cancelled by user"
        exit 1
    fi
    
    print_success "Configuration confirmed. Starting automated installation..."
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
    
    sudo debootstrap --arch=amd64 \
        --include=linux-image-generic,grub-efi-amd64,grub-efi-amd64-signed,shim-signed \
        "$UBUNTU_RELEASE" /mnt/usb-install http://archive.ubuntu.com/ubuntu/
    
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

# Install desktop environment
install_desktop() {
    if [ "$INSTALL_DESKTOP" = true ]; then
        print_status "Installing Ubuntu Desktop (this will take additional time)..."
        
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
        print_status "Skipping desktop installation (system base only)"
    fi
}

# Set passwords
set_passwords() {
    print_status "Setting user password for: $USERNAME"
    
    # Set user password (already collected)
    echo "$USERNAME:$USER_PASSWORD" | sudo chroot /mnt/usb-install chpasswd
    print_success "User password set"
    
    # Set or disable root password based on configuration
    if [ "$SET_ROOT_PASSWORD" = true ]; then
        print_status "Setting root password..."
        echo "root:$ROOT_PASSWORD" | sudo chroot /mnt/usb-install chpasswd
        print_success "Root password set"
    else
        sudo chroot /mnt/usb-install passwd -l root
        print_success "Root account disabled (use sudo)"
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

# Test with QEMU (optional)
test_with_qemu() {
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        whiptail --title "Test with QEMU" \
            --yesno "QEMU is not installed. Do you want to install it to test the USB?\n\nThis is an optional step." 10 60
        
        if [ $? -eq 0 ]; then
            print_status "Installing QEMU..."
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
    echo "========================================"
    echo "  Ubuntu USB Installer - Batch Config  "
    echo "========================================"
    echo ""
    
    check_root
    check_dependencies
    
    # Collect ALL configuration upfront
    collect_all_configuration
    
    # Show summary and get final confirmation
    show_configuration_summary
    
    # Installation steps - now fully automated
    print_status "🚀 Starting automated installation process..."
    echo ""
    
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
    
    # Success message with more details
    local desktop_info=""
    if [ "$INSTALL_DESKTOP" = true ]; then
        desktop_info="\n\nAfter the first boot:\n• Login: $USERNAME\n• Environment: Ubuntu Desktop (GNOME)"
    else
        desktop_info="\n\nAfter the first boot:\n• Login: $USERNAME\n• System: Command-line only"
    fi
    
    whiptail --title "✅ INSTALLATION COMPLETED!" \
        --msgbox "Ubuntu has been successfully installed on $DEVICE!$desktop_info\n\nTo boot:\n1. Restart your computer\n2. Access the boot menu (F12/F8/ESC/F2)\n3. Select the USB device\n4. Choose 'Ubuntu USB' from GRUB\n" \
        22 80
    
    # Optional testing
    whiptail --title "Test Installation" \
        --yesno "Do you want to test the installation with QEMU?\n\n(Optional - you can also test directly by rebooting)" \
        10 70
    
    if [ $? -eq 0 ]; then
        test_with_qemu
    fi
    
    print_success "🎉 Installation completed! Your USB is ready to boot."
}

# Run main with error handling
set +e  # Disable exit on error for proper error handling
trap cleanup EXIT INT TERM
main "$@"