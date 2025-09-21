#!/bin/bash

# Script to setup and run Raspberry Pi OS in QEMU
# Enhanced version with multiple OS versions support, .xz support, and DTB fixes

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Working directories
readonly WORK_DIR="$(pwd)"
readonly DEST_DIR="qemu_vms"
readonly CACHE_DIR=".qemu_cache"

# QEMU Configuration
readonly DEFAULT_MEMORY="256"  # MB (aumentato per Bullseye)
readonly SSH_PORT="5022"

# OS Versions configuration - Aggiunto DTB compatibile con versatilepb
declare -A OS_VERSIONS=(
    ["1"]="jessie|2017-04-10|kernel-qemu-4.4.34-jessie|versatile-pb.dtb|http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/2017-04-10-raspbian-jessie.zip"
    ["2"]="stretch|2018-11-13|kernel-qemu-4.14.79-stretch|versatile-pb.dtb|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2018-11-15/2018-11-13-raspbian-stretch-lite.zip"
    ["3"]="buster|2020-02-13|kernel-qemu-4.19.50-buster|versatile-pb-buster.dtb|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2020-02-14/2020-02-13-raspbian-buster-lite.zip"
    ["4"]="bullseye|2022-04-04|kernel-qemu-5.10.63-bullseye|versatile-pb.dtb|https://downloads.raspberrypi.org/raspios_oldstable_lite_armhf/images/raspios_oldstable_lite_armhf-2022-04-07/2022-04-04-raspios-bullseye-armhf-lite.img.xz"
)

# Kernel and DTB repository base URL
readonly KERNEL_REPO="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master"

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Function to check required commands
check_requirements() {
    local missing_deps=()
    
    for cmd in wget unzip xz fdisk awk qemu-img qemu-system-arm; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install them with: sudo apt-get install ${missing_deps[*]}"
        return 1
    fi
}

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_warn "Script terminated with error. Cleaning up..."
        
        # Unmount if mounted
        if mountpoint -q "$DEST_DIR" 2>/dev/null; then
            log_info "Unmounting $DEST_DIR..."
            sudo umount "$DEST_DIR" 2>/dev/null || true
        fi
    fi
    
    exit $exit_code
}

# Function to download with retry
download_with_retry() {
    local url=$1
    local output=$2
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Downloading $output (attempt $attempt/$max_attempts)..."
        
        if wget --progress=bar:force -O "$output" "$url"; then
            log_info "Download completed: $output"
            return 0
        else
            log_warn "Download failed, attempt $attempt of $max_attempts"
            attempt=$((attempt + 1))
            [ $attempt -le $max_attempts ] && sleep 5
        fi
    done
    
    log_error "Download failed after $max_attempts attempts"
    return 1
}

# Function to verify image integrity
verify_image() {
    local img_file=$1
    
    if [ ! -f "$img_file" ]; then
        log_error "Image file not found: $img_file"
        return 1
    fi
    
    # Check that image has at least 2 partitions
    local partitions=$(fdisk -l "$img_file" 2>/dev/null | grep -c "^${img_file}[0-9]" || true)
    
    if [ "$partitions" -lt 2 ]; then
        log_error "Invalid or corrupted image (partitions found: $partitions)"
        return 1
    fi
    
    log_info "Image verified: $partitions partitions found"
    return 0
}

# Function to resize image to power of 2
resize_image_to_power_of_2() {
    local img_file=$1
    local current_size=$(stat -c%s "$img_file")
    local size_gb=$((current_size / 1073741824))
    local new_size=4
    
    # Find next power of 2
    if [ $size_gb -lt 4 ]; then
        new_size=4
    elif [ $size_gb -lt 8 ]; then
        new_size=8
    elif [ $size_gb -lt 16 ]; then
        new_size=16
    else
        new_size=32
    fi
    
    log_info "Resizing image to ${new_size}G (power of 2 requirement for QEMU SD card emulation)..."
    
    # Backup original image
    cp "$img_file" "${img_file}.backup"
    
    # Resize image
    if qemu-img resize "$img_file" "${new_size}G"; then
        log_info "Image resized successfully to ${new_size}G"
        rm -f "${img_file}.backup"
        return 0
    else
        log_error "Failed to resize image"
        mv "${img_file}.backup" "$img_file"
        return 1
    fi
}

