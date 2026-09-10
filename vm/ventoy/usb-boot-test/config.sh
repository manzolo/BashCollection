# shellcheck shell=bash
# Configuration persistence. The file is plain KEY="value" lines and is parsed,
# not sourced, so a damaged or tampered config cannot execute code.

# Settings that may be persisted, with the validation each value must pass.
_config_keys() {
    cat <<'EOF'
MEMORY:number
CORES:number
THREADS:number
SOCKETS:number
MACHINE_TYPE:word
DISK:path
FORMAT:word
BIOS_MODE:word
VGA_MODE:word
MOUSE_MODE:mouse
DISPLAY_SCALE:scale
FULLSCREEN:bool
NETWORK:bool
SOUND:bool
USB_VERSION:word
SNAPSHOT:bool
MEDIA_MODE:word
EOF
}

_config_value_ok() {
    local kind="$1" value="$2"
    case "$kind" in
        number) [[ "$value" =~ ^[0-9]+$ ]] ;;
        bool)   [[ "$value" == true || "$value" == false ]] ;;
        mouse)  [[ "$value" == tablet || "$value" == relative ]] ;;
        scale)  [[ "$value" == fit || "$value" == native ]] ;;
        word)   [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] ;;
        path)   [[ "$value" != *$'\n'* ]] ;;
        *)      return 1 ;;
    esac
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    {
        echo "# $SCRIPT_NAME v$VERSION configuration — KEY=\"value\" lines"
        local entry key
        while IFS= read -r entry; do
            key="${entry%%:*}"
            printf '%s="%s"\n' "$key" "${!key}"
        done < <(_config_keys)
    } > "$CONFIG_FILE"
    # Keep the file owned by the invoking user when running via sudo.
    if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
        chown -R "$SUDO_USER" "$CONFIG_DIR" 2>/dev/null || true
    fi
    log_info "Configuration saved to $CONFIG_FILE"
}

# Parse a KEY="value" file into the known settings; unknown keys and invalid
# values are ignored with a warning.
_config_parse_file() {
    local file="$1"
    local line key value kind
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%"${value##*[![:space:]]}"}"          # rtrim
        [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
        kind=$(_config_keys | awk -F: -v k="$key" '$1==k{print $2}')
        if [[ -z "$kind" ]]; then
            log_warn "config: ignoring unknown key '$key'"
            continue
        fi
        if [[ -n "$value" ]] && ! _config_value_ok "$kind" "$value"; then
            log_warn "config: ignoring invalid value for $key"
            continue
        fi
        printf -v "$key" '%s' "$value"
    done < "$file"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        _config_parse_file "$CONFIG_FILE"
        log_info "Configuration loaded from $CONFIG_FILE"
    elif [[ -f "$LEGACY_CONFIG_FILE" ]]; then
        _config_parse_file "$LEGACY_CONFIG_FILE"
        log_info "Migrated legacy configuration from $LEGACY_CONFIG_FILE"
        save_config
    fi
    # A saved disk that no longer exists (USB unplugged) must not linger.
    if [[ -n "$DISK" && ! -b "$DISK" && ! -f "$DISK" ]]; then
        log_warn "Saved disk $DISK is not present, clearing selection"
        DISK=""
    fi
    case "$MEDIA_MODE" in auto|disk|cdrom) ;; *) MEDIA_MODE="auto" ;; esac
    case "$MOUSE_MODE" in tablet|relative) ;; *) MOUSE_MODE="tablet" ;; esac
    case "$DISPLAY_SCALE" in fit|native) ;; *) DISPLAY_SCALE="fit" ;; esac
    case "$FULLSCREEN" in true|false) ;; *) FULLSCREEN=false ;; esac
    refresh_media_type
}

# shellcheck disable=SC2034  # globals consumed by the menus and build_qemu_command
reset_to_defaults() {
    MEMORY="2048"
    CORES="4"
    THREADS="1"
    SOCKETS="1"
    MACHINE_TYPE="q35"
    DISK=""
    FORMAT="raw"
    BIOS_MODE="uefi"
    VGA_MODE="virtio"
    MOUSE_MODE="tablet"
    DISPLAY_SCALE="fit"
    FULLSCREEN=false
    NETWORK=false
    SOUND=false
    USB_VERSION="3.0"
    SNAPSHOT=true
    MEDIA_MODE="auto"
    MEDIA="disk"
}

# Apply only hardware/display defaults. Preserve the target, firmware choice,
# media, snapshot protection, network and audio settings.
# shellcheck disable=SC2034
apply_hardware_profile() {
    MEMORY="8192"
    CORES="4"
    THREADS="1"
    SOCKETS="1"
    MACHINE_TYPE="q35"
    USB_VERSION="3.0"
    VGA_MODE="std"
    MOUSE_MODE="tablet"
    DISPLAY_SCALE="fit"
    if [[ "${1:-windows}" == generic ]]; then
        MEMORY="2048"
        VGA_MODE="virtio"
    fi
}
