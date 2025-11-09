# Disk Cloner

Advanced disk cloning tool supporting physical and virtual disk formats with intelligent space usage.

## Available Scripts

### manzolo-disk-clone

Professional disk cloning solution with support for multiple source/destination combinations and advanced features.

**Features:**
- Smart cloning (copies only used space using partclone)
- Multiple cloning modes:
  - Virtual to Physical
  - Physical to Virtual
  - Virtual to Virtual (with compression)
  - Physical to Physical (simple)
  - Physical to Physical (with UUID preservation)
- LUKS encryption support
- UUID preservation for filesystems and partitions
- GPT and MBR partition table support
- Proportional partition resizing
- Dry-run mode for testing
- NBD (Network Block Device) support for virtual images
- Interactive dialog-based TUI

**Usage:**
```bash
sudo manzolo-disk-clone
```

**Cloning Modes:**

1. **Virtual to Physical (📦 → 📼)**
   - Clone qcow2/vdi/vmdk images to physical disks
   - Supports NBD mounting of virtual images
   - Automatic partition detection

2. **Physical to Virtual (📼 → 📦)**
   - Create virtual disk images from physical disks
   - Output formats: qcow2, vdi, vmdk, raw
   - Optional compression

3. **Virtual to Virtual (💿 → 📦)**
   - Convert between virtual disk formats
   - Compression and optimization
   - Format conversion

4. **Physical to Physical - Simple (📼 → 📼)**
   - Direct block-level copy
   - Fast cloning
   - No UUID preservation

5. **Physical to Physical - UUID Preservation (📼 → 📼)**
   - Maintains partition and filesystem UUIDs
   - LUKS support
   - Proportional resizing
   - Ideal for bootable system clones

**Supported Formats:**
- **Virtual Images**: qcow2, vdi, vmdk, raw/img
- **Physical**: Any block device (/dev/sdX, /dev/nvmeXnY)
- **Filesystems**: ext2, ext3, ext4, btrfs, xfs, NTFS, FAT32
- **Encryption**: LUKS/dm-crypt

**Requirements:**
- Root privileges
- dialog (TUI interface)
- partclone (smart cloning)
- qemu-utils (virtual disk support)
- parted (partition management)
- cryptsetup (LUKS support, optional)
- lvm2 (LVM support, optional)
- pv (progress monitoring, optional)

**Installation of Dependencies:**
```bash
sudo apt install dialog partclone qemu-utils parted cryptsetup lvm2 pv
```

**Dry-Run Mode:**
Enable dry-run mode to test operations without making changes:
```bash
# Edit the script and set DRY_RUN=true
# Or launch and select dry-run mode from settings
```

**Safety Features:**
- Dry-run mode for testing
- Confirmation prompts
- Automatic cleanup on errors
- Logging to /tmp

**Example Scenarios:**

**Clone VM disk to physical disk:**
```bash
sudo manzolo-disk-clone
# Select option 1: Virtual to Physical
# Choose source: /path/to/vm.qcow2
# Choose destination: /dev/sdb
```

**Create virtual image from physical disk:**
```bash
sudo manzolo-disk-clone
# Select option 2: Physical to Virtual
# Choose source: /dev/sda
# Choose destination: /path/to/backup.qcow2
```

**Clone physical disk with UUID preservation:**
```bash
sudo manzolo-disk-clone
# Select option 5: Physical to Physical (UUID Preservation)
# Choose source: /dev/sda
# Choose destination: /dev/sdb
```

**Technical Details:**

**Modular Architecture:**
The script uses a modular design, sourcing helper modules from the `manzolo-disk-clone/` subdirectory:
- `common.sh`: Common functions and utilities
- `nbd.sh`: NBD device management
- `partition.sh`: Partition operations
- `clone.sh`: Cloning operations
- `ui.sh`: Dialog interface helpers

**NBD Usage:**
Virtual disk images are mounted as block devices using qemu-nbd:
```bash
qemu-nbd --connect=/dev/nbd0 image.qcow2
# Perform operations on /dev/nbd0
qemu-nbd --disconnect /dev/nbd0
```

**UUID Preservation:**
When cloning with UUID preservation, the tool:
1. Reads original partition and filesystem UUIDs
2. Clones partitions with partclone
3. Restores UUIDs on destination
4. Handles LUKS headers and keys

**Logs:**
Operation logs are stored in `/tmp/manzolo_clone_*`
