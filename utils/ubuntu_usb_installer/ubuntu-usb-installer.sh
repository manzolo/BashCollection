#!/bin/bash
# Universal USB Installer Script - Ubuntu Noble / Debian Trixie
# Multi-mode installer with batch configuration - FIXED VERSION

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Global variables
DEVICE=""
EFI_PARTITION=""
ROOT_PARTITION=""
HOSTNAME="linux-usb"
USERNAME="user"
USER_PASSWORD=""
ROOT_PASSWORD=""
SET_ROOT_PASSWORD=false
DISTRO="ubuntu"  # ubuntu or debian
RELEASE=""       # noble or trixie
INSTALL_DESKTOP=false
OPERATION_MODE=""  # full, test, chroot

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
print_cyan() {
    echo -e "${CYAN}$1${NC}"
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

# Main menu selection
select_operation_mode() {
    OPERATION_MODE=$(whiptail --title "🚀 USB Linux Installer" \
        --menu "Select operation mode:" \
        16 70 5 \
        "full" "📦 Full Installation - Complete USB setup" \
        "test" "🧪 Test Only - Test existing USB with QEMU" \
        "chroot" "🔧 Chroot - Enter existing installation" \
        "exit" "❌ Exit" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ "$OPERATION_MODE" = "exit" ]; then
        print_status "Exiting..."
        exit 0
    fi
}

# Select distribution
select_distribution() {
    local distro_choice=$(whiptail --title "🐧 Select Distribution" \
        --menu "Choose the Linux distribution to install:" \
        14 70 3 \
        "ubuntu-noble" "Ubuntu 24.04 LTS (Noble Numbat)" \
        "debian-trixie" "Debian 13 (Trixie - Testing)" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        print_error "No distribution selected. Exiting."
        exit 1
    fi
    
    case "$distro_choice" in
        "ubuntu-noble")
            DISTRO="ubuntu"
            RELEASE="noble"
            HOSTNAME="ubuntu-usb"
            USERNAME="ubuntu"
            ;;
        "debian-trixie")
            DISTRO="debian"
            RELEASE="trixie"
            HOSTNAME="debian-usb"
            USERNAME="debian"
            ;;
    esac
    
    print_success "Selected: $(echo $distro_choice | tr '-' ' ' | tr '[:lower:]' '[:upper:]')"
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

# Select device for operations
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
    
    local title_text="Select Target Device"
    if [ "$OPERATION_MODE" = "test" ] || [ "$OPERATION_MODE" = "chroot" ]; then
        title_text="Select USB Device"
    fi
    
    DEVICE=$(whiptail --title "$title_text" \
        --menu "Choose the device:\n\n$([ "$OPERATION_MODE" = "full" ] && echo '⚠️  WARNING: ALL DATA WILL BE ERASED!' || echo 'Select the USB device to work with:')" \
        20 80 10 "${devices[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        print_error "No device selected. Exiting."
        exit 1
    fi
    
    # Set partition variables
    if [[ "$DEVICE" == *"nvme"* ]] || [[ "$DEVICE" == *"mmcblk"* ]]; then
        EFI_PARTITION="${DEVICE}p1"
        ROOT_PARTITION="${DEVICE}p2"
    else
        EFI_PARTITION="${DEVICE}1"
        ROOT_PARTITION="${DEVICE}2"
    fi
}

# Collect full installation configuration
collect_full_configuration() {
    print_status "Collecting full configuration..."
    
    # Device already selected, confirm it
    whiptail --title "⚠️  DEVICE CONFIRMATION  ⚠️" \
        --yesno "ALL DATA ON $DEVICE WILL BE PERMANENTLY DESTROYED!\n\nDistribution: $([ "$DISTRO" = "ubuntu" ] && echo "Ubuntu Noble" || echo "Debian Trixie")\nDevice: $DEVICE\n\nAre you absolutely sure you want to continue?" \
        12 60
    
    if [ $? -ne 0 ]; then
        print_error "Operation cancelled."
        exit 1
    fi
    
    # Desktop environment
    whiptail --title "Desktop Environment" \
        --yesno "Do you want to install a desktop environment?\n\n• YES: Full system with graphical interface (~2GB additional)\n  $([ "$DISTRO" = "ubuntu" ] && echo "Ubuntu: GNOME Desktop" || echo "Debian: GNOME Desktop")\n• NO: Command-line base system only\n\nInstall desktop?" \
        14 70
    
    if [ $? -eq 0 ]; then
        INSTALL_DESKTOP=true
        print_status "Desktop environment will be installed"
    else
        INSTALL_DESKTOP=false
        print_status "Base system only will be installed"
    fi
    
    # System hostname
    HOSTNAME=$(whiptail --title "System Hostname" \
        --inputbox "Enter the system hostname:" \
        10 50 "$HOSTNAME" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$HOSTNAME" ]; then
        HOSTNAME=$([ "$DISTRO" = "ubuntu" ] && echo "ubuntu-usb" || echo "debian-usb")
    fi
    
    # Username
    USERNAME=$(whiptail --title "Username" \
        --inputbox "Enter the username:" \
        10 50 "$USERNAME" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$USERNAME" ]; then
        USERNAME=$([ "$DISTRO" = "ubuntu" ] && echo "ubuntu" || echo "debian")
    fi
    
    # User password
    local password_set=false
    while [ "$password_set" = false ]; do
        USER_PASSWORD=$(whiptail --title "User Password" \
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
    
        local password_confirm=$(whiptail --title "Confirm Password" \
            --passwordbox "Confirm the password for $USERNAME:" \
            10 60 3>&1 1>&2 2>&3)
    
        if [ "$USER_PASSWORD" = "$password_confirm" ]; then
            print_success "User password configured"
            password_set=true
        else
            whiptail --title "Error" --msgbox "Passwords do not match! Please try again." 8 40
        fi
    done
    
    # Root password (optional)
    whiptail --title "Root Password" \
        --yesno "Do you want to set a password for the root user?\n\n• YES: You will be able to log in as root\n• NO: Root will be disabled (use sudo)\n\nRecommended: NO for better security\n\nSet root password?" \
        14 70
    
    if [ $? -eq 0 ]; then
        SET_ROOT_PASSWORD=true
        local root_password_set=false
        
        while [ "$root_password_set" = false ]; do
            ROOT_PASSWORD=$(whiptail --title "Root Password" \
                --passwordbox "Enter the password for root:" \
                10 60 3>&1 1>&2 2>&3)
        
            if [ $? -ne 0 ]; then
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
                local root_confirm=$(whiptail --title "Confirm Root Password" \
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
    print_status "Installing $DISTRO base system (this will take time)..."
    
    if [ "$DISTRO" = "ubuntu" ]; then
        # Ubuntu: non includere shim-signed in debootstrap, lo installeremo dopo
        sudo debootstrap --arch=amd64 \
            --include=linux-image-generic,grub-efi-amd64 \
            "$RELEASE" /mnt/usb-install http://archive.ubuntu.com/ubuntu/
    else
        # Debian Trixie
        sudo debootstrap --arch=amd64 \
            --include=linux-image-amd64,grub-efi-amd64 \
            "$RELEASE" /mnt/usb-install http://deb.debian.org/debian/
    fi
    
    if [ $? -ne 0 ]; then
        print_error "Base system installation failed!"
        exit 1
    fi
    
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
    
    # Get host system locale
    local HOST_LOCALE=$(locale | grep '^LANG=' | cut -d= -f2 | tr -d '[:space:]')
    if [ -z "$HOST_LOCALE" ]; then
        print_warning "Could not detect host locale, falling back to en_US.UTF-8"
        HOST_LOCALE="en_US.UTF-8"
    fi
    
    # Normalize locale for checking (e.g., it_IT.UTF-8 -> it_IT.utf8)
    local LOCALE_CHECK=$(echo "$HOST_LOCALE" | sed 's/UTF-8/utf8/')
    local LOCALE_BASE=$(echo "$HOST_LOCALE" | cut -d_ -f1)  # e.g., it_IT.UTF-8 -> it
    
    # Create configuration script
    cat > /tmp/chroot_config.sh << 'CHROOT_SCRIPT'
#!/bin/bash
set -x  # Enable debug output
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# Configure APT sources
if [ "$DISTRO" = "ubuntu" ]; then
    cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu/ $RELEASE main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $RELEASE-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $RELEASE-security main restricted universe multiverse
EOF
else
    # Debian Trixie
    cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
fi

# Update package lists and upgrade
apt update || {
    echo "Failed to update package lists. Trying alternative mirror..." >&2
    sed -i 's/archive.ubuntu.com/us.archive.ubuntu.com/' /etc/apt/sources.list
    sed -i 's/deb.debian.org/ftp.debian.org/' /etc/apt/sources.list
    apt update || exit 1
}
apt upgrade -y || {
    echo "Failed to upgrade packages, continuing with installation..." >&2
}

# Install essential packages
PACKAGES="grub-efi-amd64 efibootmgr os-prober"
PACKAGES="$PACKAGES sudo nano vim network-manager systemd-resolved locales console-setup"
PACKAGES="$PACKAGES keyboard-configuration usbutils pciutils wget curl ca-certificates libpam-modules passwd"

if [ "$DISTRO" = "ubuntu" ]; then
    # Ubuntu ha bisogno di shim-signed e grub-efi-amd64-signed per il secure boot
    PACKAGES="$PACKAGES shim-signed grub-efi-amd64-signed"
    PACKAGES="$PACKAGES initramfs-tools linux-firmware linux-image-generic"
    PACKAGES="$PACKAGES ubuntu-minimal ubuntu-standard"
    
    # Aggiungi il pacchetto della lingua solo se esiste
    if apt-cache show "language-pack-$LOCALE_BASE" >/dev/null 2>&1; then
        PACKAGES="$PACKAGES language-pack-$LOCALE_BASE"
    else
        echo "Language pack for $LOCALE_BASE not found, skipping..." >&2
    fi
else
    # Debian Trixie
    PACKAGES="$PACKAGES shim-signed grub-efi-amd64-signed"
    PACKAGES="$PACKAGES initramfs-tools firmware-linux-free"
    PACKAGES="$PACKAGES task-english task-ssh-server"
fi

# Prima di installare, assicuriamoci che dpkg sia configurato correttamente
dpkg --configure -a 2>/dev/null || true

apt install -y $PACKAGES || {
    echo "Package installation failed. Retrying with --fix-missing..." >&2
    apt update
    apt install -y --fix-missing $PACKAGES || {
        echo "Still failing, trying to install packages one by one..." >&2
        for pkg in $PACKAGES; do
            apt install -y $pkg || echo "Warning: Failed to install $pkg" >&2
        done
    }
}

# Generate locales
if grep -q "^$HOST_LOCALE" /usr/share/i18n/SUPPORTED || grep -q "^$(echo "$HOST_LOCALE" | sed 's/UTF-8/utf8/')" /usr/share/i18n/SUPPORTED; then
    echo "$HOST_LOCALE UTF-8" > /etc/locale.gen
    locale-gen || {
        echo "Failed to generate locale $HOST_LOCALE, falling back to en_US.UTF-8" >&2
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
        locale-gen || exit 1
    }
else
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen || exit 1
    echo "Warning: Host locale $HOST_LOCALE not supported, defaulting to en_US.UTF-8" >&2
fi

# Verify and set locale
if locale -a | grep -q -E "^($LOCALE_CHECK|$HOST_LOCALE)$"; then
    echo "LANG=$HOST_LOCALE" > /etc/default/locale
    update-locale LANG="$HOST_LOCALE" || {
        echo "Failed to set locale $HOST_LOCALE, trying en_US.UTF-8" >&2
        echo "LANG=en_US.UTF-8" > /etc/default/locale
        update-locale LANG="en_US.UTF-8" || exit 1
    }
    echo "Locale $HOST_LOCALE successfully configured" >&2
else
    echo "LANG=en_US.UTF-8" > /etc/default/locale
    update-locale LANG="en_US.UTF-8" || exit 1
    echo "Warning: Locale $HOST_LOCALE not available, using en_US.UTF-8" >&2
fi

# Set timezone
ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
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

# Create user and verify
useradd -m -s /bin/bash -G sudo,adm,dialout,cdrom,floppy,audio,dip,video,plugdev,netdev "$USERNAME" || {
    echo "Failed to create user $USERNAME" >&2
    exit 1
}
if id "$USERNAME" >/dev/null 2>&1; then
    echo "User $USERNAME created successfully" >&2
else
    echo "User $USERNAME creation failed" >&2
    exit 1
fi

# Configure fstab
cat > /etc/fstab << EOF
# /etc/fstab: static file system information.
UUID=$ROOT_UUID /               ext4    errors=remount-ro 0       1
UUID=$EFI_UUID  /boot/efi       vfat    umask=0077      0       1
tmpfs           /tmp            tmpfs   defaults,noatime,mode=1777 0 0
EOF

# Verify kernel and initramfs
if [ -z "$(ls /boot/vmlinuz-* 2>/dev/null)" ] || [ -z "$(ls /boot/initrd.img-* 2>/dev/null)" ]; then
    echo "Error: Kernel or initramfs files missing in /boot" >&2
    apt install --reinstall linux-image-generic || exit 1
    update-initramfs -c -k all || exit 1
fi

# Check kernel and initramfs consistency
for kernel in /boot/vmlinuz-*; do
    kernel_version=$(basename "$kernel" | sed 's/vmlinuz-//')
    if [ ! -f "/boot/initrd.img-$kernel_version" ]; then
        echo "Error: Missing initramfs for kernel $kernel_version" >&2
        update-initramfs -c -k "$kernel_version" || exit 1
    fi
done

# Configure initramfs for USB boot (CRITICAL for USB boot)
if [ "$DISTRO" = "ubuntu" ]; then
    # Ubuntu specific USB modules configuration
    cat > /etc/initramfs-tools/modules << EOF
# USB storage modules - required for USB boot
usb_storage
uas
uhci_hcd
ohci_hcd
ehci_hcd
xhci_hcd
xhci_pci
# Additional storage drivers
sd_mod
sr_mod
# File systems
ext4
vfat
EOF

    # Ensure USB modules are included in initramfs
    cat > /etc/initramfs-tools/hooks/usb-boot << 'HOOKSCRIPT'
#!/bin/sh
PREREQ=""
prereqs()
{
    echo "$PREREQ"
}
case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac
. /usr/share/initramfs-tools/hook-functions
# Force inclusion of USB modules
force_load usb_storage
force_load uas
force_load xhci_hcd
force_load xhci_pci
force_load ehci_hcd
copy_exec /sbin/blkid
copy_exec /sbin/lsblk
exit 0
HOOKSCRIPT
    chmod +x /etc/initramfs-tools/hooks/usb-boot

    # Add delay for USB detection
    echo "MODULES=most" > /etc/initramfs-tools/initramfs.conf
    echo "COMPRESS=gzip" >> /etc/initramfs-tools/initramfs.conf
    echo "RESUME=none" >> /etc/initramfs-tools/initramfs.conf
    
    # Add rootdelay for slow USB devices
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash rootdelay=5"/' /etc/default/grub
    
else
    # Debian configuration
    cat > /etc/initramfs-tools/modules << EOF
# USB storage modules
usb_storage
uas
uhci_hcd
ohci_hcd
ehci_hcd
xhci_hcd
xhci_pci
EOF
fi

# Update initramfs
update-initramfs -c -k all || {
    echo "Failed to update initramfs" >&2
    exit 1
}

# Configure GRUB
cat > /etc/default/grub << EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="$DISTRO USB"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=true
EOF

# Install GRUB for UEFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=$DISTRO --removable --recheck || {
    echo "GRUB installation failed" >&2
    exit 1
}

# Create BOOT entry for better compatibility
mkdir -p /boot/efi/EFI/BOOT

if [ "$DISTRO" = "ubuntu" ]; then
    # Ubuntu specific: copy shim and grub files
    if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
        cp /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/bootx64.efi
        cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
    elif [ -f /usr/lib/shim/shimx64.efi.signed ]; then
        cp /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/BOOT/bootx64.efi
        # Find and copy grubx64.efi
        if [ -f /boot/efi/EFI/ubuntu/grubx64.efi ]; then
            cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
        elif [ -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ]; then
            cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /boot/efi/EFI/BOOT/grubx64.efi
        fi
    else
        # Fallback: use grubx64.efi as bootx64.efi
        if [ -f /boot/efi/EFI/ubuntu/grubx64.efi ]; then
            cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/bootx64.efi
            cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
        fi
    fi
    
    # CRITICAL FIX: Create proper fallback GRUB config for Ubuntu
    # This is what was missing and causing boot failures
    cat > /boot/efi/EFI/BOOT/grub.cfg << GRUBCFG
set timeout=10
set default=0

# Search for root partition by UUID
search --no-floppy --fs-uuid --set=root $ROOT_UUID

# Load necessary modules
insmod gzio
insmod part_gpt
insmod ext2
insmod normal
insmod linux
insmod echo
insmod all_video
insmod test
insmod multiboot
insmod multiboot2
insmod search
insmod sleep
insmod iso9660
insmod usb
insmod usbms
insmod fat
insmod efifwsetup

# Main Ubuntu entry
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

# Advanced options - load main grub.cfg
menuentry "Advanced options" {
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    configfile /boot/grub/grub.cfg
}

# UEFI Firmware Settings
if [ "\${grub_platform}" = "efi" ]; then
    menuentry "System Setup" {
        fwsetup
    }
fi
GRUBCFG

    # Also ensure symlinks exist in /boot for Ubuntu
    cd /boot
    for kernel in vmlinuz-*; do
        if [ -f "$kernel" ]; then
            version="${kernel#vmlinuz-}"
            [ -e "vmlinuz" ] || ln -s "$kernel" vmlinuz
            [ -e "initrd.img" ] || [ ! -f "initrd.img-$version" ] || ln -s "initrd.img-$version" initrd.img
        fi
    done
    cd /
    
else
    # Debian configuration (già funzionante)
    if [ -f /boot/efi/EFI/debian/shimx64.efi ]; then
        cp /boot/efi/EFI/debian/shimx64.efi /boot/efi/EFI/BOOT/bootx64.efi
        cp /boot/efi/EFI/debian/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
    elif [ -f /usr/lib/shim/shimx64.efi.signed ]; then
        cp /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/BOOT/bootx64.efi
        if [ -f /boot/efi/EFI/debian/grubx64.efi ]; then
            cp /boot/efi/EFI/debian/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
        elif [ -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ]; then
            cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /boot/efi/EFI/BOOT/grubx64.efi
        fi
    else
        if [ -f /boot/efi/EFI/debian/grubx64.efi ]; then
            cp /boot/efi/EFI/debian/grubx64.efi /boot/efi/EFI/BOOT/bootx64.efi
            cp /boot/efi/EFI/debian/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
        fi
    fi
    
    # Debian fallback grub.cfg
    cat > /boot/efi/EFI/BOOT/grub.cfg << GRUBCFG
search.fs_uuid $ROOT_UUID root 
set prefix=(\$root)'/boot/grub'
configfile \$prefix/grub.cfg
GRUBCFG
fi

# Verify GRUB EFI files
echo "Contents of /boot/efi/EFI/BOOT/:" >&2
ls -la /boot/efi/EFI/BOOT/ >&2
if [ -d /boot/efi/EFI/$DISTRO ]; then
    echo "Contents of /boot/efi/EFI/$DISTRO/:" >&2
    ls -la /boot/efi/EFI/$DISTRO/ >&2 || true
fi

# Ensure BOOTX64.EFI exists and is valid (case insensitive)
if [ ! -f /boot/efi/EFI/BOOT/bootx64.efi ] && [ ! -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
    echo "ERROR: bootx64.efi/BOOTX64.EFI still missing after all attempts!" >&2
    exit 1
fi

# Check file size
if [ -f /boot/efi/EFI/BOOT/bootx64.efi ]; then
    bootx64_size=$(stat -c%s /boot/efi/EFI/BOOT/bootx64.efi)
elif [ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
    bootx64_size=$(stat -c%s /boot/efi/EFI/BOOT/BOOTX64.EFI)
fi

if [ "$bootx64_size" -lt 1000 ]; then
    echo "ERROR: bootx64.efi is too small ($bootx64_size bytes), likely corrupted!" >&2
    exit 1
fi

echo "bootx64.efi verified: $bootx64_size bytes" >&2

# Update GRUB configuration
update-grub || {
    echo "Failed to update GRUB configuration" >&2
    exit 1
}

# Enable NetworkManager
systemctl enable NetworkManager
systemctl enable systemd-resolved

# Configure networking
if [ "$DISTRO" = "ubuntu" ]; then
    cat > /etc/netplan/01-network-manager-all.yaml << EOF
network:
  version: 2
  renderer: NetworkManager
EOF
else
    # Debian uses /etc/network/interfaces
    cat > /etc/network/interfaces << EOF
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# Let NetworkManager handle other interfaces
EOF
fi

# Clean apt cache
apt-get clean
echo "System configuration completed"
CHROOT_SCRIPT

    # Make the script executable and pass variables
    chmod +x /tmp/chroot_config.sh
    
    # Create a wrapper script that exports the variables
    cat > /tmp/chroot_wrapper.sh << WRAPPER_SCRIPT
#!/bin/bash
export DISTRO="$DISTRO"
export RELEASE="$RELEASE"
export HOSTNAME="$HOSTNAME"
export USERNAME="$USERNAME"
export ROOT_UUID="$ROOT_UUID"
export EFI_UUID="$EFI_UUID"
export HOST_LOCALE="$HOST_LOCALE"
export LOCALE_CHECK="$LOCALE_CHECK"
export LOCALE_BASE="$LOCALE_BASE"
/tmp/chroot_config.sh
WRAPPER_SCRIPT
    
    chmod +x /tmp/chroot_wrapper.sh
    
    # Copy scripts to chroot
    sudo cp /tmp/chroot_config.sh /mnt/usb-install/tmp/
    sudo cp /tmp/chroot_wrapper.sh /mnt/usb-install/tmp/
    
    # Execute configuration script with logging
    sudo chroot /mnt/usb-install /tmp/chroot_wrapper.sh 2>&1 | tee /tmp/chroot_config.log || {
        print_error "Chroot configuration failed. Check /tmp/chroot_config.log for details."
        exit 1
    }
    
    print_success "System configured"
}

# Install desktop environment
install_desktop() {
    if [ "$INSTALL_DESKTOP" = true ]; then
        print_status "Installing Desktop Environment (this will take additional time)..."
        
        cat > /tmp/install_desktop.sh << DESKTOP_SCRIPT
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update

if [ "$DISTRO" = "ubuntu" ]; then
    apt-get install -y ubuntu-desktop-minimal firefox
else
    # Debian with GNOME
    apt-get install -y task-gnome-desktop firefox-esr
fi

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
    
    # Set user password
    echo "$USERNAME:$USER_PASSWORD" | sudo chroot /mnt/usb-install chpasswd
    print_success "User password set"
    
    # Set or disable root password
    if [ "$SET_ROOT_PASSWORD" = true ]; then
        print_status "Setting root password..."
        echo "root:$ROOT_PASSWORD" | sudo chroot /mnt/usb-install chpasswd
        print_success "Root password set"
    else
        sudo chroot /mnt/usb-install passwd -l root
        print_success "Root account disabled (use sudo)"
    fi
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
        whiptail --title "Install QEMU?" \
            --yesno "QEMU is not installed. Do you want to install it?\n\nRequired for testing the USB drive." 10 60
        
        if [ $? -eq 0 ]; then
            print_status "Installing QEMU..."
            sudo apt update
            sudo apt install -y qemu-system-x86 ovmf
        else
            print_error "QEMU is required for testing. Exiting."
            return 1
        fi
    fi
    
    print_status "Starting QEMU test..."
    
    # Find OVMF
    OVMF=""
    for path in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
        if [ -f "$path" ]; then
            OVMF="$path"
            break
        fi
    done
    
    if [ -n "$OVMF" ]; then
        print_cyan "Launching QEMU with UEFI..."
        sudo qemu-system-x86_64 \
            -m 2048 \
            -bios "$OVMF" \
            -drive format=raw,file="$DEVICE" \
            -enable-kvm 2>/dev/null || \
        sudo qemu-system-x86_64 \
            -m 2048 \
            -bios "$OVMF" \
            -drive format=raw,file="$DEVICE"
    else
        print_warning "UEFI firmware not found, testing without UEFI"
        sudo qemu-system-x86_64 \
            -m 2048 \
            -drive format=raw,file="$DEVICE" \
            -enable-kvm 2>/dev/null || \
        sudo qemu-system-x86_64 \
            -m 2048 \
            -drive format=raw,file="$DEVICE"
    fi
}

# Enter chroot mode
enter_chroot() {
    print_status "Preparing to enter chroot on $DEVICE..."
    
    # Check if partitions exist
    if [ ! -b "$ROOT_PARTITION" ]; then
        print_error "Root partition $ROOT_PARTITION not found!"
        exit 1
    fi
    
    # Mount partitions
    print_status "Mounting partitions..."
    sudo mkdir -p /mnt/usb-install
    sudo mount "$ROOT_PARTITION" /mnt/usb-install
    
    if [ -b "$EFI_PARTITION" ]; then
        sudo mount "$EFI_PARTITION" /mnt/usb-install/boot/efi
    fi
    
    # Setup chroot environment
    setup_chroot
    
    print_cyan "Entering chroot environment..."
    print_cyan "Type 'exit' to leave the chroot"
    echo ""
    
    # Enter chroot
    sudo chroot /mnt/usb-install /bin/bash
    
    # Cleanup after exiting chroot
    cleanup
    print_success "Exited chroot environment"
}

# Full installation process
full_installation() {
    select_distribution
    select_device
    collect_full_configuration
    
    # Show summary
    local desktop_text="NO - Base system only"
    if [ "$INSTALL_DESKTOP" = true ]; then
        desktop_text="YES - Desktop Environment"
    fi
    
    local root_text="NO - Root disabled"
    if [ "$SET_ROOT_PASSWORD" = true ]; then
        root_text="YES - Password set"
    fi
    
    whiptail --title "🔍 CONFIGURATION SUMMARY" \
        --yesno "Confirm the configuration:\n\n• Distribution: $([ "$DISTRO" = "ubuntu" ] && echo "Ubuntu Noble" || echo "Debian Trixie")\n• Device: $DEVICE\n• Hostname: $HOSTNAME\n• Username: $USERNAME\n• Desktop: $desktop_text\n• Root Password: $root_text\n\n⚠️  Installation will proceed automatically!\n\nContinue?" \
        18 70
    
    if [ $? -ne 0 ]; then
        print_error "Installation cancelled"
        exit 1
    fi
    
    print_status "🚀 Starting automated installation..."
    echo ""
    
    partition_device
    format_partitions
    mount_partitions
    install_base_system
    setup_chroot
    configure_system
    install_desktop
    set_passwords
    cleanup
    
    whiptail --title "✅ INSTALLATION COMPLETED!" \
        --msgbox "$([ "$DISTRO" = "ubuntu" ] && echo "Ubuntu Noble" || echo "Debian Trixie") has been successfully installed on $DEVICE!\n\nLogin: $USERNAME\n\nTo boot:\n1. Restart your computer\n2. Access boot menu (F12/F8/ESC)\n3. Select the USB device" \
        16 70
    
    # Ask for QEMU test
    whiptail --title "Test Installation" \
        --yesno "Do you want to test the installation with QEMU?" \
        10 60
    
    if [ $? -eq 0 ]; then
        test_with_qemu
    fi
}

# Main function
main() {
    clear
    echo "========================================="
    echo "   Universal USB Linux Installer        "
    echo "   Ubuntu Noble / Debian Trixie         "
    echo "========================================="
    echo ""
    
    check_root
    check_dependencies
    
    # Main operation selection
    select_operation_mode
    
    case "$OPERATION_MODE" in
        "full")
            full_installation
            ;;
        "test")
            select_device
            test_with_qemu
            ;;
        "chroot")
            select_device
            enter_chroot
            ;;
        *)
            print_error "Invalid operation mode"
            exit 1
            ;;
    esac
    
    print_success "🎉 Operation completed successfully!"
}

# Run main with error handling
set +e
trap cleanup EXIT INT TERM
main "$@"