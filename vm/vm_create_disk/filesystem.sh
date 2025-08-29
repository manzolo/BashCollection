# Function to normalize filesystem type
normalize_fs_type() {
    local fs="$1"
    local type="$2"
    local name="$3"
    case "$fs" in
        "linux-swap(v1)"|"linux-swap") echo "swap" ;;
        "vfat"|"fat32") echo "fat32" ;;
        "fat16") echo "fat16" ;;
        "ntfs") echo "ntfs" ;;
        "ext4") echo "ext4" ;;
        "ext3") echo "ext3" ;;
        "xfs") echo "xfs" ;;
        "btrfs") echo "btrfs" ;;
        *)
            if [[ "$name" =~ "Microsoft reserved" || "$type" == "msr" ]]; then
                echo "msr"
            else
                echo "none"
            fi
            ;;
    esac
}