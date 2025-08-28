#!/bin/bash

# Test script for vm_create_disk.sh
# Generates a matrix of disk configurations, creates disks, and verifies with --info

# --- Configuration ---
# Set to 'true' to enable debug logging
DEBUG=${DEBUG:-false}

# Directory to store config files and disks
TEST_DIR="test_disks"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    
    # Check if the command exists before trying to run it
    if ! eval "$cmd"; then
        log "ERROR" "$description failed with exit code $?"
        return 1
    else
        log "SUCCESS" "$description completed successfully"
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

# Function to clean up test directory
cleanup() {
    log "INFO" "Cleaning up test directory..."
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
        log "SUCCESS" "Test directory cleaned up."
    fi
    # Also remove any disk files created in the current directory
    log "DEBUG" "Removing lingering disk files."
    rm -f test_*.{qcow2,raw,vmdk}
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
    
    local file_size=$(stat -c%s "$disk_file")
    log "DEBUG" "Disk file size: $file_size bytes"
    
    if [[ $file_size -eq 0 ]]; then
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

# --- Main Execution ---

main() {
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    
    # List of expanded test cases (matrix: format, partition_table, preallocation, partitions)
    declare -a TESTS=(
        "qcow2 gpt off 2G:ext4 1G:swap 1G:fat32"
        "qcow2 gpt metadata 2G:ext4 2G:swap 2G:btrfs"
        "qcow2 gpt full 5G:ntfs remaining:ext4"
        "qcow2 mbr off 4G:ext4 2G:fat32 1G:ntfs"
        "qcow2 mbr metadata 3G:xfs 3G:ext4 remaining:swap"
        "qcow2 mbr full 5G:ntfs 1G:fat32 1G:ext4"
        "raw gpt off 1G:ext4 1G:ext3 1G:fat16 remaining:swap"
        "raw gpt full 2G:btrfs 2G:xfs 2G:ntfs"
        "raw mbr off 5G:ntfs remaining:ext4"
        "raw mbr full 3G:xfs 2G:ntfs remaining:vfat"
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
        
        # Define disk file path
        disk_file="$TEST_DIR/test_${disk_format}_${partition_table}_${preallocation}.${disk_format}"
        
        # Run the vm_create_disk utility
        if run_command "vm_create_disk \"$config_file\"" "Disk creation for $disk_format disk"; then
            
            # Check for the existence of the created file
            if [[ -f "./test_${disk_format}_${partition_table}_${preallocation}.${disk_format}" ]]; then
                # Move the disk file to the test directory for verification
                mv "test_${disk_format}_${partition_table}_${preallocation}.${disk_format}" "$disk_file" 2>/dev/null
                
                # Verify the created disk and test the --info option
                if verify_disk "$disk_file" "$disk_format"; then
                    log "INFO" "Testing --info option..."
                    if run_command "vm_create_disk --info \"$disk_file\"" "Disk info for $disk_file"; then
                        log "SUCCESS" "Test $total_tests PASSED"
                        passed_tests=$((passed_tests + 1))
                    else
                        log "ERROR" "Disk info test failed."
                        failed_tests=$((failed_tests + 1))
                    fi
                else
                    log "ERROR" "Disk verification failed."
                    failed_tests=$((failed_tests + 1))
                fi
            else
                log "ERROR" "Disk file not created by vm_create_disk."
                failed_tests=$((failed_tests + 1))
            fi
        else
            log "ERROR" "Disk creation failed."
            failed_tests=$((failed_tests + 1))
        fi
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

# Run main function
main "$@"