# mfirewall module: default policy configuration
# Sourced by mfirewall.sh — do not execute directly.
set_default_policies() {
    local current_policies
    current_policies="Current default policies:\n$(sudo ufw status verbose | grep 'Default:' || echo 'Could not retrieve current policies')"
    local choice
    choice=$(whiptail --title "Set Default Policies" --menu "$current_policies\n\nChoose policy set:" 20 $WT_WIDTH $WT_MENU_HEIGHT \
    "1" "Secure (deny incoming, allow outgoing)" \
    "2" "Restrictive (deny both incoming/outgoing)" \
    "3" "Permissive (allow both - NOT recommended)" \
    "4" "Custom Configuration" 3>&1 1>&2 2>&3) || true
    
    case $choice in
        1)
            if confirm_action "Apply secure default policies?\n(deny incoming, allow outgoing)"; then
                execute_command "sudo ufw default deny incoming && sudo ufw default allow outgoing" "Apply secure policies"
            fi
            ;;
        2)
            if confirm_action "Apply restrictive policies?\n\nWARNING: This may block internet access!"; then
                execute_command "sudo ufw default deny incoming && sudo ufw default deny outgoing" "Apply restrictive policies"
            fi
            ;;
        3)
            if confirm_action "Apply permissive policies?\n\nWARNING: This is less secure!"; then
                execute_command "sudo ufw default allow incoming && sudo ufw default allow outgoing" "Apply permissive policies"
            fi
            ;;
        4) custom_default_policies ;;
    esac
}

custom_default_policies() {
    local incoming
    incoming=$(whiptail --title "Incoming Policy" --menu "Choose default policy for incoming connections:" $WT_HEIGHT $WT_WIDTH 3 \
    "allow" "Allow all incoming" \
    "deny" "Deny all incoming (recommended)" \
    "reject" "Reject all incoming" 3>&1 1>&2 2>&3) || true
    
    if [ -n "$incoming" ]; then
        local outgoing
        outgoing=$(whiptail --title "Outgoing Policy" --menu "Choose default policy for outgoing connections:" $WT_HEIGHT $WT_WIDTH 3 \
        "allow" "Allow all outgoing (recommended)" \
        "deny" "Deny all outgoing" \
        "reject" "Reject all outgoing" 3>&1 1>&2 2>&3) || true
        
        if [ -n "$outgoing" ]; then
            if confirm_action "Apply custom policies?\nIncoming: $incoming\nOutgoing: $outgoing"; then
                execute_command "sudo ufw default $incoming incoming && sudo ufw default $outgoing outgoing" "Apply custom policies"
            fi
        fi
    fi
}

