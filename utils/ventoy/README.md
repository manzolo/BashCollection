# USB Boot Tester (usb-boot-test)

Interactive QEMU-based tool for testing bootable USB drives and disk images without rebooting your system.

## Overview

**usb-boot-test** (formerly `ventoy-usb-test`) is a comprehensive TUI tool for testing bootable USB devices and disk images in a QEMU virtual machine. While originally designed for Ventoy USB drives, it works with **any bootable media** including Ubuntu ISOs, Windows installers, rescue disks, and more.

## Why Use This Tool?

Testing bootable USB drives typically requires:
- Rebooting your computer
- Changing BIOS settings
- Risk of data loss if wrong device selected
- Time-consuming process

**This tool eliminates all those issues** by:
- Testing in a safe QEMU virtual machine
- No reboot required
- Quick configuration changes
- Support for both UEFI and BIOS modes
- Saves your time and system state

## Features

### Boot Mode Testing
- **UEFI Boot**: Modern UEFI boot with OVMF firmware
- **BIOS/Legacy Boot**: Traditional MBR/BIOS boot
- **Dual Mode Test**: Test both UEFI and BIOS in sequence
- **Auto-Detection**: Automatically detects boot mode from disk partitions

### Media Support
- **Physical USB Devices**: Test /dev/sdb, /dev/sdc, etc.
- **Disk Images**: Support for qcow2, raw, img, iso formats
- **Ventoy USB**: Optimized for Ventoy multi-boot USB drives
- **Any Bootable Media**: Ubuntu, Windows, rescue disks, etc.

### System Configuration
- **RAM Allocation**: Configure memory (512MB to 8GB+)
- **CPU Settings**: Cores, threads, sockets configuration
- **VGA Modes**: virtio, std, qxl, vmware, cirrus
- **USB Version**: USB 2.0, 3.0 support
- **Network Emulation**: Optional network device
- **Sound Emulation**: Optional audio device

### Advanced Features
- **Format Detection**: Automatic detection of disk format
- **OVMF Management**: Automatic OVMF firmware detection and installation
- **Configuration Profiles**: Save and load test configurations
- **Diagnostic Tools**: System verification and troubleshooting
- **KVM Acceleration**: Hardware acceleration when available
- **QEMU Monitor**: Telnet access on port 4444
- **Detailed Logging**: Logs saved to /tmp/ventoy_test_logs

### User Experience
- **Interactive TUI**: Beautiful whiptail-based interface with emojis
- **File Browser**: Easy disk/image selection
- **Real-time Validation**: Immediate feedback on configurations
- **Help System**: Built-in guide and documentation
- **Safe Defaults**: Sensible default values

## Usage

### Basic Usage

```bash
# Interactive mode (recommended)
sudo usb-boot-test

# Legacy command (still works)
sudo ventoy-usb-test
```

### Quick Start Guide

1. **Launch the tool**
   ```bash
   sudo usb-boot-test
   ```

2. **Select your media**
   - Choose option 1: "Disk/USB"
   - Select either:
     - Physical USB device (/dev/sdb, etc.)
     - Disk image file (.iso, .img, .qcow2, etc.)

3. **Configure boot mode**
   - Choose option 2: "Boot"
   - Select UEFI or BIOS
   - Or use "Auto" for automatic detection

4. **Start the test**
   - Choose option 7: "START SINGLE TEST!"
   - Or option 8: "DUAL TEST (UEFI+BIOS)" to test both modes

5. **Use the booted system**
   - Test your bootable media
   - Ctrl+Alt+G to release mouse
   - Ctrl+C to exit when done

### Menu Options

#### 1. Disk/USB Selection
- Browse for USB devices
- Select disk image files
- Shows device size and information
- Validates selected media

#### 2. Boot Mode Configuration
- **UEFI**: Modern UEFI boot (requires OVMF)
- **BIOS**: Legacy BIOS/MBR boot
- **Auto**: Detect from partition table
- Firmware validation and status

#### 3. System Configuration
- **Memory**: 512MB to 8GB+ RAM
- **CPU Cores**: 1-16 cores
- **CPU Threads**: 1-2 per core
- **CPU Sockets**: 1-4 sockets

