#!/bin/bash

# Test script for vm_create_disk
# Generates a matrix of disk configurations, creates disks, verifies with --info, and logs file size
# All output is logged to vm_create_disk_test.log in the current directory

# --- Configuration ---
# Set to 'true' to enable debug logging
DEBUG=${DEBUG:-false}

# Directory to store config files and disks
TEST_DIR="test_disks"

# Path to the main script (installed in system PATH)
SCRIPT_PATH="vm_create_disk"

# Log file in the current working directory
LOG_FILE="$(pwd)/vm_create_disk_test.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Flag to determine whether to keep disk images
KEEP_IMAGES=false

# --- Utility Functions ---

# Function for colored and timestamped logging
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO")
            echo -e "${BLUE}[INFO]${NC} $timestamp - $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $timestamp - $message"
            ;;
        "WARNING")
            echo -e "${YELLOW}[WARNING]${NC} $timestamp - $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $timestamp - $message" >&2
            ;;
        "DEBUG")
            if [[ "$DEBUG" == "true" ]]; then
                echo -e "${BLUE}[DEBUG]${NC} $timestamp - $message"
            fi
            ;;
        *)
            echo "$timestamp - $message"
            ;;
    esac
}

# Function to run a command with proper error handling and logging
run_command() {
    local cmd="$1"
    local description="$2"
    
    log "DEBUG" "Running: $cmd"
    
    # Run the command and capture its output
    if ! output=$(eval "$cmd" 2>&1); then
        log "ERROR" "$description failed with exit code $?"
        echo "$output" | while IFS= read -r line; do log "ERROR" "  $line"; done
        return 1
    else
        log "SUCCESS" "$description completed successfully"
        echo "$output" | while IFS= read -r line; do log "INFO" "  $line"; done
        return 0
    fi
}

# Helper function to repeat a character
repeat() {
    local char=$1
    local count=$2
    printf "%*s" "$count" "" | tr " " "$char"
}

# --- Test Case Management ---