# Function to select OS version
select_os_version() {
    echo
    log_info "=== Available Raspberry Pi OS Versions ==="
    echo
    
    for key in "${!OS_VERSIONS[@]}"; do
        IFS='|' read -r version date kernel dtb url <<< "${OS_VERSIONS[$key]}"
        echo -e "  ${BLUE}[$key]${NC} Raspbian ${GREEN}$version${NC} ($date)"
    done
    
    echo
    read -p "Select version [1-${#OS_VERSIONS[@]}] (default: 1): " selection
    selection=${selection:-1}
    
    if [[ ! "${OS_VERSIONS[$selection]+isset}" ]]; then
        log_error "Invalid selection. Using default (jessie)"
        selection="1"
    fi
    
    # Parse selected version
    IFS='|' read -r VERSION DATE KERNEL DTB URL <<< "${OS_VERSIONS[$selection]}"
    
    # Set global variables
    IMG_FILE="${DATE}-raspbian-${VERSION}"
    COMPRESSED_FILE="${IMG_FILE}.zip"
    if [[ "$VERSION" == "bullseye" ]]; then
        IMG_FILE="${DATE}-raspios-${VERSION}-armhf-lite"
        if [[ "$URL" == *.xz ]]; then
            COMPRESSED_FILE="${IMG_FILE}.img.xz"
        else
            COMPRESSED_FILE="${IMG_FILE}.zip"
        fi
    elif [[ "$VERSION" == "stretch" || "$VERSION" == "buster" ]]; then
        IMG_FILE="${DATE}-raspbian-${VERSION}-lite"
    fi
    
    RASPBIAN_URL="$URL"
    KERNEL_FILE="$KERNEL"
    KERNEL_URL="${KERNEL_REPO}/${KERNEL}"
    DTB_FILE="$DTB"
    DTB_URL="${KERNEL_REPO}/${DTB}"
    
    log_info "Selected: Raspbian $VERSION ($DATE)"
    echo
}

# Function to download DTB with fallback
download_dtb() {
    if [ -f "$DTB_FILE" ]; then
        log_info "DTB $DTB_FILE already present"
        return 0
    fi
    
    if download_with_retry "$DTB_URL" "$DTB_FILE"; then
        return 0
    else
        log_warn "Failed to download specific DTB $DTB_FILE, trying fallback to versatile-pb.dtb..."
        DTB_FILE="versatile-pb.dtb"
        DTB_URL="${KERNEL_REPO}/${DTB_FILE}"
        if download_with_retry "$DTB_URL" "$DTB_FILE"; then
            return 0
        else
            log_error "Failed to download fallback DTB"
            return 1
        fi
    fi
}

# Function to mount image for modifications
mount_image_for_modifications() {
    local img_file=$1
    local offset=$2
    
    log_info "Mounting image to $DEST_DIR for modifications..."
    sudo mount -v -o offset="$offset" -t ext4 "$img_file" "$DEST_DIR" || {
        log_error "Mount failed"
        return 1
    }
    
    # Common modifications
    log_info "Applying common modifications..."
    
    # Enable SSH (if the directory exists)
    if [ -d "$DEST_DIR/boot" ]; then
        sudo touch "$DEST_DIR/boot/ssh" 2>/dev/null || true
    fi
    
    log_info "Image mounted. You can make additional modifications in $DEST_DIR"
    log_info "Press ENTER when done with modifications..."
    read -r
    
    log_info "Unmounting image..."
    sudo umount "$DEST_DIR"
    sleep 2
}

# ==============================================================================
# MAIN FUNCTION
# ==============================================================================