#### 4. Advanced Settings
- **VGA Mode**: Graphics adapter type
  - virtio (recommended for Linux)
  - std (standard VGA)
  - qxl (for SPICE)
  - vmware (VMware compatibility)
  - cirrus (legacy)
- **USB Version**: 2.0 or 3.0
- **Network**: Enable/disable network adapter
- **Sound**: Enable/disable audio device
- **Machine Type**: pc or q35

#### 5. Diagnostics & System Info
- Verify QEMU installation
- Check OVMF firmware
- Test KVM acceleration
- View system information
- Disk format detection

#### 6. Configuration Management
- Save current configuration
- Load saved configurations
- Export/import settings
- Reset to defaults

#### 7. START SINGLE TEST
- Launches QEMU with current settings
- Tests in selected boot mode
- Shows QEMU command used

#### 8. DUAL TEST (UEFI+BIOS)
- Tests UEFI mode first
- Then tests BIOS mode
- Useful for multi-mode media validation

#### 9. Help
- User guide
- QEMU controls
- Troubleshooting tips
- Keyboard shortcuts

## Common Use Cases

### 1. Test Ventoy USB Drive

**Scenario**: Created a Ventoy USB with multiple ISOs, want to verify it boots.

```bash
sudo usb-boot-test

# In menu:
# 1. Select Disk/USB → Choose /dev/sdb (your Ventoy USB)
# 2. Select Boot → Choose "UEFI" or "Auto"
# 3. START SINGLE TEST
# 4. Verify Ventoy menu appears and ISOs are listed
```

### 2. Test Ubuntu ISO Before Burning to USB

**Scenario**: Downloaded Ubuntu ISO, want to test before creating bootable USB.

```bash
sudo usb-boot-test

# In menu:
# 1. Select Disk/USB → Browse to ubuntu-22.04.iso
# 2. Boot mode will auto-detect
# 3. START SINGLE TEST
# 4. Test Ubuntu live environment
```

### 3. Verify UEFI and BIOS Compatibility

**Scenario**: Created bootable media that should work on both old and new computers.

```bash
sudo usb-boot-test

# In menu:
# 1. Select your USB device or ISO
# 2. Choose DUAL TEST (UEFI+BIOS)
# 3. First UEFI window opens → test it
# 4. Close it → BIOS window opens → test it
# 5. Verify both modes work correctly
```

### 4. Test Windows Installer USB

**Scenario**: Created Windows 10/11 bootable USB, need to verify.

```bash
sudo usb-boot-test

# In menu:
# 1. Select Disk/USB → Your Windows USB
# 2. Select Boot → UEFI (Windows 10/11 prefers UEFI)
# 3. System → Increase RAM to 4096MB
# 4. START SINGLE TEST
# 5. Verify Windows installer starts
```

### 5. Test with Different Hardware Configurations

**Scenario**: Need to test how USB boots with different RAM/CPU settings.

```bash
sudo usb-boot-test

# Test 1: Low-end system
# System → RAM: 1024MB, CPU: 1 core
# START SINGLE TEST

# Test 2: High-end system
# System → RAM: 8192MB, CPU: 4 cores
# START SINGLE TEST
```

### 6. Debug Boot Problems

**Scenario**: USB won't boot on some computers, need to troubleshoot.

```bash
sudo usb-boot-test

# In menu:
# 1. Diagnostics → Run all checks
# 2. Check disk format detection
# 3. Try different boot modes
# 4. Try different VGA modes
# 5. Check logs in /tmp/ventoy_test_logs
```

## Requirements

### Required
- bash >= 4.0
- qemu-system-x86 (QEMU virtualization)
- Root/sudo privileges

### Recommended
- ovmf (UEFI firmware for QEMU)
- whiptail (TUI interface)
- KVM kernel module (hardware acceleration)

### Optional
- telnet (QEMU monitor access)

### Installation of Dependencies

```bash
# Ubuntu/Debian
sudo apt install qemu-system-x86 ovmf whiptail

# Fedora/RHEL
sudo dnf install qemu-system-x86 edk2-ovmf newt

# Arch Linux
sudo pacman -S qemu ovmf newt
```

### Enable KVM (for acceleration)