# Function to clean up test directory and log file
cleanup() {
    log "INFO" "Cleaning up test directory and log file..."
    if [[ -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
        log "SUCCESS" "Log file $LOG_FILE removed."
    fi
    if [[ -d "$TEST_DIR" ]]; then
        if [[ "$KEEP_IMAGES" == "false" ]]; then
            rm -rf "$TEST_DIR"
            log "SUCCESS" "Test directory cleaned up."
        else
            log "INFO" "Keeping disk images in $TEST_DIR due to --keep-images option."
        fi
    fi
    # Also remove any disk files created in the current directory
    if [[ "$KEEP_IMAGES" == "false" ]]; then
        log "DEBUG" "Removing lingering disk files."
        rm -f test_*.{qcow2,raw}
    else
        log "INFO" "Keeping lingering disk files due to --keep-images option."
    fi
    # Ensure nbd devices are disconnected
    if command -v qemu-nbd >/dev/null 2>&1; then
        for nbd in /dev/nbd*; do
            if [[ -b "$nbd" ]] && sudo qemu-nbd -d "$nbd" &>/dev/null; then
                log "INFO" "Disconnected $nbd."
            fi
        done
    fi
    # Release any loop devices
    if command -v losetup >/dev/null 2>&1; then
        for loop in $(losetup -a | awk -F: '{print $1}'); do
            if sudo losetup -d "$loop" &>/dev/null; then
                log "INFO" "Released loop device $loop."
            fi
        done
    fi
}

# Function to generate a configuration file for a specific test case
generate_config() {
    local disk_format=$1
    local partition_table=$2
    local preallocation=$3
    shift 3
    local partitions_array=("$@")

    local config_file="$TEST_DIR/test_${disk_format}_${partition_table}_${preallocation}.sh"
    local disk_name="test_${disk_format}_${partition_table}_${preallocation}.${disk_format}"

    cat << EOF > "$config_file"
#!/bin/bash
DISK_NAME="$disk_name"
DISK_SIZE="10G"
DISK_FORMAT="$disk_format"
PARTITION_TABLE="$partition_table"
PREALLOCATION="$preallocation"
PARTITIONS=(
EOF

    for part in "${partitions_array[@]}"; do
        echo "    \"$part\"" >> "$config_file"
    done

    echo ")" >> "$config_file"
    chmod +x "$config_file"
   
    echo "$config_file"
}

# Function to verify the created disk file
verify_disk() {
    local disk_file="$1"
    local expected_format="$2"
    
    log "INFO" "Verifying disk file: $disk_file"
    
    if [[ ! -f "$disk_file" ]]; then
        log "ERROR" "Disk file not found: $disk_file"
        return 1
    fi
    
    # Log the file size in human-readable format
    local file_size=$(ls -lh "$disk_file" | awk '{print $5}')
    log "INFO" "Disk file size on filesystem: $file_size"
    
    local file_size_bytes=$(stat -c%s "$disk_file")
    log "DEBUG" "Disk file size: $file_size_bytes bytes"
    
    if [[ $file_size_bytes -eq 0 ]]; then
        log "ERROR" "Disk file is empty: $disk_file"
        return 1
    fi
    
    if command -v qemu-img >/dev/null 2>&1; then
        log "INFO" "Checking disk format with qemu-img..."
        if qemu-img info "$disk_file" | grep -q "file format: $expected_format"; then
            log "SUCCESS" "Disk format verified: $expected_format"
            return 0
        else
            log "ERROR" "Disk format verification failed. Expected: $expected_format"
            return 1
        fi
    else
        log "WARNING" "qemu-img command not found. Skipping format verification."
        return 0
    fi
}

# Function to analyze the disk image using lsblk
analyze_disk_with_lsblk() {
    local disk_file="$1"

    if ! command -v qemu-nbd >/dev/null 2>&1 || ! command -v lsblk >/dev/null 2>&1; then
        log "WARNING" "qemu-nbd or lsblk not found. Skipping disk analysis."
        return 0
    fi

    log "INFO" "Analyzing disk image with lsblk..."
    
    local device_name
    
    # Try to connect the disk image to a network block device
    if sudo qemu-nbd -c /dev/nbd0 --read-only "$disk_file" &> /dev/null; then
        device_name="/dev/nbd0"
        log "INFO" "Connected disk to /dev/nbd0 via qemu-nbd."
    else
        log "WARNING" "Failed to connect disk to a network block device. Falling back to loop device."
        
        # Fallback to loop device for raw format
        if [[ "$(qemu-img info "$disk_file" | grep 'file format' | awk '{print $NF}')" == "raw" ]]; then
            device_name=$(sudo losetup -f --show "$disk_file" 2>/dev/null)
            if [[ $? -ne 0 ]]; then
                log "WARNING" "Failed to set up loop device."
                return 0
            fi
            log "INFO" "Set up loop device: $device_name"
        else
            log "WARNING" "Cannot analyze non-raw disk image without qemu-nbd."
            return 0
        fi
    fi
    
    # Wait for partitions to be detected
    sleep 2
    
    # Use lsblk to get detailed information
    echo "Partition table for $disk_file:"
    if [[ "$device_name" == "/dev/nbd0" ]]; then
        # lsblk needs sudo to see partitions on nbd device
        if ! output=$(sudo lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,PARTTYPE "$device_name" 2>&1); then
            log "WARNING" "lsblk failed for $device_name."
            echo "$output" | while IFS= read -r line; do log "WARNING" "  $line"; done
        else
            echo "$output" | while IFS= read -r line; do log "INFO" "  $line"; done
        fi
    else
        # lsblk needs sudo to see partitions on loop device
        if ! output=$(sudo lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT "$device_name" 2>&1); then
            log "WARNING" "lsblk failed for $device_name."
            echo "$output" | while IFS= read -r line; do log "WARNING" "  $line"; done
        else
            echo "$output" | while IFS= read -r line; do log "INFO" "  $line"; done
        fi
    fi
    
    # Disconnect the device
    if [[ "$device_name" == "/dev/nbd0" ]]; then
        if sudo qemu-nbd -d "$device_name" &> /dev/null; then
            log "INFO" "Disconnected /dev/nbd0."
        else
            log "WARNING" "Failed to disconnect /dev/nbd0."
        fi
    elif [[ -n "$device_name" ]]; then
        if sudo losetup -d "$device_name" &> /dev/null; then
            log "INFO" "Released loop device $device_name."
        else
            log "WARNING" "Failed to release loop device $device_name."
        fi
    fi
    
    return 0
}

normalize_fs_type() {
    local raw_fs="$1"
    local part_type="$2"   # opzionale: ID partizione (esadecimale)

    case "$raw_fs" in
        vfat)
            # Distinguere fat32 vs fat16 in base al tipo partizione
            if [[ "$part_type" == "0xc" || "$part_type" == "0xb" ]]; then
                echo "fat32"
            elif [[ "$part_type" == "0x6" || "$part_type" == "0xe" ]]; then
                echo "fat16"
            else
                echo "fat32"   # fallback
            fi
            ;;
        ntfs)   echo "ntfs" ;;
        ext2)   echo "ext2" ;;
        ext3)   echo "ext3" ;;
        ext4)   echo "ext4" ;;
        swap)   echo "swap" ;;
        xfs)    echo "xfs" ;;
        btrfs)  echo "btrfs" ;;
        *)
            # Se non riconosciuto, prova a usare il codice partizione
            case "$part_type" in
                0x5|0xf) echo "none" ;;   # extended: non formattata
                *)       echo "none" ;;
            esac
            ;;
    esac
}

