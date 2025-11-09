# NVIDIA Manager

Interactive NVIDIA driver and GPU management tool with comprehensive troubleshooting capabilities.

## Overview

**nvidia-manager** is a TUI-based tool for managing NVIDIA drivers, GPU settings, and container toolkit integration on Ubuntu/Debian systems. It simplifies the complex process of installing, updating, and troubleshooting NVIDIA drivers with an easy-to-use whiptail interface.

## Features

### Driver Management
- **Check Driver Status**: View detailed driver information with nvidia-smi
- **Search and Install Drivers**: Browse and install available NVIDIA driver versions
- **Clean Drivers**: Completely remove NVIDIA drivers and packages
- **Version Detection**: Automatic detection of installed driver versions

### Container Support
- **NVIDIA Container Toolkit**: Install and configure GPU support for Docker/containerd
- **Runtime Auto-detection**: Automatically detects Docker or containerd
- **GPU Passthrough**: Enable NVIDIA GPUs in containers
- **Version Verification**: Test container toolkit functionality

### Troubleshooting
- **Comprehensive Diagnostics**: Automated troubleshooting reports
- **Device Node Verification**: Check NVIDIA device files
- **OpenGL Testing**: Verify OpenGL renderer
- **CUDA Testing**: Test CUDA functionality
- **Driver Detection**: Multiple methods for driver version detection

### User Experience
- **Interactive TUI**: User-friendly whiptail-based interface
- **Automatic Dependency Installation**: Installs required tools automatically
- **Safe Operations**: Confirmation prompts before destructive actions
- **Detailed Feedback**: Clear success/warning/error messages
- **Reboot Management**: Prompts for reboot when required

## Usage

### Basic Usage

```bash
# Launch the interactive interface
sudo nvidia-manager
```

The main menu provides six options:
1. Check Driver Status
2. Clean Drivers
3. Search and Install Drivers
4. Manage Container Toolkit
5. Troubleshoot
6. Exit

### Menu Options Explained

#### 1. Check Driver Status

Displays detailed NVIDIA driver information using nvidia-smi, including:
- Driver version
- GPU model and name
- Memory usage
- Temperature
- Power consumption
- Running processes using GPU

```bash
# Shows output similar to:
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 535.129.03   Driver Version: 535.129.03   CUDA Version: 12.2   |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp  Perf  Pwr:Usage/Cap|         Memory-Usage | GPU-Util  Compute M. |
+-------------------------------+----------------------+----------------------+
```

#### 2. Clean Drivers

Removes all NVIDIA drivers and related packages from the system.

**Warning**: This operation will:
- Remove all nvidia-* packages
- Remove all libnvidia-* packages
- Run autoremove and autoclean
- Require system reboot

**Use cases**:
- Switching to different driver version
- Troubleshooting driver conflicts
- Preparing for manual driver installation
- Clean system state before reinstall

#### 3. Search and Install Drivers

Searches Ubuntu repositories for available NVIDIA driver versions and allows installation.

**Process**:
1. Updates package repositories
2. Searches for nvidia-driver-* packages
3. Displays available versions in a menu
4. Installs selected driver with dependencies
5. Configures system for new driver

**Available drivers typically include**:
- nvidia-driver-535 (Latest stable)
- nvidia-driver-525 (Previous stable)
- nvidia-driver-470 (Legacy)
- nvidia-driver-390 (Older GPUs)

#### 4. Manage Container Toolkit

Installs and configures NVIDIA Container Toolkit for GPU support in Docker/containerd.

**Features**:
- Auto-detects Docker or containerd
- Tests existing toolkit functionality
- Installs toolkit if not present
- Configures runtime automatically
- Restarts container service
- Verifies installation with test container

**Use cases**:
- Running GPU workloads in Docker
- Machine learning with containerized frameworks
- CUDA applications in containers
- GPU-accelerated rendering in containers

**Test command used**:
```bash
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi
```

#### 5. Troubleshoot

Runs comprehensive diagnostics and generates a troubleshooting report.

**Checks performed**:
- Host NVIDIA driver detection (3 methods)
- Container NVIDIA packages
- OpenGL renderer test
- CUDA functionality test
- Device node verification (/dev/nvidia*, /dev/nvidiactl, etc.)
- nvidia-smi functionality
- GPU device listing

**Report includes**:
- Driver versions (host and container)
- Detection methods used
- OpenGL renderer information
- CUDA status
- Missing device nodes
- Recommendations for fixes

## Screenshots

### Main Menu

<img width="796" height="453" alt="NVIDIA Manager main menu" src="https://github.com/user-attachments/assets/8ebbc181-cbd2-4b03-987e-efc2685c8555" />

### Driver Status Check

<img width="949" height="489" alt="nvidia-smi output showing driver status" src="https://github.com/user-attachments/assets/30ec00c2-9503-4f73-9341-24a7691c7756" />

### Driver Search and Selection

<img width="949" height="489" alt="Available NVIDIA drivers list" src="https://github.com/user-attachments/assets/c4c298c9-d0f7-4c55-91a2-65eee5f7adfb" />

