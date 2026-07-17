# ==============================================================================
# AUDIO CONFIGURATION
# ==============================================================================

check_audio_support() {
    local available_backends=""
    
    # Test PulseAudio more rigorously
    if command -v pactl &> /dev/null; then
        # Check if PulseAudio server is running
        if pactl info &> /dev/null 2>&1; then
            # Check if we can access the socket
            if [ -S "/run/user/$(id -u)/pulse/native" ] || pgrep -x pulseaudio > /dev/null; then
                available_backends+="pa "
            fi
        fi
    fi
    
    # Test ALSA more thoroughly  
    if [ -d /proc/asound ] && command -v aplay &> /dev/null; then
        # Check if there are any playback devices
        if aplay -l 2>/dev/null | grep -q "card"; then
            available_backends+="alsa "
        fi
    fi
    
    # Test OSS
    if [ -c /dev/dsp ] || [ -c /dev/audio ]; then
        available_backends+="oss "
    fi
    
    # SDL as fallback (usually available if SDL libraries are installed)
    if command -v pkg-config &> /dev/null && pkg-config --exists sdl2; then
        available_backends+="sdl "
    fi
    
    echo "$available_backends"
}

configure_audio() {
    local available=$(check_audio_support)
    
    if [ -z "$available" ]; then
        dialog --msgbox "No audio backends available!\n\nInstall PulseAudio or ALSA for audio support.\nRun './pi-emulate --install-audio' to install." 10 50
        return
    fi
    
    local current_backend="${AUDIO_BACKEND:-pa}"
    local audio_menu=""
    local counter=1
    
    for backend in "${!AUDIO_BACKENDS[@]}"; do
        audio_menu+="$counter \"$backend - ${AUDIO_BACKENDS[$backend]}\" "
        ((counter++))
    done
    
    local choice
    choice=$(eval dialog --title \"Audio Configuration\" \
        --menu \"Available: $available\n\nSelect audio backend:\" 15 60 6 $audio_menu 2>&1 >/dev/tty)
    
    [ -z "$choice" ] && return
    
    local backends=(${!AUDIO_BACKENDS[@]})
    local selected_backend="${backends[$((choice-1))]}"
    
    # Save configuration
    echo "AUDIO_BACKEND=$selected_backend" > "${CONFIGS_DIR}/audio.conf"
    
    dialog --msgbox "Audio backend set to: ${AUDIO_BACKENDS[$selected_backend]}" 8 50
}

install_audio_dependencies() {
    dialog --title "Installing Audio Support" --infobox "Installing audio dependencies..." 5 40
    
    local packages="pulseaudio pavucontrol alsa-utils"
    
    ${SUDO_CMD} apt-get update
    ${SUDO_CMD} apt-get install -y $packages
    
    # Start PulseAudio if not running
    if command -v pulseaudio &> /dev/null; then
        pulseaudio --check || pulseaudio --start --daemonize
    fi
    
    dialog --msgbox "Audio dependencies installed!\nPlease restart the script." 8 40
}

test_audio_simple() {
    # Try the simplest audio configuration first
    echo "Testing simple audio configuration..."
    
    # Start PulseAudio if not running (user session)
    if command -v pulseaudio &> /dev/null && ! pgrep -x pulseaudio > /dev/null; then
        echo "Starting PulseAudio..."
        pulseaudio --start --daemonize 2>/dev/null || true
        sleep 2
    fi
    
    # Test with minimal audio setup
    local test_cmd="qemu-system-arm -audiodev pa,id=audio0 -device AC97,audiodev=audio0 -M versatilepb -display none -serial null -monitor none"
    
    timeout 5s $test_cmd 2>/dev/null && echo "PulseAudio works" || echo "PulseAudio failed"
}