```bash
# Check if KVM is available
lsmod | grep kvm

# If not loaded, load the module
sudo modprobe kvm
sudo modprobe kvm_intel  # For Intel CPUs
# OR
sudo modprobe kvm_amd    # For AMD CPUs

# Add user to kvm group (optional)
sudo usermod -aG kvm $USER
```

## OVMF Firmware

UEFI boot requires OVMF firmware. The script will:
1. Auto-detect OVMF in common locations
2. Offer to install if not found
3. Provide manual installation instructions

**Common OVMF locations**:
- `/usr/share/OVMF/OVMF.fd`
- `/usr/share/ovmf/OVMF.fd`
- `/usr/share/edk2-ovmf/x64/OVMF.fd`
- `/usr/share/qemu/OVMF.fd`

**Manual installation**:
```bash
# Ubuntu/Debian
sudo apt install ovmf

# Fedora/RHEL
sudo dnf install edk2-ovmf

# Arch
sudo pacman -S edk2-ovmf
```

## Configuration Files

### Save Configuration

Configurations are saved to `~/.ventoy_test_config` with:
- Last used disk/USB
- Boot mode preference
- RAM and CPU settings
- VGA and USB settings
- Network and sound preferences

### Manual Configuration

You can edit `~/.ventoy_test_config` directly:

```bash
DISK="/dev/sdb"
BIOS_MODE="uefi"
MEMORY="2048"
CORES="4"
VGA_MODE="virtio"
USB_VERSION="3.0"
NETWORK=true
SOUND=false
```

## QEMU Controls

When the virtual machine is running:

| Key Combination | Action |
|----------------|--------|
| Ctrl+Alt+G | Release mouse from VM window |
| Ctrl+Alt+F | Toggle fullscreen |
| Ctrl+C | Terminate emulation |
| Ctrl+Alt+1 | Switch to VGA display |
| Ctrl+Alt+2 | Switch to QEMU monitor |

### QEMU Monitor

Access the QEMU monitor via telnet:

```bash
telnet localhost 4444
```

**Useful commands**:
- `info status` - VM status
- `info registers` - CPU registers
- `info block` - Block devices
- `savevm snapshot1` - Save snapshot
- `loadvm snapshot1` - Load snapshot
- `quit` - Exit QEMU

## Format Detection

The tool automatically detects:
- **Disk Format**: raw, qcow2, vdi, vmdk, vhdx
- **Partition Table**: GPT, MBR, hybrid
- **Boot Partitions**: EFI System Partition, BIOS boot
- **File Systems**: FAT32, NTFS, ext4, etc.

## Modular Architecture

The script uses a modular design:

```
utils/ventoy/
├── ventoy-usb-test.sh          # Main script
└── ventoy-usb-test/            # Helper modules
    ├── cache.sh                # Configuration caching
    ├── checks.sh               # System checks
    ├── config.sh               # Configuration management
    ├── dependencies.sh         # Dependency verification
    ├── detect.sh               # Device/format detection
    ├── format-detection.sh     # Advanced format detection
    ├── log.sh                  # Logging functions
    ├── menu.sh                 # TUI menus
    ├── omvf.sh                 # OVMF management
    ├── qemu.sh                 # QEMU command building
    └── utils.sh                # Utility functions
```

## Troubleshooting

### OVMF firmware not found

**Problem**: UEFI mode fails with "OVMF not found".

**Solution**:
```bash
# Install OVMF
sudo apt install ovmf

# Or specify custom path in Diagnostics menu
```

### KVM not available

**Problem**: Warning about KVM acceleration.

**Solution**:
```bash
# Check virtualization support
egrep -c '(vmx|svm)' /proc/cpuinfo
# Should be > 0

# Load KVM module
sudo modprobe kvm_intel  # or kvm_amd

# Check if loaded
lsmod | grep kvm
```

### Permission denied on /dev/kvm

**Problem**: Cannot access KVM device.

**Solution**:
```bash
# Fix permissions
sudo chmod 666 /dev/kvm

# Or add user to kvm group
sudo usermod -aG kvm $USER
# Log out and back in
```

### USB device busy

**Problem**: Selected USB is in use.

**Solution**:
```bash
# Unmount all partitions
sudo umount /dev/sdb*

# Or select a different device
```