### Container Toolkit Configuration

<img width="949" height="489" alt="Driver installation progress" src="https://github.com/user-attachments/assets/af37ec52-ba6a-4de1-8a2d-8966f8efdfb7" />

### System information

<img width="949" height="489" alt="NVIDIA Container Toolkit setup" src="https://github.com/user-attachments/assets/482e16ca-0ed3-4b37-b2e2-00079c7dd58e" />

## Requirements

### Required
- bash >= 4.0
- whiptail (auto-installed if missing)
- Root/sudo privileges
- Ubuntu/Debian-based system
- NVIDIA GPU hardware

### Recommended
- nvidia-smi (installed with driver)
- Docker or containerd (for Container Toolkit features)
- mesa-utils (for glxinfo/OpenGL testing)

### Installation of Dependencies

```bash
# Basic requirements (auto-installed by script)
sudo apt install whiptail

# Optional tools
sudo apt install mesa-utils

# Docker (for container features)
sudo apt install docker.io

# Or containerd
sudo apt install containerd
```

## Common Use Cases

### 1. First-Time NVIDIA Driver Installation

**Scenario**: New system with NVIDIA GPU, no drivers installed.

```bash
sudo nvidia-manager

# In menu:
# 1. Select "Search and Install Drivers"
# 2. Choose latest stable version (e.g., nvidia-driver-535)
# 3. Wait for installation
# 4. Reboot when prompted

# After reboot, verify:
# Select "Check Driver Status"
```

### 2. Upgrading NVIDIA Driver

**Scenario**: Update to newer driver version.

```bash
sudo nvidia-manager

# In menu:
# 1. Select "Clean Drivers" (removes old version)
# 2. Reboot
# 3. Run nvidia-manager again
# 4. Select "Search and Install Drivers"
# 5. Choose new version
# 6. Reboot
```

### 3. Setting Up GPU for Docker

**Scenario**: Enable NVIDIA GPU in Docker containers.

```bash
sudo nvidia-manager

# In menu:
# 1. Ensure driver is installed (Check Driver Status)
# 2. Select "Manage Container Toolkit"
# 3. Follow prompts to install toolkit
# 4. Wait for Docker restart
# 5. Test with provided command

# Verify it works:
sudo docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi
```

### 4. Troubleshooting Driver Issues

**Scenario**: nvidia-smi not working or GPU not detected.

```bash
sudo nvidia-manager

# In menu:
# 1. Select "Troubleshoot"
# 2. Review diagnostics report
# 3. Check for:
#    - Missing device nodes
#    - Driver version mismatches
#    - OpenGL renderer issues
# 4. Based on report, try:
#    - "Clean Drivers" then reinstall
#    - Check secure boot settings
#    - Verify GPU is properly seated
```

### 5. Switching Between Driver Versions

**Scenario**: Need older driver for compatibility.

```bash
sudo nvidia-manager

# In menu:
# 1. Select "Clean Drivers"
# 2. Confirm removal
# 3. Reboot
# 4. Run nvidia-manager again
# 5. Select "Search and Install Drivers"
# 6. Choose specific version (e.g., nvidia-driver-470)
# 7. Install and reboot
```

### 6. Verifying Installation

**Scenario**: Confirm everything is working correctly.

```bash
sudo nvidia-manager

# In menu:
# 1. Select "Check Driver Status"
#    - Should show GPU information
# 2. Select "Troubleshoot"
#    - All checks should pass
# 3. If using containers, select "Manage Container Toolkit"
#    - Should report toolkit is working
```

## Driver Version Selection Guide

### Latest Stable (Recommended for most users)
- **nvidia-driver-535**: Current stable release
- Best performance and latest features
- Supports most recent GPUs

### Previous Stable
- **nvidia-driver-525**: Previous stable
- Good balance of stability and features
- Use if latest has issues

### Legacy Drivers
- **nvidia-driver-470**: For older GPUs (GTX 600/700 series)
- **nvidia-driver-390**: For very old GPUs (GTX 400/500 series)

### How to Choose
1. Check NVIDIA's website for your GPU model
2. Start with latest stable
3. If issues occur, try previous stable
4. For old GPUs (5+ years), use legacy drivers

## Container Toolkit Details

### What It Does
- Exposes NVIDIA GPUs to containers
- Provides CUDA libraries in containers
- Enables GPU-accelerated workloads

### Supported Runtimes
- **Docker**: Most common container runtime
- **containerd**: Used by Kubernetes and others

### Configuration
The toolkit configures the runtime to:
1. Detect NVIDIA GPUs on host
2. Mount GPU devices into containers
3. Inject NVIDIA libraries
4. Set up proper permissions

### Testing
After installation, test with:

```bash
# Docker
docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi

# Example ML workload
docker run --rm --gpus all tensorflow/tensorflow:latest-gpu python -c "import tensorflow as tf; print(tf.config.list_physical_devices('GPU'))"
```

## Troubleshooting

### nvidia-smi: command not found

**Cause**: Driver not installed or not in PATH.