# --- Main Execution ---

main() {
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    
    # Parse command-line options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-images)
                KEEP_IMAGES=true
                shift
                ;;
            *)
                log "WARNING" "Unknown option: $1"
                shift
                ;;
        esac
    done
    
    # Check if the main script is executable and in PATH
    if ! command -v "$SCRIPT_PATH" >/dev/null 2>&1; then
        log "ERROR" "Main script '$SCRIPT_PATH' not found in PATH"
        exit 1
    fi

    # List of test cases (matrix: format, partition_table, preallocation, partitions)
    declare -a TESTS=(
        "qcow2 gpt off 2G:ext4 1G:swap 1G:fat32"
        "qcow2 gpt metadata 2G:ext4 2G:swap 2G:btrfs"
        "qcow2 gpt full 5G:ntfs remaining:ext4"
        "qcow2 mbr off 4G:ext4:primary 2G:fat32:primary 1G:ntfs:primary"
        "qcow2 mbr metadata 3G:xfs:primary 3G:ext4:primary remaining:swap:primary"
        "qcow2 mbr full 5G:ntfs:primary 1G:fat32:primary 1G:ext4:logical"
        "raw gpt off 1G:ext4 1G:ext3 1G:fat16 remaining:swap"
        "raw gpt full 2G:btrfs 2G:xfs 2G:ntfs"
        "raw mbr off 5G:ntfs:primary remaining:ext4:primary"
        "raw mbr full 3G:xfs:primary 2G:ntfs:primary remaining:vfat:primary"
        "qcow2 gpt full 100M:fat32 16M:msr 9G:ntfs 500M:ntfs"
        "qcow2 gpt metadata 512M:fat32 8G:ext4 1512M:swap"
        "raw mbr full 9G:ntfs:primary"
    )

    # Set up trap for cleanup on exit or interrupt
    trap cleanup EXIT INT TERM
    
    # Create test directory
    mkdir -p "$TEST_DIR" || { log "ERROR" "Failed to create test directory."; exit 1; }
    log "INFO" "Created test directory: $TEST_DIR"
    
    log "INFO" "Starting disk creation tests..."
    log "INFO" "Total test cases to run: ${#TESTS[@]}"
    
    for test_case in "${TESTS[@]}"; do
        total_tests=$((total_tests + 1))
        
        # Parse test case string into variables
        read -r disk_format partition_table preallocation partitions <<< "$test_case"
        IFS=' ' read -r -a partitions_array <<< "$partitions" # Correctly parse partitions string into an array
        
        echo
        log "INFO" "$(repeat "=" 60)"
        log "INFO" "Running Test $total_tests:"
        log "INFO" "  Format: $disk_format"
        log "INFO" "  Partition Table: $partition_table"
        log "INFO" "  Preallocation: $preallocation"
        log "INFO" "  Partitions: ${partitions_array[*]}"
        
        # Generate and check the config file
        config_file=$(generate_config "$disk_format" "$partition_table" "$preallocation" "${partitions_array[@]}")
        if [[ ! -f "$config_file" ]]; then
            log "ERROR" "Failed to generate config file: $config_file"
            failed_tests=$((failed_tests + 1))
            continue
        fi
        
        # Define disk file path
        disk_file="$TEST_DIR/test_${disk_format}_${partition_table}_${preallocation}.${disk_format}"
        
        # Run the vm_create_disk utility
        if ! run_command "$SCRIPT_PATH \"$config_file\"" "Disk creation for $disk_format disk"; then
            log "ERROR" "Disk creation failed."
            failed_tests=$((failed_tests + 1))
            continue
        fi
        
        # Check for the existence of the created file
        if [[ ! -f "./test_${disk_format}_${partition_table}_${preallocation}.${disk_format}" ]]; then
            log "ERROR" "Disk file not created by vm_create_disk."
            failed_tests=$((failed_tests + 1))
            continue
        fi
        
        # Move the disk file to the test directory for verification
        if ! mv "test_${disk_format}_${partition_table}_${preallocation}.${disk_format}" "$disk_file" 2>/dev/null; then
            log "ERROR" "Failed to move disk file to $disk_file."
            failed_tests=$((failed_tests + 1))
            continue
        fi
        
        # Verify the created disk
        if ! verify_disk "$disk_file" "$disk_format"; then
            log "ERROR" "Disk verification failed."
            failed_tests=$((failed_tests + 1))
            continue
        fi
        
        # Test the --info option and lsblk analysis
        log "INFO" "Testing --info option with lsblk..."
        if run_command "$SCRIPT_PATH --info \"$disk_file\"" "Disk info for $disk_file" && analyze_disk_with_lsblk "$disk_file"; then
            log "SUCCESS" "Info test PASSED for Test $total_tests"
        else
            log "ERROR" "Disk info test failed."
            failed_tests=$((failed_tests + 1))
            continue
        fi

        # Test the --reverse option
        log "INFO" "Testing --reverse option..."
        reverse_config="${disk_file%.*}_config.sh"
        if run_command "$SCRIPT_PATH --reverse \"$disk_file\"" "Reverse config generation for $disk_file"; then
            if [[ -f "$reverse_config" ]]; then
                log "SUCCESS" "Reverse config file generated: $reverse_config"
                # Basic validation of the generated config
                if grep -q "DISK_NAME=" "$reverse_config" && \
                   grep -q "DISK_SIZE=" "$reverse_config" && \
                   grep -q "DISK_FORMAT=" "$reverse_config" && \
                   grep -q "PARTITION_TABLE=" "$reverse_config"; then
                    log "SUCCESS" "Reverse config validation PASSED"
                else
                    log "ERROR" "Reverse config validation FAILED: missing variables"
                    failed_tests=$((failed_tests + 1))
                    continue
                fi
            else
                log "ERROR" "Reverse config file not found: $reverse_config"
                failed_tests=$((failed_tests + 1))
                continue
            fi
        else
            log "ERROR" "Reverse config generation failed."
            failed_tests=$((failed_tests + 1))
            continue
        fi

        # If we reach here, the test is fully passed
        log "SUCCESS" "Test $total_tests PASSED"
        passed_tests=$((passed_tests + 1))
    done
    
    # Print a summary of the test results
    echo
    log "INFO" "$(repeat "=" 60)"
    log "INFO" "TEST SUMMARY"
    log "INFO" "Total tests: $total_tests"
    log "SUCCESS" "Passed: $passed_tests"
    if [[ $failed_tests -gt 0 ]]; then
        log "ERROR" "Failed: $failed_tests"
    else
        log "SUCCESS" "Failed: $failed_tests"
    fi
    
    # Return an appropriate exit code
    if [[ $failed_tests -eq 0 ]]; then
        log "SUCCESS" "All tests completed successfully! 🎉"
        return 0
    else
        log "ERROR" "Some tests failed! ❌"
        return 1
    fi
}

# Remove existing log file if it exists
if [[ -f "$LOG_FILE" ]]; then
    rm -f "$LOG_FILE"
fi

# Redirect all output (stdout and stderr) to the log file and terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# Run main function
main "$@"