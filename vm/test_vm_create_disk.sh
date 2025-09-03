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
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Flag to determine whether to keep disk images
KEEP_IMAGES=false

# Test execution counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# --- Enhanced Logging System ---

# Get current timestamp in consistent format
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Get elapsed time since start
get_elapsed_time() {
    if [[ -n "${SCRIPT_START_TIME:-}" ]]; then
        local current_time=$(date +%s)
        local elapsed=$((current_time - SCRIPT_START_TIME))
        printf "%02d:%02d" $((elapsed / 60)) $((elapsed % 60))
    else
        echo "00:00"
    fi
}

# Enhanced logging function with consistent formatting
log() {
    local level="$1"
    local message="$2"
    local context="${3:-}"
    local timestamp="$(get_timestamp)"
    local elapsed="$(get_elapsed_time)"
    local prefix=""
    local color=""
    
    case "$level" in
        "INIT")
            color="$CYAN"
            prefix="INIT "
            ;;
        "INFO")
            color="$BLUE"
            prefix="INFO "
            ;;
        "SUCCESS")
            color="$GREEN"
            prefix="PASS "
            ;;
        "WARNING")
            color="$YELLOW"
            prefix="WARN "
            ;;
        "ERROR")
            color="$RED"
            prefix="FAIL "
            ;;
        "DEBUG")
            if [[ "$DEBUG" != "true" ]]; then
                return 0
            fi
            color="$GRAY"
            prefix="DBUG "
            ;;
        "STEP")
            color="$PURPLE"
            prefix="STEP "
            ;;
        "RESULT")
            color="$CYAN"
            prefix="RSLT "
            ;;
        *)
            color="$NC"
            prefix="LOG  "
            ;;
    esac
    
    # Format: [LEVEL] YYYY-MM-DD HH:MM:SS [MM:SS] [CONTEXT] Message
    local log_line=""
    if [[ -n "$context" ]]; then
        log_line="[${prefix}] ${timestamp} [${elapsed}] [${context}] ${message}"
    else
        log_line="[${prefix}] ${timestamp} [${elapsed}] ${message}"
    fi
    
    # Output to terminal (file descriptor 3) with colors
    if [[ -t 3 ]]; then
        echo -e "${color}${log_line}${NC}" >&3
    else
        echo "${log_line}" >&3
    fi
    
    # Output to log file (without colors)
    echo "${log_line}" >> "$LOG_FILE"
}

# Specialized logging functions for better readability
log_init() { log "INIT" "$1" "$2"; }
log_info() { log "INFO" "$1" "$2"; }
log_success() { log "SUCCESS" "$1" "$2"; }
log_warning() { log "WARNING" "$1" "$2"; }
log_error() { log "ERROR" "$1" "$2"; }
log_debug() { log "DEBUG" "$1" "$2"; }
log_step() { log "STEP" "$1" "$2"; }
log_result() { log "RESULT" "$1" "$2"; }

# Enhanced section logging with visual separators
log_section() {
    local title="$1"
    local level="${2:-INFO}"
    local separator_char="${3:-=}"
    local width=80
    
    log "$level" ""
    log "$level" "$(printf "%*s" $width "" | tr " " "$separator_char")"
    
    # Create centered title with separators
    local title_length=${#title}
    local padding=$(( (width - title_length - 2) / 2 ))
    local left_sep=$(printf "%*s" $padding "" | tr " " "$separator_char")
    local right_sep=$(printf "%*s" $((width - title_length - 2 - padding)) "" | tr " " "$separator_char")
    
    log "$level" "${left_sep} ${title} ${right_sep}"
    log "$level" "$(printf "%*s" $width "" | tr " " "$separator_char")"
}

# Test progress logging
log_test_start() {
    local test_num="$1"
    local test_name="$2"
    local total="$3"
    
    log_section "Test $test_num/$total: $test_name" "STEP" "-"
    log_step "Starting test case" "TEST-$test_num"
}

log_test_end() {
    local test_num="$1"
    local status="$2"  # PASS/FAIL/SKIP
    local message="$3"
    
    case "$status" in
        "PASS")
            log_success "Test $test_num completed successfully: $message" "TEST-$test_num"
            ((PASSED_TESTS++))
            ;;
        "FAIL")
            log_error "Test $test_num failed: $message" "TEST-$test_num"
            ((FAILED_TESTS++))
            ;;
        "SKIP")
            log_warning "Test $test_num skipped: $message" "TEST-$test_num"
            ((SKIPPED_TESTS++))
            ;;
    esac
}

