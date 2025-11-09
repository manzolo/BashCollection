# QEMU Utilities

Utilities for managing QEMU disk images and virtual machines.

## Available Scripts

### compress-qemu-hd-folder

Batch compression tool for QEMU disk images in a directory. Converts and compresses qcow2, vdi, vmdk, and raw images.

**Features:**
- Batch processing of entire directories
- Support for multiple disk formats (qcow2, vdi, vmdk, raw/img)
- Compression using qemu-img with -c flag
- Optional deletion of original files after compression
- Progress tracking
- Recursive directory scanning
- Error handling

**Usage:**
```bash
# Compress all images in a directory (keep originals)
compress-qemu-hd-folder /path/to/vm/images

# Compress and delete originals
compress-qemu-hd-folder /path/to/vm/images --delete

# Show help
compress-qemu-hd-folder --help
```

**Parameters:**
- `directory`: Path to directory containing disk images (required)
- `--delete`: Delete original files after successful compression (optional)

**Supported Formats:**
- **.qcow2**: QEMU Copy-On-Write version 2
- **.vdi**: VirtualBox Disk Image
- **.vmdk**: VMware Virtual Machine Disk
- **.img/.raw**: Raw disk images

**Example:**
```bash
# Before compression:
/vm/images/
├── ubuntu.qcow2 (10 GB)
├── windows.vdi (15 GB)
└── debian.vmdk (8 GB)

# Run compression
sudo compress-qemu-hd-folder /vm/images

# After compression:
/vm/images/
├── ubuntu.qcow2 (10 GB)
├── ubuntu_compressed.qcow2 (4 GB)
├── windows.vdi (15 GB)
├── windows_compressed.qcow2 (6 GB)
├── debian.vmdk (8 GB)
└── debian_compressed.qcow2 (3 GB)

# Run with --delete flag to remove originals
sudo compress-qemu-hd-folder /vm/images --delete

# After compression with delete:
/vm/images/
├── ubuntu_compressed.qcow2 (4 GB)
├── windows_compressed.qcow2 (6 GB)
└── debian_compressed.qcow2 (3 GB)
```

**How It Works:**
1. Scans the specified directory for supported disk image formats
2. For each image found:
   - Creates a compressed qcow2 version with `_compressed` suffix
   - Uses `qemu-img convert -c -O qcow2 -p` for compression
   - Shows progress during conversion
3. Optionally deletes original files if `--delete` flag is used

**Requirements:**
- qemu-utils (qemu-img command)

**Installation of Dependencies:**
```bash
sudo apt install qemu-utils
```

**Compression Details:**
The script uses QEMU's built-in compression (`-c` flag) which:
- Compresses data blocks in the qcow2 format
- Significantly reduces disk space usage
- Slightly impacts I/O performance (negligible for most use cases)
- Creates fully compatible qcow2 images

**Benefits:**
- Save disk space (typically 40-70% reduction)
- Convert various formats to standardized qcow2
- Batch process multiple images automatically
- Safe operation (creates new files before deleting originals)

**Safety Features:**
- Creates compressed copy before touching originals
- Only deletes originals if explicitly requested with `--delete`
- Verifies qemu-img is installed before processing
- Error handling for missing files
- Validates successful compression before deletion

**Performance:**
Compression time depends on:
- Image size
- Amount of actual data (sparse images compress faster)
- Disk I/O speed
- CPU performance

Typical compression speeds: 50-200 MB/s

**Tips:**
- Run without `--delete` first to verify results
- Ensure sufficient disk space (need space for both original and compressed)
- Consider running during off-hours for large batches
- Compressed images are still fully functional and bootable
- No need to decompress - QEMU handles compression transparently
