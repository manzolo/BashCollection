setup_gui_support() {
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        log "Setting up graphical support (X11) - EXPERIMENTAL"
        
        if [[ -n "${DISPLAY:-}" ]]; then
            log "Configuring X11 display access"
            
            # Ensure /tmp/.X11-unix has correct permissions
            if [[ -d "/tmp/.X11-unix" ]]; then
                run_with_privileges chmod 1777 "/tmp/.X11-unix" || true
            fi
            
            # Copy Xauthority
            local chroot_user="${CHROOT_USER:-root}"
            local xauthority_path="/home/$ORIGINAL_USER/.Xauthority"
            local chroot_xauth_path
            
            if [[ "$chroot_user" == "root" ]]; then
                chroot_xauth_path="$ROOT_MOUNT/root/.Xauthority"
            else
                chroot_xauth_path="$ROOT_MOUNT/home/$chroot_user/.Xauthority"
            fi
            
            if [[ -f "$xauthority_path" ]]; then
                log "Copying Xauthority file"
                run_with_privileges cp "$xauthority_path" "$chroot_xauth_path" && \
                run_with_privileges chown "$chroot_user:$chroot_user" "$chroot_xauth_path" && \
                run_with_privileges chmod 600 "$chroot_xauth_path" || \
                    warning "Failed to setup X11 authentication"
            fi
            
            # Allow local connections
            if command -v xhost &> /dev/null; then
                xhost +local: || warning "Failed to configure xhost"
            fi
        else
            warning "DISPLAY not set, X11 support will not work"
            ENABLE_GUI_SUPPORT=false
        fi
    fi
}