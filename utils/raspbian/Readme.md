# QEMU Raspberry Pi Emulator

A Bash script (`pi-emulate`) to manage QEMU-based Raspberry Pi emulations, supporting Raspbian/Raspberry Pi OS images (Jessie, Stretch, Buster, Bullseye) with a focus on ease of use and compatibility.

<img width="1287" height="1032" alt="image" src="https://github.com/user-attachments/assets/7614012f-708f-44fd-8868-1c6d0afcb05e" />


## Features
- **Quick Start**: Launch a pre-configured Raspbian Jessie 2017 instance.
- **Instance Management**: Create, start, stop, clone, and delete emulated Raspberry Pi instances.
- **OS Image Download**: Download and prepare Raspbian/Raspberry Pi OS images.
- **Networking**: Configured with user-mode networking and SSH port forwarding.
- **Diagnostics & Logs**: View system diagnostics and detailed logs.
- **Performance Tips**: Guidance for optimal emulation performance.

## Requirements
- Linux system with `bash`, `qemu-system-arm`, `qemu-img`, `wget`, `unzip`, `xz`, `fdisk`, and `dialog`.
- Sudo privileges for installing dependencies and file operations.

## Installation
### Clone the repository:
   ```bash
   git clone https://github.com/manzolo/BashCollection
   cd BashCollection
   sudo ./menage_scripts.sh install
   pi-emulate
   ```

## Usage
Run the script with optional flags:
```bash
./pi-emulate [-h|--help] [-v|--verbose] [-d|--debug]
```
- `-h, --help`: Display help information.
- `-v, --verbose`: Enable verbose output.
- `-d, --debug`: Enable debug mode (includes verbose).

The script provides an interactive `dialog`-based menu to:
- Start a quick Jessie instance.
- Create and manage custom instances.
- Download OS images.
- View diagnostics, logs, and performance tips.
- Clean the workspace.

## Notes
- Uses Jessie kernel (4.4.34) for all OS versions for maximum compatibility.
- Emulation is single-core (ARM1176) without KVM acceleration on x86 hosts.
- Default credentials: `pi` / `raspberry` (SSH access after boot).
- Network uses `-nic user,hostfwd=tcp::PORT-:22` for SSH connectivity.

## Directory Structure
- `~/.qemu-rpi-manager/`
  - `images/`: OS image files.
  - `kernels/`: Kernel files.
  - `configs/`: Configuration and instance database.
  - `logs/`: Log files.
  - `cache/`, `temp/`, `mount/`: Temporary directories.

## License
MIT License. See [LICENSE](LICENSE) for details.

## Contributing
Pull requests and issues are welcome! Please test changes thoroughly and ensure compatibility with supported OS versions.
