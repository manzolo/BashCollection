# nvidia-manager module: logging and small helpers
# Sourced by nvidia-manager.sh — do not execute directly.

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

require_nvidia_smi() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        whiptail --title "NVIDIA Required" --msgbox "nvidia-smi is not available. Install a working NVIDIA driver first." 10 70
        return 1
    fi

    if ! nvidia-smi >/dev/null 2>&1; then
        whiptail --title "NVIDIA Required" --msgbox "nvidia-smi is installed but cannot communicate with the NVIDIA driver." 10 70
        return 1
    fi
}

pause_for_enter() {
    echo ""
    echo -e "${CYAN}Press Enter to return to main menu...${NC}"
    read -r
}

# Function to check NVIDIA driver status