**Solution**:
```bash
sudo nvidia-manager
# Select "Search and Install Drivers"
```

### nvidia-smi: Failed to initialize NVML

**Cause**: Driver loaded incorrectly or kernel module issues.

**Solution**:
```bash
# Check kernel module
lsmod | grep nvidia

# If not loaded:
sudo modprobe nvidia

# If that fails, reinstall driver:
sudo nvidia-manager
# Select "Clean Drivers", reboot, then reinstall
```

### No devices found in docker with --gpus

**Cause**: NVIDIA Container Toolkit not installed.

**Solution**:
```bash
sudo nvidia-manager
# Select "Manage Container Toolkit"
```

### Driver version mismatch

**Cause**: Multiple driver versions or incomplete removal.

**Solution**:
```bash
sudo nvidia-manager
# Select "Clean Drivers"
# Reboot
# Reinstall single version
```

### Secure Boot preventing driver loading

**Cause**: Unsigned kernel modules blocked by Secure Boot.

**Solution**:
1. Disable Secure Boot in BIOS/UEFI, or
2. Sign the NVIDIA kernel module (advanced)

### Black screen after driver installation

**Cause**: Display manager conflict or wrong driver.

**Solution**:
```bash
# Boot to recovery mode or TTY (Ctrl+Alt+F2)
sudo nvidia-manager
# Select "Clean Drivers"
# Reboot and try different driver version
```

### GPU not detected (lspci shows it)

**Cause**: Nouveau (open-source driver) conflict.

**Solution**:
```bash
# Check if nouveau is loaded
lsmod | grep nouveau

# Blacklist nouveau
echo "blacklist nouveau" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
sudo update-initramfs -u
sudo reboot

# Then install NVIDIA driver
sudo nvidia-manager
```

## Advanced Tips

### Check Current Driver Version
```bash
# Method 1
nvidia-smi --query-gpu=driver_version --format=csv,noheader

# Method 2
cat /proc/driver/nvidia/version

# Method 3
modinfo nvidia | grep ^version
```

### Manually Test Container Toolkit
```bash
# Check if runtime is configured
docker info | grep -i runtime

# Test GPU access
docker run --rm --gpus all ubuntu:22.04 nvidia-smi
```

### View Detailed GPU Information
```bash
# Full nvidia-smi output
nvidia-smi -q

# Specific query
nvidia-smi --query-gpu=gpu_name,driver_version,memory.total --format=csv
```

### Monitor GPU in Real-time
```bash
# Update every second
watch -n 1 nvidia-smi

# Or with more details
nvidia-smi dmon
```

### Check CUDA Version
```bash
nvcc --version  # CUDA compiler (if toolkit installed)
nvidia-smi      # Shows compatible CUDA version
```

## Safety Features

- **Confirmation Prompts**: All destructive operations require confirmation
- **Automatic Backup**: APT handles package backups
- **Reboot Warnings**: Prompts when reboot is required
- **Dependency Checking**: Verifies prerequisites before operations
- **Error Handling**: Comprehensive error messages and recovery
- **Repository Verification**: Uses official NVIDIA repositories

## Known Limitations

- Ubuntu/Debian only (uses APT)
- Requires systemd (for service restarts)
- Internet connection needed for driver downloads
- Cannot install drivers during active X session (may require reboot)
- Secure Boot may require additional configuration
- Optimus/hybrid graphics may need extra setup

## Best Practices

1. **Always backup** important data before driver changes
2. **Close GPU applications** before driver updates
3. **Use latest stable** driver unless compatibility issues exist
4. **Test after installation** using "Check Driver Status"
5. **Keep one driver version** - don't mix versions
6. **Reboot after major changes** to ensure clean state
7. **Use Container Toolkit** instead of installing CUDA in containers
8. **Check compatibility** with your GPU model before installation

## Comparison with Manual Installation

| Task | Manual | nvidia-manager |
|------|--------|----------------|
| Find available drivers | Research needed | ✅ Automated search |
| Install driver | `apt install ...` | ✅ Interactive menu |
| Clean old drivers | Multiple commands | ✅ One-click removal |
| Container Toolkit setup | Complex manual steps | ✅ Automated |
| Troubleshooting | Manual investigation | ✅ Diagnostic report |
| Repository setup | Manual configuration | ✅ Auto-configured |
| Version verification | Multiple commands | ✅ Built-in checks |

## Exit Codes

- `0` - Success
- `1` - General error or user cancellation

## Related Resources

- [NVIDIA Official Drivers](https://www.nvidia.com/Download/index.aspx)
- [NVIDIA Container Toolkit Documentation](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
- [Ubuntu NVIDIA Driver Installation Guide](https://ubuntu.com/server/docs/nvidia-drivers-installation)
- [Docker GPU Support](https://docs.docker.com/config/containers/resource_constraints/#gpu)

## See Also

- [Docker Manager](../docker/README.md) - For Docker container management
- [Server Monitor](../utils/README.md#server-monitor) - For GPU monitoring in dashboard
- Standard Linux commands: `nvidia-smi(1)`, `modprobe(8)`, `lspci(8)`
