# nvidia-manager module: usage text
# Sourced by nvidia-manager.sh — do not execute directly.

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Interactive NVIDIA driver and GPU management tool.

Options:
  -h, --help      Show this help message and exit

Features:
  - Check NVIDIA driver status with nvidia-smi
  - Live GPU dashboard with utilization, temperature, VRAM, power, fan and processes
  - Install, update and clean NVIDIA drivers
  - Configure performance settings: persistence mode, power limit, fan speed, clock offsets
  - View GPU processes and terminate selected PIDs
  - Install and validate NVIDIA Container Toolkit
  - Run troubleshooting diagnostics

Run:
  sudo $SCRIPT_NAME
EOF
}