### Disk image not bootable

**Problem**: QEMU shows "No bootable device".

**Solution**:
1. Check if ISO/image is actually bootable
2. Try different boot mode (UEFI vs BIOS)
3. Run Diagnostics → Disk format detection
4. Verify partition table with: `sudo fdisk -l /path/to/image`

### Black screen on boot

**Problem**: QEMU window is black.

**Solution**:
1. Wait 30 seconds (may be loading)
2. Try different VGA mode (Advanced → VGA Mode)
3. Check QEMU monitor (telnet localhost 4444)
4. Increase RAM if low

### Very slow performance

**Problem**: VM is extremely slow.

**Solution**:
1. Enable KVM acceleration (see above)
2. Increase CPU cores
3. Increase RAM
4. Use virtio VGA mode
5. Close other applications

## Advanced Usage

### Custom QEMU Parameters

The tool builds QEMU commands that look like:

```bash
qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -smp cores=4,threads=1,sockets=1 \
    -machine q35 \
    -bios /usr/share/OVMF/OVMF.fd \
    -drive file=/dev/sdb,format=raw,if=none,id=usb1 \
    -device usb-storage,drive=usb1 \
    -vga virtio \
    -monitor telnet:localhost:4444,server,nowait
```

### Testing Multiple USB Devices

```bash
# Test each USB drive sequentially
for usb in /dev/sdb /dev/sdc /dev/sdd; do
    echo "Testing $usb..."
    # Select device in menu and test
done
```

### Automated Testing (Advanced)

For scripting, you can configure then run:

```bash
# Set up config file
cat > ~/.ventoy_test_config << EOF
DISK="/dev/sdb"
BIOS_MODE="uefi"
MEMORY="2048"
CORES="2"
EOF

# Run with saved config
sudo usb-boot-test
```

## Safety Features

- **Read-Only Access**: USB devices are opened read-only by default
- **No Write Risk**: Testing doesn't modify your bootable media
- **Isolated Environment**: Runs in safe QEMU VM
- **Validation**: Checks device/file existence before starting
- **Error Handling**: Comprehensive error checking
- **Logging**: Detailed logs for troubleshooting

## Best Practices

1. **Always use latest QEMU** for best compatibility
2. **Install OVMF** for UEFI testing
3. **Enable KVM** for better performance
4. **Test both modes** (UEFI and BIOS) for maximum compatibility
5. **Save configurations** for frequently tested media
6. **Check diagnostics** before reporting issues
7. **Increase RAM** for Windows and resource-heavy ISOs
8. **Use virtio VGA** for best Linux performance

## Comparison with Real Hardware Testing

| Aspect | Real Hardware | usb-boot-test |
|--------|--------------|---------------|
| Reboot required | ✅ Yes | ❌ No |
| BIOS changes | ✅ Yes | ❌ No |
| Time per test | 5-10 minutes | 30 seconds |
| Risk of data loss | ⚠️ Medium | ✅ None |
| Both UEFI/BIOS | Sequential reboots | ✅ Quick switch |
| Hardware acceleration | ✅ Full | ✅ KVM |
| Config changes | Slow (reboot) | ✅ Instant |
| Multi-device testing | Very slow | ✅ Fast |

## Logs

Logs are saved to `/tmp/ventoy_test_logs/`:

```bash
# View latest log
ls -lt /tmp/ventoy_test_logs/ | head

# Check for errors
grep -i error /tmp/ventoy_test_logs/*.log

# Monitor in real-time
tail -f /tmp/ventoy_test_logs/ventoy_test_*.log
```

## Name Change Notice

This tool was previously called `ventoy-usb-test`. It has been renamed to `usb-boot-test` to better reflect its generic bootable media testing capabilities.

**Both commands work**:
- `usb-boot-test` (new, recommended)
- `ventoy-usb-test` (legacy, still supported)

## See Also

- [VM Management Tools](../../vm/README.md) - For VM disk operations
- [VM Clone](../../vm/README.md#vm-clone) - For VM cloning with QEMU
- QEMU Documentation: https://www.qemu.org/docs/master/
- OVMF Project: https://github.com/tianocore/tianocore.github.io/wiki/OVMF
- Ventoy: https://www.ventoy.net/
