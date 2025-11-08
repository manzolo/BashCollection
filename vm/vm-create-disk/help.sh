# Show help
show_help() {
    cat << EOF
Virtual Disk Creator - Enhanced Edition

Usage:
  $0                      Start in interactive mode
  $0 <config_file>        Use configuration file
  $0 --reverse <disk_image> Generate config.sh from an existing disk image
  $0 --info <disk_image>  Print disk information, partition table type, and partitions in a nice format
  $0 -h, --help           Show this help
  VERBOSE=1 $0            Enable verbose output for debugging

Features:
  - UEFI (GPT) and Legacy BIOS (MBR) support
  - Multiple disk formats (qcow2, raw)
  - Fixed/sparse disk allocation
  - Multiple filesystem support (ext4, ext3, xfs, btrfs, ntfs, fat16, vfat, fat32, none)
  - Linux swap partition support
  - MBR partition type support (primary, extended, logical)
  - Interactive and configuration file modes
  - Verbose mode for detailed command output (set VERBOSE=1)
  - Displays final partition table in a tabular format after creation
  - Generate config.sh from an existing disk image (--reverse)
  - Print disk information in a nice format (--info)

Configuration file example (GPT):
  DISK_NAME="example.qcow2"
  DISK_SIZE="10G"
  DISK_FORMAT="qcow2"
  PARTITION_TABLE="gpt"
  PREALLOCATION="off"
  PARTITIONS=(
      "2G:ext4"
      "1G:swap"
      "500M:fat32"
      "remaining:vfat"
  )

Configuration file example (MBR):
  DISK_NAME="example.qcow2"
  DISK_SIZE="10G"
  DISK_FORMAT="qcow2"
  PARTITION_TABLE="mbr"
  PREALLOCATION="off"
  PARTITIONS=(
      "2G:ext4:primary"
      "1G:swap:primary"
      "500M:fat32:primary"
      "remaining:none:extended"
  )

EOF
}