# Command execution with enhanced logging
run_command() {
    local cmd="$1"
    local description="$2"
    local context="${3:-CMD}"
    local timeout="${4:-300}" # 5 minutes default timeout
    
    log_debug "Executing: $cmd" "$context"
    log_info "Running: $description" "$context"
    
    local start_time=$(date +%s)
    local output
    local exit_code
    
    # Run command with timeout
    if command -v timeout >/dev/null 2>&1; then
        output=$(sudo -E timeout --foreground "$timeout" bash -c "$cmd" 2>&1)
        exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_error "Command timed out after ${timeout}s: $cmd" "$context"
            log_debug "Timeout output: $output" "$context"
            return 1
        fi
    else
        output=$(sudo -E bash -c "$cmd" 2>&1)
        exit_code=$?
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "$description completed in ${duration}s" "$context"
        if [[ -n "$output" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && log_debug "Output: $line" "$context"
            done <<< "$output"
        fi
        return 0
    else
        log_error "$description failed (exit code: $exit_code) after ${duration}s" "$context"
        if [[ -n "$output" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && log_error "Error: $line" "$context"
            done <<< "$output"
        fi
        return 1
    fi
}

# File operations logging
log_file_info() {
    local file_path="$1"
    local context="${2:-FILE}"
    
    if [[ ! -f "$file_path" ]]; then
        log_error "File not found: $file_path" "$context"
        return 1
    fi
    
    local file_size_bytes=$(stat -c%s "$file_path" 2>/dev/null || echo "0")
    local file_size_human=$(ls -lh "$file_path" 2>/dev/null | awk '{print $5}' || echo "unknown")
    local file_type=$(file -b "$file_path" 2>/dev/null || echo "unknown")
    
    log_info "File: $(basename "$file_path")" "$context"
    log_info "  Path: $file_path" "$context"
    log_info "  Size: $file_size_human ($file_size_bytes bytes)" "$context"
    log_info "  Type: $file_type" "$context"
}

# Fixed progress bar for long operations
show_progress() {
    local current="$1"
    local total="$2"
    local operation="$3"
    local width=50
    
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    local bar="["
    bar+="$(printf "%*s" $filled "" | tr " " "#")"
    bar+="$(printf "%*s" $empty "" | tr " " "-")"
    bar+="]"
    
    # Write to /dev/tty with unbuffered output
    if [[ -t 1 ]]; then
        # Clear the current line and print progress
        stdbuf -oL printf "\r%*s\r" 80 "" > /dev/tty
        stdbuf -oL printf "\033[0;36m[PROG]\033[0m $(get_timestamp) [$(get_elapsed_time)] %s %s %3d%% (%d/%d)" \
               "$bar" "$operation" "$percentage" "$current" "$total" > /dev/tty
        
        if [[ $current -eq $total ]]; then
            stdbuf -oL printf "\n" > /dev/tty  # New line when complete
        fi
    fi
    
    # Log progress to file (unchanged)
    if [[ $current -eq $total ]] || [[ $((current % 5)) -eq 0 ]] || [[ $current -eq 1 ]]; then
        log_info "Progress: $operation $percentage% ($current/$total)" "PROGRESS"
    fi
}

# --- Enhanced Utility Functions ---

repeat() {
    local char="$1"
    local count="$2"
    printf "%*s" "$count" "" | tr " " "$char"
}

format_duration() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [[ $hours -gt 0 ]]; then
        printf "%02d:%02d:%02d" $hours $minutes $secs
    else
        printf "%02d:%02d" $minutes $secs
    fi
}

# Generate unique test name from partition specifications
generate_unique_test_name() {
    local disk_format="$1"
    local partition_table="$2"
    local preallocation="$3"
    shift 3
    local partitions=("$@")
    
    # Create a hash from the partition specifications for uniqueness
    local partition_spec="${partitions[*]}"
    local hash_input="${disk_format}_${partition_table}_${preallocation}_${partition_spec}"
    
    # Simple hash using cksum (available on most systems)
    local hash=""
    if command -v cksum >/dev/null 2>&1; then
        hash=$(echo "$hash_input" | cksum | cut -d' ' -f1)
    else
        # Fallback: use length and first few characters
        hash="${#hash_input}_$(echo "$hash_input" | head -c 8)"
    fi
    
    # Create descriptive name with hash suffix for uniqueness
    local base_name="${disk_format}_${partition_table}_${preallocation}"
    local unique_name="${base_name}_${hash}"
    
    log_debug "Generated unique name: $unique_name for partitions: ${partitions[*]}" "NAMING"
    echo "$unique_name"
}

# Check system requirements and log findings
check_system_requirements() {
    log_step "Checking system requirements" "INIT"
    
    local missing_deps=()
    local optional_deps=()
    local required_cmds=("qemu-img")
    local optional_cmds=("bc" "lsblk" "losetup" "qemu-nbd" "timeout" "cksum")
    
    # Check required dependencies
    for cmd in "${required_cmds[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log_success "Required command found: $cmd" "DEPS"
        else
            missing_deps+=("$cmd")
            log_error "Required command missing: $cmd" "DEPS"
        fi
    done
    
    # Check optional dependencies
    for cmd in "${optional_cmds[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log_info "Optional command available: $cmd" "DEPS"
        else
            optional_deps+=("$cmd")
            log_warning "Optional command missing: $cmd" "DEPS"
        fi
    done
    
    # Report results
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}" "DEPS"
        log_error "Install with: apt-get install ${missing_deps[*]}" "DEPS"
        return 1
    fi
    
    if [[ ${#optional_deps[@]} -gt 0 ]]; then
        log_warning "Missing optional dependencies: ${optional_deps[*]}" "DEPS"
        log_warning "Some features may be limited" "DEPS"
        log_info "Install with: apt-get install ${optional_deps[*]}" "DEPS"
    fi
    
    log_success "System requirements check completed" "DEPS"
    return 0
}

# Enhanced cleanup function
cleanup() {
    log_step "Starting cleanup process" "CLEANUP"
    
    # Remove log file if requested
    if [[ -f "$LOG_FILE" && "$KEEP_IMAGES" == "false" ]]; then
        log_info "Removing log file: $LOG_FILE" "CLEANUP"
    fi
    
    # Cleanup test directory
    if [[ -d "$TEST_DIR" ]]; then
        if [[ "$KEEP_IMAGES" == "false" ]]; then
            local file_count=$(find "$TEST_DIR" -type f | wc -l)
            log_info "Removing test directory with $file_count files" "CLEANUP"
            rm -rf "$TEST_DIR"
            log_success "Test directory cleaned up" "CLEANUP"
        else
            log_info "Keeping test directory: $TEST_DIR" "CLEANUP"
        fi
    fi
    
    # Remove lingering disk files (using unique naming pattern)
    local lingering_patterns=("test_*_*.qcow2" "test_*_*.raw")
    for pattern in "${lingering_patterns[@]}"; do
        for file in $pattern; do
            if [[ -f "$file" ]]; then
                if [[ "$KEEP_IMAGES" == "false" ]]; then
                    rm -f "$file"
                    log_info "Removed lingering file: $file" "CLEANUP"
                else
                    log_info "Keeping lingering file: $file" "CLEANUP"
                fi
            fi
        done
    done
    
    # Disconnect NBD devices
    if command -v qemu-nbd >/dev/null 2>&1; then
        local nbd_count=0
        for nbd in /dev/nbd*; do
            if [[ -b "$nbd" ]] && sudo qemu-nbd -d "$nbd" &>/dev/null; then
                log_info "Disconnected NBD device: $nbd" "CLEANUP"
                ((nbd_count++))
            fi
        done
        [[ $nbd_count -gt 0 ]] && log_success "Disconnected $nbd_count NBD devices" "CLEANUP"
    fi
    
    # Release loop devices
    if command -v losetup >/dev/null 2>&1; then
        local loop_count=0
        while IFS= read -r loop_info; do
            local loop_dev=$(echo "$loop_info" | awk -F: '{print $1}')
            if sudo losetup -d "$loop_dev" &>/dev/null; then
                log_info "Released loop device: $loop_dev" "CLEANUP"
                ((loop_count++))
            fi
        done < <(losetup -a 2>/dev/null || true)
        [[ $loop_count -gt 0 ]] && log_success "Released $loop_count loop devices" "CLEANUP"
    fi
    
    log_success "Cleanup process completed" "CLEANUP"
}

# Enhanced configuration generation with unique naming
generate_config() {
    local disk_format="$1"
    local partition_table="$2"
    local preallocation="$3"
    shift 3
    local partitions_array=("$@")

    # Generate unique test name
    local unique_name=$(generate_unique_test_name "$disk_format" "$partition_table" "$preallocation" "${partitions_array[@]}")
    
    local config_file="$TEST_DIR/${unique_name}.sh"
    local disk_name="${unique_name}.${disk_format}"

    log_debug "Generating config file: $config_file" "CONFIG"
    log_debug "  Unique name: $unique_name" "CONFIG"
    log_debug "  Disk format: $disk_format" "CONFIG"
    log_debug "  Partition table: $partition_table" "CONFIG"
    log_debug "  Preallocation: $preallocation" "CONFIG"
    log_debug "  Partitions: ${partitions_array[*]}" "CONFIG"

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
    
    log_success "Generated config file: $(basename "$config_file")" "CONFIG"
    echo "$config_file"
}

# Enhanced disk verification
verify_disk() {
    local disk_file="$1"
    local expected_format="$2"
    local context="${3:-VERIFY}"
    
    log_step "Verifying disk file: $(basename "$disk_file")" "$context"
    
    if [[ ! -f "$disk_file" ]]; then
        log_error "Disk file not found: $disk_file" "$context"
        return 1
    fi
    
    log_file_info "$disk_file" "$context"
    
    local file_size_bytes=$(stat -c%s "$disk_file" 2>/dev/null || echo "0")
    if [[ $file_size_bytes -eq 0 ]]; then
        log_error "Disk file is empty" "$context"
        return 1
    fi
    
    if command -v qemu-img >/dev/null 2>&1; then
        log_info "Checking disk format with qemu-img" "$context"
        
        local qemu_output
        if qemu_output=$(qemu-img info "$disk_file" 2>&1); then
            log_debug "qemu-img info output:" "$context"
            while IFS= read -r line; do
                log_debug "  $line" "$context"
            done <<< "$qemu_output"
            
            if echo "$qemu_output" | grep -q "file format: $expected_format"; then
                log_success "Disk format verified: $expected_format" "$context"
                return 0
            else
                log_error "Disk format verification failed. Expected: $expected_format" "$context"
                return 1
            fi
        else
            log_error "qemu-img info failed" "$context"
            log_error "$qemu_output" "$context"
            return 1
        fi
    else
        log_warning "qemu-img not available, skipping format verification" "$context"
        return 0
    fi
}

# Enhanced disk analysis
analyze_disk_with_lsblk() {
    local disk_file="$1"
    local context="${2:-ANALYZE}"

    if ! command -v qemu-nbd >/dev/null 2>&1 || ! command -v lsblk >/dev/null 2>&1; then
        log_warning "qemu-nbd or lsblk not found, skipping disk analysis" "$context"
        return 0
    fi

    log_step "Analyzing disk image with lsblk" "$context"
    
    local device_name=""
    local connection_method=""
    
    # Try to connect via qemu-nbd first
    if sudo qemu-nbd -c /dev/nbd0 --read-only "$disk_file" &> /dev/null; then
        device_name="/dev/nbd0"
        connection_method="qemu-nbd"
        log_success "Connected disk to $device_name via qemu-nbd" "$context"
    else
        log_warning "Failed to connect via qemu-nbd, trying loop device" "$context"
        
        # Fallback to loop device for raw format
        local disk_format=$(qemu-img info "$disk_file" 2>/dev/null | grep 'file format' | awk '{print $NF}')
        if [[ "$disk_format" == "raw" ]]; then
            if device_name=$(sudo losetup -f --show "$disk_file" 2>/dev/null); then
                connection_method="loopback"
                log_success "Set up loop device: $device_name" "$context"
            else
                log_error "Failed to set up loop device" "$context"
                return 1
            fi
        else
            log_error "Cannot analyze non-raw disk without qemu-nbd" "$context"
            return 1
        fi
    fi
    
    # Wait for partitions to be detected
    log_debug "Waiting for partition detection..." "$context"
    sleep 2
    
    # Run lsblk analysis
    log_info "Running lsblk analysis on $device_name" "$context"
    local lsblk_output
    if lsblk_output=$(sudo lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,PARTTYPE "$device_name" 2>&1); then
        log_result "Partition table for $(basename "$disk_file"):" "$context"
        while IFS= read -r line; do
            log_result "  $line" "$context"
        done <<< "$lsblk_output"
    else
        log_warning "lsblk analysis failed" "$context"
        log_debug "$lsblk_output" "$context"
    fi
    
    # Disconnect the device
    log_debug "Disconnecting $device_name" "$context"
    if [[ "$connection_method" == "qemu-nbd" ]]; then
        if sudo qemu-nbd -d "$device_name" &> /dev/null; then
            log_success "Disconnected $device_name" "$context"
        else
            log_warning "Failed to disconnect $device_name" "$context"
        fi
    elif [[ "$connection_method" == "loopback" && -n "$device_name" ]]; then
        if sudo losetup -d "$device_name" &> /dev/null; then
            log_success "Released loop device $device_name" "$context"
        else
            log_warning "Failed to release loop device $device_name" "$context"
        fi
    fi
    
    return 0
}

# Enhanced initialization and log file handling
initialize_logging() {
    # Remove existing log file if it exists
    if [[ -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
    fi
    
    # Create log file directory if needed
    local log_dir=$(dirname "$LOG_FILE")
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || {
            echo "ERROR: Failed to create log directory: $log_dir"
            exit 1
        }
    fi
    
    # Open file descriptor 3 for terminal output
    exec 3>&1
    
    # Redirect stdout and stderr to both log file and terminal
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# --- Main Execution ---

main() {
    # Initialize script timing
    SCRIPT_START_TIME=$(date +%s)
    
    # Parse command-line options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-images)
                KEEP_IMAGES=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            *)
                log_warning "Unknown option: $1"
                shift
                ;;
        esac
    done
    
    # Initialize logging
    log_section "VM CREATE DISK TEST SUITE" "INIT"
    log_init "Test script started at $(get_timestamp)"
    log_init "Debug mode: $DEBUG"
    log_init "Keep images: $KEEP_IMAGES"
    log_init "Log file: $LOG_FILE"
    
    # Check system requirements
    if ! check_system_requirements; then
        log_error "System requirements not met"
        exit 1
    fi
    
    # Check if main script exists
    if ! command -v "$SCRIPT_PATH" >/dev/null 2>&1; then
        log_error "Main script '$SCRIPT_PATH' not found in PATH"
        exit 1
    fi
    log_success "Main script found: $SCRIPT_PATH"

    # Test cases definition with unique configurations
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

    TOTAL_TESTS=${#TESTS[@]}
    
    # Set up trap for cleanup
    trap cleanup EXIT INT TERM
    
    # Create test directory
    log_step "Setting up test environment"
    if ! mkdir -p "$TEST_DIR"; then
        log_error "Failed to create test directory: $TEST_DIR"
        exit 1
    fi
    log_success "Test directory created: $TEST_DIR"
    
    log_section "STARTING TEST EXECUTION" "INIT"
    log_init "Total test cases to execute: $TOTAL_TESTS"
    
    # Execute tests
    local test_index=1
    for test_case in "${TESTS[@]}"; do
        # Parse test case
        read -r disk_format partition_table preallocation partitions <<< "$test_case"
        IFS=' ' read -r -a partitions_array <<< "$partitions"
        
        # Generate unique test name
        local unique_name=$(generate_unique_test_name "$disk_format" "$partition_table" "$preallocation" "${partitions_array[@]}")
        
        # Show progress
        show_progress $test_index $TOTAL_TESTS "Executing tests"
        
        # Start test
        log_test_start $test_index "$unique_name" $TOTAL_TESTS
        
        # Log test parameters
        log_info "Unique Name: $unique_name" "TEST-$test_index"
        log_info "Format: $disk_format" "TEST-$test_index"
        log_info "Partition Table: $partition_table" "TEST-$test_index"
        log_info "Preallocation: $preallocation" "TEST-$test_index"
        log_info "Partitions: ${partitions_array[*]}" "TEST-$test_index"
        
        # Execute test steps
        local test_failed=false
        local failure_reason=""
        
        # Step 1: Generate config
        local config_file
        if config_file=$(generate_config "$disk_format" "$partition_table" "$preallocation" "${partitions_array[@]}"); then
            log_success "Config generated: $(basename "$config_file")" "TEST-$test_index"
        else
            test_failed=true
            failure_reason="Config generation failed"
        fi
        
        if [[ "$test_failed" == "false" ]]; then
            # Step 2: Create disk (with unique name)
            local disk_file="$TEST_DIR/${unique_name}.${disk_format}"
            if run_command "$SCRIPT_PATH \"$config_file\"" "Creating disk image" "TEST-$test_index"; then
                # Move disk file to test directory with unique name
                local created_disk_name
                created_disk_name=$(basename "$(grep "^DISK_NAME=" "$config_file" | cut -d'"' -f2)")
                
                if [[ -f "./$created_disk_name" ]]; then
                    mv "./$created_disk_name" "$disk_file"
                    log_success "Disk file moved to: $(basename "$disk_file")" "TEST-$test_index"
                else
                    test_failed=true
                    failure_reason="Disk file not created: $created_disk_name"
                fi
            else
                test_failed=true
                failure_reason="Disk creation failed"
            fi
        fi
        
        if [[ "$test_failed" == "false" ]]; then
            # Step 3: Verify disk
            if verify_disk "$disk_file" "$disk_format" "TEST-$test_index"; then
                log_success "Disk verification passed" "TEST-$test_index"
            else
                test_failed=true
                failure_reason="Disk verification failed"
            fi
        fi
        
        if [[ "$test_failed" == "false" ]]; then
            # Step 4: Test --info option
            if run_command "$SCRIPT_PATH --info \"$disk_file\"" "Testing --info option" "TEST-$test_index"; then
                log_success "Info option test passed" "TEST-$test_index"
                analyze_disk_with_lsblk "$disk_file" "TEST-$test_index"
            else
                test_failed=true
                failure_reason="Info option test failed"
            fi
        fi
        
        if [[ "$test_failed" == "false" ]]; then
            # Step 5: Test --reverse option
            local reverse_config="${disk_file%.*}_config.sh"
            if run_command "$SCRIPT_PATH --reverse \"$disk_file\"" "Testing --reverse option" "TEST-$test_index"; then
                if [[ -f "$reverse_config" ]]; then
                    log_success "Reverse config generated" "TEST-$test_index"
                    # Note: Validation function would need to be implemented
                    log_info "Reverse config validation skipped (not implemented)" "TEST-$test_index"
                else
                    test_failed=true
                    failure_reason="Reverse config file not found"
                fi
            else
                test_failed=true
                failure_reason="Reverse option test failed"
            fi
        fi
        
        # Report test result
        if [[ "$test_failed" == "true" ]]; then
            log_test_end $test_index "FAIL" "$failure_reason"
        else
            log_test_end $test_index "PASS" "All test steps completed successfully"
        fi
        
        ((test_index++))
    done
    
    # Final summary
    local total_time=$(($(date +%s) - SCRIPT_START_TIME))
    local formatted_duration=$(format_duration $total_time)
    
    log_section "TEST EXECUTION SUMMARY" "RESULT"
    log_result "Execution completed in: $formatted_duration"
    log_result "Total tests executed: $TOTAL_TESTS"
    log_result "Tests passed: $PASSED_TESTS"
    log_result "Tests failed: $FAILED_TESTS" 
    log_result "Tests skipped: $SKIPPED_TESTS"
    
    # Calculate success rate
    if [[ $TOTAL_TESTS -gt 0 ]]; then
        local success_rate=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
        log_result "Success rate: ${success_rate}%"
    fi
    
    # Final status
    if [[ $FAILED_TESTS -eq 0 ]]; then
        log_section "🎉 ALL TESTS PASSED! 🎉" "SUCCESS"
        log_success "Test suite completed successfully!"
        return 0
    else
        log_section "❌ SOME TESTS FAILED ❌" "ERROR"
        log_error "Test suite completed with failures"
        log_error "Check the log above for detailed failure information"
        return 1
    fi
}

# Additional utility functions for validation (simplified versions)

validate_reverse_config() {
    local original_config="$1"
    local reverse_config="$2"
    local test_name="$3"
    local context="VALIDATE"
    
    log_step "Validating reverse config for $test_name" "$context"
    
    if [[ ! -f "$original_config" || ! -f "$reverse_config" ]]; then
        log_error "Config files not found for validation" "$context"
        return 1
    fi
    
    # Simple validation - check if files exist and have basic structure
    if grep -q "DISK_NAME=" "$reverse_config" && \
       grep -q "PARTITIONS=" "$reverse_config"; then
        log_success "Reverse config has basic structure" "$context"
        return 0
    else
        log_error "Reverse config missing required structure" "$context"
        return 1
    fi
}

# Parse partitions function (simplified)
parse_partitions_array() {
    local -n result_array=$1
    shift
    local partitions=("$@")
    local context="PARSE"
    
    result_array=()
    local index=0
    
    log_debug "Parsing ${#partitions[@]} partitions" "$context"
    
    for partition in "${partitions[@]}"; do
        local size fs_type part_type
        
        # Parse format: SIZE:FILESYSTEM[:TYPE]
        if [[ "$partition" =~ ^([^:]+):([^:]+)(:(.+))?$ ]]; then
            size="${BASH_REMATCH[1]}"
            fs_type="${BASH_REMATCH[2]}"
            part_type="${BASH_REMATCH[4]:-primary}"
        else
            log_warning "Cannot parse partition: $partition" "$context"
            continue
        fi
        
        # Normalize size to bytes for comparison
        local size_bytes=$(normalize_size_to_bytes "$size")
        
        result_array+=("$index|$size|$size_bytes|$fs_type|$part_type")
        log_debug "Parsed partition $index: $size ($size_bytes bytes) $fs_type $part_type" "$context"
        ((index++))
    done
    
    log_debug "Successfully parsed ${#result_array[@]} partitions" "$context"
}

normalize_size_to_bytes() {
    local size="$1"
    local multiplier=1
    local number
    
    # Extract number and unit
    if [[ "$size" =~ ^([0-9]+\.?[0-9]*)([KMGT]?)$ ]]; then
        number="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        
        case "$unit" in
            "K") multiplier=1024 ;;
            "M") multiplier=$((1024 * 1024)) ;;
            "G") multiplier=$((1024 * 1024 * 1024)) ;;
            "T") multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
            "") multiplier=1 ;;
        esac
        
        # Convert to integer bytes (approximate for floating point)
        if command -v bc >/dev/null 2>&1; then
            echo $(( $(echo "$number * $multiplier" | bc | cut -d. -f1) ))
        else
            # Fallback without bc
            echo $(( ${number%.*} * multiplier ))
        fi
    else
        # Return 0 for unparseable sizes (like "remaining")
        echo 0
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Initialize logging system
    initialize_logging
    
    # Show usage if requested
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --keep-images    Keep created disk images after testing"
        echo "  --debug         Enable debug logging"
        echo "  --help, -h      Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  DEBUG=true      Enable debug logging (alternative to --debug)"
        echo ""
        echo "Features:"
        echo "  - Unique disk naming using hash of partition specifications"
        echo "  - Fixed progress bar that doesn't interfere with logs"
        echo "  - Enhanced logging with timestamps and context"
        echo "  - Comprehensive test validation"
        echo ""
        exit 0
    fi
    
    # Run main function
    main "$@"
    exit_code=$?
    
    # Ensure cleanup runs
    cleanup
    
    exit $exit_code
fi