main() {
    log_info "=== QEMU Raspberry Pi OS Emulator ==="
    log_info "Working Directory: $WORK_DIR"
    
    # Setup trap for cleanup
    trap cleanup EXIT
    
    # Check system requirements
    log_info "Checking system requirements..."
    check_requirements || exit 1
    
    # Install QEMU if needed
    if ! command -v qemu-system-arm &> /dev/null; then
        log_info "Installing QEMU..."
        sudo apt-get update
        sudo apt-get install -y qemu-system-arm qemu-utils || {
            log_error "QEMU installation failed"
            exit 1
        }
    else
        log_info "QEMU already installed ($(qemu-system-arm --version | head -n1))"
    fi
    
    # Create cache directory
    mkdir -p "$CACHE_DIR"
    
    # Select OS version
    select_os_version
    
    # Download and extract Raspberry Pi OS image
    if [ -f "${IMG_FILE}.img" ]; then
        log_info "Image ${IMG_FILE}.img already present"
        verify_image "${IMG_FILE}.img" || {
            log_warn "Existing image invalid, re-downloading..."
            rm -f "${IMG_FILE}.img"
            rm -f "$COMPRESSED_FILE"
        }
    fi
    
    if [ ! -f "${IMG_FILE}.img" ]; then
        if [ ! -f "$COMPRESSED_FILE" ]; then
            download_with_retry "$RASPBIAN_URL" "$COMPRESSED_FILE" || exit 1
        fi
        
        log_info "Extracting image..."
        if [[ "$COMPRESSED_FILE" == *.xz ]]; then
            unxz -v "$COMPRESSED_FILE" || {
                log_error "Extraction failed"
                rm -f "$COMPRESSED_FILE"
                exit 1
            }
        else
            unzip -o "$COMPRESSED_FILE" || {
                log_error "Extraction failed"
                rm -f "$COMPRESSED_FILE"
                exit 1
            }
        fi
        
        # Handle different extracted filenames
        if [ ! -f "${IMG_FILE}.img" ]; then
            local found_img=$(ls *.img 2>/dev/null | head -n1)
            if [ -n "$found_img" ]; then
                log_info "Found image: $found_img, renaming to ${IMG_FILE}.img"
                mv "$found_img" "${IMG_FILE}.img"
            else
                log_error "No .img file found after extraction"
                exit 1
            fi
        fi
        
        verify_image "${IMG_FILE}.img" || exit 1
        
        log_info "Removing compressed file to save space..."
        rm -f "$COMPRESSED_FILE"
    fi
    
    # Check and resize image if needed
    local img_size=$(stat -c%s "${IMG_FILE}.img")
    local size_gb=$((img_size / 1073741824))
    
    if ! [[ $size_gb =~ ^(1|2|4|8|16|32)$ ]]; then
        resize_image_to_power_of_2 "${IMG_FILE}.img" || {
            log_warn "Failed to resize image, trying alternative method..."
        }
    fi
    
    # Download kernel
    if [ -f "$KERNEL_FILE" ]; then
        log_info "Kernel $KERNEL_FILE already present"
    else
        download_with_retry "$KERNEL_URL" "$KERNEL_FILE" || {
            log_warn "Failed to download specific kernel, trying alternative..."
            KERNEL_FILE="kernel-qemu-4.4.34-jessie"
            KERNEL_URL="${KERNEL_REPO}/${KERNEL_FILE}"
            download_with_retry "$KERNEL_URL" "$KERNEL_FILE" || exit 1
        }
    fi
    
    # Download DTB with fallback
    download_dtb || exit 1
    
    # Analyze image partitions
    log_info "Analyzing image partitions..."
    fdisk -l "${IMG_FILE}.img"
    
    local start_sector
    start_sector=$(fdisk -l "${IMG_FILE}.img" | grep "${IMG_FILE}.img2" | awk '{print $2}')
    
    if [ -z "$start_sector" ]; then
        log_error "Could not find second partition in image"
        exit 1
    fi
    
    local offset=$((start_sector * 512))
    log_info "Calculated offset: $offset (sector $start_sector)"
    
    # Create mount directory if it doesn't exist
    mkdir -p "$DEST_DIR"
    
    # Unmount if already mounted
    if mountpoint -q "$DEST_DIR" 2>/dev/null; then
        log_info "Unmounting existing directory..."
        sudo umount "$DEST_DIR" || {
            log_error "Failed to unmount $DEST_DIR"
            exit 1
        }
        sleep 2
    fi
    
    # Optional: Mount image for modifications
    read -p "Do you want to mount the image for modifications before starting? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mount_image_for_modifications "${IMG_FILE}.img" "$offset"
    fi
    
    # Display pre-launch information
    echo
    log_info "=== QEMU Configuration ==="
    log_info "OS Version: Raspbian $VERSION"
    log_info "Machine Type: versatilepb"
    log_info "Memory: ${DEFAULT_MEMORY}MB"
    log_info "SSH Port Forward: localhost:${SSH_PORT} -> guest:22"
    log_info "To connect via SSH: ssh -p ${SSH_PORT} pi@localhost"
    log_info "Default password: raspberry"
    echo
    log_warn "Press CTRL+C to terminate the emulator"
    echo
    sleep 2
    
    # Start QEMU with versatilepb configuration
    log_info "Starting QEMU emulator..."
    qemu-system-arm \
        -M versatilepb \
        -cpu arm1176 \
        -m "$DEFAULT_MEMORY" \
        -kernel "$KERNEL_FILE" \
        -dtb "$DTB_FILE" \
        -append "root=/dev/sda2 rootfstype=ext4 rw console=ttyAMA0" \
        -drive "file=${IMG_FILE}.img,format=raw" \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
        -device "rtl8139,netdev=net0" \
        -serial stdio \
        -no-reboot \
        2>/dev/null || {
            log_warn "QEMU terminated - trying fallback configuration without DTB..."
            
            # Fallback without DTB
            qemu-system-arm \
                -M versatilepb \
                -cpu arm1176 \
                -m "$DEFAULT_MEMORY" \
                -kernel "$KERNEL_FILE" \
                -append "root=/dev/sda2 rootfstype=ext4 rw console=ttyAMA0" \
                -drive "file=${IMG_FILE}.img,format=raw" \
                -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
                -device "rtl8139,netdev=net0" \
                -serial stdio \
                -no-reboot || {
                    log_error "QEMU terminated with error"
                    exit 1
                }
        }
    
    log_info "Emulator terminated successfully"
}

# Execute main function
main "$@"