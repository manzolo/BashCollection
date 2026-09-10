# shellcheck shell=bash
# TUI presentation and quick actions. No additional terminal UI dependency.

ui_init() {
    # Honour an existing newt theme; otherwise use a muted blue/grey palette:
    # light grey text on blue, grey highlights, no red or bright cyan accents.
    if [[ -z "${NEWT_COLORS:-}" && -z "${NEWT_COLORS_FILE:-}" ]]; then
        export NEWT_COLORS='root=lightgray,black
roottext=lightgray,black
border=lightgray,blue
window=lightgray,blue
shadow=black,black
title=white,blue
button=black,lightgray
actbutton=black,white
compactbutton=lightgray,blue
checkbox=lightgray,blue
actcheckbox=black,lightgray
entry=black,lightgray
label=lightgray,blue
listbox=lightgray,blue
sellistbox=white,blue
actlistbox=black,lightgray
actsellistbox=black,lightgray
textbox=lightgray,blue
acttextbox=black,lightgray
emptyscale=lightgray,blue
fullscale=blue,lightgray'
    fi
}

# Main dashboard and text viewers fit the current terminal, also after resize.
# shellcheck disable=SC2034
ui_dimensions() {
    local rows cols
    rows=$(tput lines 2>/dev/null) || rows=24
    cols=$(tput cols 2>/dev/null) || cols=80
    UI_HEIGHT=$((rows - 2))
    UI_WIDTH=$((cols - 4))
    (( UI_HEIGHT > 28 )) && UI_HEIGHT=28
    (( UI_WIDTH > 100 )) && UI_WIDTH=100
    (( UI_HEIGHT < 16 )) && UI_HEIGHT=16
    (( UI_WIDTH < 56 )) && UI_WIDTH=56
    UI_LIST_HEIGHT=$((UI_HEIGHT - 11))
    (( UI_LIST_HEIGHT > 11 )) && UI_LIST_HEIGHT=11
    return 0
}

profile_menu() {
    local choice
    choice=$(whiptail --title "✨ Quick Profiles" --cancel-button "Back" \
        --menu "Apply hardware defaults, then fine-tune as needed.\nTarget, boot mode, snapshot, network and audio are preserved." \
        15 76 2 \
        "windows" "🪟 Windows · 8 GiB, 4 cores, standard VGA" \
        "generic" "💿 Generic · 2 GiB, 4 cores, VirtIO video" \
        3>&1 1>&2 2>&3) || return 0
    case "$choice" in windows|generic) apply_hardware_profile "$choice" ;; esac
}

preview_command() {
    if [[ -z "$DISK" ]]; then
        whiptail --title "Command Preview" --msgbox "Select a USB device or image first." 8 56 || true
        return 0
    fi
    local preview
    preview=$(mktemp "$RUN_DIR/preview.XXXXXX") || return 1
    # Use the same CLI dry-run path, including boot/media detection and checks.
    # The subprocess owns its temporary OVMF copy; no configuration is saved.
    local args=(--dry-run --ram "$MEMORY" --cores "$CORES"
        --machine "$MACHINE_TYPE" --usb "$USB_VERSION" --vga "$VGA_MODE"
        --mouse "$MOUSE_MODE" --scale "$DISPLAY_SCALE" --format "$FORMAT"
        --media "$MEDIA_MODE" --ovmf "$DEFAULT_BIOS" "--$BIOS_MODE")
    [[ "$NETWORK" == true ]] && args+=(--net)
    [[ "$SOUND" == true ]] && args+=(--sound)
    [[ "$SNAPSHOT" == false ]] && args+=(--no-snapshot)
    [[ "$FULLSCREEN" == true ]] && args+=(--fullscreen)
    # The CLI exposes cores, while threads/sockets may be set in the TUI.
    # Source in an isolated process to pass that topology without new CLI flags.
    bash -c 'source "$1"; shift; log_warn() { echo "[WARN] $*" >&2; }; log_error() { echo "[ERROR] $*" >&2; }; THREADS="$1"; SOCKETS="$2"; shift 2; main "$@"' \
        usb-boot-preview "$SCRIPT_PATH" "$THREADS" "$SOCKETS" "${args[@]}" -- "$DISK" > "$preview" 2>&1 || true
    ui_dimensions
    whiptail --title "🔎 QEMU Command · Preview Only" --scrolltext \
        --textbox "$preview" "$UI_HEIGHT" "$UI_WIDTH" || true
    rm -f "$preview"
}

show_last_log() {
    if [[ -z "$RUN_LOG" || ! -f "$RUN_LOG" ]]; then
        whiptail --title "Run Log" --msgbox \
            "No test has run in this session.\n\nSaved logs: $LOG_DIR" 11 72 || true
        return 0
    fi
    ui_dimensions
    whiptail --title "📋 Last Run Log" --scrolltext \
        --textbox "$RUN_LOG" "$UI_HEIGHT" "$UI_WIDTH" || true
}

tools_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "🔍 Tools" --cancel-button "Back" \
            --menu "Inspect the configuration or review the last test:" 16 72 5 \
            "1" "🔎 Preview QEMU command (no boot)" \
            "2" "📋 Last run log (this session)" \
            "3" "🔧 Diagnostics & system information" \
            "4" "❓ User guide" \
            "5" "Back" 3>&1 1>&2 2>&3) || true
        case "$choice" in
            1) preview_command ;;
            2) show_last_log ;;
            3) diagnostic_menu ;;
            4) show_help ;;
            5|"") break ;;
        esac
    done
}
