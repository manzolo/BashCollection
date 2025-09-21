#!/bin/bash

set -e

# ==============================================================================
# GLOBAL CONFIGURATION
# ==============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly WORK_DIR="${HOME}/.qemu-rpi-manager"
readonly IMAGES_DIR="${WORK_DIR}/images"
readonly KERNELS_DIR="${WORK_DIR}/kernels"
readonly SNAPSHOTS_DIR="${WORK_DIR}/snapshots"
readonly CONFIGS_DIR="${WORK_DIR}/configs"
readonly LOGS_DIR="${WORK_DIR}/logs"
readonly TEMP_DIR="${WORK_DIR}/temp"
readonly CACHE_DIR="${WORK_DIR}/cache"
readonly MOUNT_DIR="${WORK_DIR}/mount"

# Configuration files
readonly CONFIG_FILE="${CONFIGS_DIR}/qemu-rpi.conf"
readonly INSTANCES_DB="${CONFIGS_DIR}/instances.db"

# Logging
readonly LOG_FILE="${LOGS_DIR}/qemu-rpi-$(date +%Y%m%d-%H%M%S).log"

# QEMU defaults
readonly DEFAULT_MEMORY="256"
readonly DEFAULT_SSH_PORT="5022"

# OS Catalog
declare -A OS_CATALOG=(
    ["jessie_2017_full"]="jessie|2017-04-10|4.4.34|full|http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/2017-04-10-raspbian-jessie.zip"
    ["jessie_2017_lite"]="jessie|2017-04-10|4.4.34|lite|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2017-04-10/2017-04-10-raspbian-jessie-lite.zip"
    ["stretch_2018_full"]="stretch|2018-11-13|4.9.80|full|http://downloads.raspberrypi.org/raspbian/images/raspbian-2018-11-15/2018-11-13-raspbian-stretch.zip"
    ["stretch_2018_lite"]="stretch|2018-11-13|4.9.80|lite|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2018-11-15/2018-11-13-raspbian-stretch-lite.zip"
    ["buster_2020_full"]="buster|2020-02-13|4.19.118|full|http://downloads.raspberrypi.org/raspbian/images/raspbian-2020-02-14/2020-02-13-raspbian-buster.zip"
    ["buster_2020_lite"]="buster|2020-02-13|4.19.118|lite|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2020-02-14/2020-02-13-raspbian-buster-lite.zip"
    ["bullseye_2022_full"]="bullseye|2022-04-04|5.10.103|full|https://downloads.raspberrypi.org/raspios_armhf/images/raspios_armhf-2022-04-07/2022-04-04-raspios-bullseye-armhf.img.xz"
    ["bullseye_2022_lite"]="bullseye|2022-04-04|5.10.103|lite|https://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2022-04-07/2022-04-04-raspios-bullseye-armhf-lite.img.xz"
)

# Kernel repository
readonly KERNEL_REPO="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master"

# ==============================================================================
# LOGGING SYSTEM
# ==============================================================================

log_init() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== QEMU RPi Manager Started: $(date) ===" >> "$LOG_FILE"
}

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    
    case $level in
        ERROR) echo -e "\033[0;31m[ERROR]\033[0m $message" >&2 ;;
        WARNING) echo -e "\033[1;33m[WARNING]\033[0m $message" >&2 ;;
        INFO) [ "${VERBOSE}" = "1" ] && echo -e "\033[0;32m[INFO]\033[0m $message" ;;
        DEBUG) [ "${DEBUG}" = "1" ] && echo -e "\033[0;34m[DEBUG]\033[0m $message" ;;
    esac
    return 0
}

# ==============================================================================
# DIALOG UI FUNCTIONS
# ==============================================================================

check_dialog() {
    if ! command -v dialog &> /dev/null; then
        echo "Installing dialog..."
        ${SUDO_CMD} apt-get update && ${SUDO_CMD} apt-get install -y dialog
    fi
    return 0
}

show_main_menu() {
    dialog --clear --backtitle "QEMU Raspberry Pi Manager v2.0.4 - Fixed Network & Performance" \
        --title "[ Main Menu ]" \
        --menu "Select an option:" 18 65 11 \
        "1" "Quick Start (Jessie 2017)" \
        "2" "Create New Instance" \
        "3" "Manage Instances" \
        "4" "Download OS Images" \
        "5" "System Diagnostics" \
        "6" "View Logs" \
        "7" "Performance Tips" \
        "8" "Clean Workspace" \
        "0" "Exit" \
        2>&1 >/dev/tty
}

# ==============================================================================
# SYSTEM INITIALIZATION
# ==============================================================================

init_workspace() {
    local dirs=("$WORK_DIR" "$IMAGES_DIR" "$KERNELS_DIR" "$SNAPSHOTS_DIR" 
                "$CONFIGS_DIR" "$LOGS_DIR" "$TEMP_DIR" "$CACHE_DIR" "$MOUNT_DIR")
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" || {
            log ERROR "Failed to create directory: $dir"
            return 1
        }
    done
    
    if [ ! -f "$INSTANCES_DB" ]; then
        cat > "$INSTANCES_DB" <<EOF
# Instance Database
# Format: ID|Name|Image|Kernel|Memory|SSH_Port|Status|Created
EOF
    fi
    
    return 0
}

check_requirements() {
    local missing=()
    local required_cmds=(qemu-system-arm qemu-img wget unzip xz fdisk dialog)
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Installing missing dependencies: ${missing[*]}"
        install_dependencies "${missing[@]}"
    fi
    
    return 0
}

install_dependencies() {
    local deps=("$@")
    local apt_packages=""
    
    for dep in "${deps[@]}"; do
        case $dep in
            qemu-system-arm) apt_packages+=" qemu-system qemu-utils" ;;
            xz) apt_packages+=" xz-utils" ;;
            *) apt_packages+=" $dep" ;;
        esac
    done
    
    echo "Installing: $apt_packages"
    ${SUDO_CMD} apt-get update
    ${SUDO_CMD} apt-get install -y $apt_packages
}

# ==============================================================================
# IMAGE MANAGEMENT
# ==============================================================================

download_os_image() {
    local choice
    choice=$(dialog --title "Download OS Image" --menu "Select download option:" 15 70 9 \
        "1" "Download All Compatible Images" \
        "2" "Jessie 2017 Full" \
        "3" "Jessie 2017 Lite" \
        "4" "Stretch 2018 Full" \
        "5" "Stretch 2018 Lite" \
        "6" "Buster 2020 Full (Experimental)" \
        "7" "Buster 2020 Lite (Experimental)" \
        "8" "Bullseye 2022 Full (Experimental)" \
        "9" "Bullseye 2022 Lite (Experimental)" \
        2>&1 >/dev/tty)
    
    [ -z "$choice" ] && return
    
    case $choice in
        1) download_all_images ;;
        2) download_single_image "jessie_2017_full" ;;
        3) download_single_image "jessie_2017_lite" ;;
        4) download_single_image "stretch_2018_full" ;;
        5) download_single_image "stretch_2018_lite" ;;
        6) download_single_image "buster_2020_full" ;;
        7) download_single_image "buster_2020_lite" ;;
        8) download_single_image "bullseye_2022_full" ;;
        9) download_single_image "bullseye_2022_lite" ;;
    esac
}

download_all_images() {
    dialog --title "Download All Images" --infobox "This will download all compatible OS images...\nThis may take a long time!" 8 50
    sleep 2
    
    for key in "${!OS_CATALOG[@]}"; do
        IFS='|' read -r version date kernel type url <<< "${OS_CATALOG[$key]}"
        echo "Downloading: $key"
        download_and_prepare_image "$key" "$url" "$kernel" "$version"
    done
    
    dialog --msgbox "All compatible images downloaded!" 8 40
}

download_single_image() {
    local os_key=$1
    IFS='|' read -r version date kernel type url <<< "${OS_CATALOG[$os_key]}"
    download_and_prepare_image "$os_key" "$url" "$kernel" "$version"
}

download_and_prepare_image() {
    local os_key=$1
    local url=$2
    local kernel_version=$3
    local os_version=$4
    
    local filename=$(basename "$url")
    local dest_file="${CACHE_DIR}/${filename}"
    local final_image="${IMAGES_DIR}/${os_key}.img"
    
    # CORREZIONE: Controlla prima se l'immagine finale esiste già
    if [ -f "$final_image" ]; then
        dialog --msgbox "Image already available: $final_image" 8 50
        return 0
    fi
    
    # Se l'archivio esiste, chiedi se re-scaricare
    if [ -f "$dest_file" ]; then
        if dialog --yesno "Archive already downloaded. Re-download?" 8 40; then
            rm -f "$dest_file"
        else
            # Se dice no, estrai dall'archivio esistente
            extract_and_prepare_image "$dest_file" "$os_key" "$kernel_version" "$os_version"
            return
        fi
    fi
    
    clear
    echo "=========================================="
    echo " Downloading OS Image"
    echo "=========================================="
    echo "File: $filename"
    echo "This may take several minutes..."
    echo ""
    
    if command -v curl &> /dev/null; then
        curl -L --progress-bar -o "$dest_file" "$url"
    else
        wget --progress=bar:force -O "$dest_file" "$url"
    fi
    
    if [ $? -ne 0 ] || [ ! -f "$dest_file" ] || [ ! -s "$dest_file" ]; then
        dialog --msgbox "Download failed! Check your internet connection." 8 50
        return 1
    fi
    
    extract_and_prepare_image "$dest_file" "$os_key" "$kernel_version" "$os_version"
}


extract_and_prepare_image() {
    local archive=$1
    local os_key=$2
    local kernel_version=$3
    local os_version=$4
    
    echo "Extracting image..."
    
    local extracted_img=""
    
    if [[ "$archive" == *.xz ]]; then
        echo "Extracting XZ archive..."
        xz -dk "$archive"
        extracted_img="${archive%.xz}"
    elif [[ "$archive" == *.zip ]]; then
        echo "Extracting ZIP archive..."
        unzip -o "$archive" -d "$TEMP_DIR/"
        extracted_img=$(find "$TEMP_DIR" -name "*.img" | head -1)
    fi
    
    if [ -z "$extracted_img" ] || [ ! -f "$extracted_img" ]; then
        dialog --msgbox "Failed to extract image!" 8 40
        return 1
    fi
    
    local final_image="${IMAGES_DIR}/${os_key}.img"
    
    echo "Preparing final image..."
    cp "$extracted_img" "$final_image"
    
    download_kernel "$kernel_version" "$os_version"
    
    # CORREZIONE: Verifica che il database immagini esista
    mkdir -p "${CONFIGS_DIR}"
    if [ ! -f "${CONFIGS_DIR}/images.db" ]; then
        echo "# Images Database" > "${CONFIGS_DIR}/images.db"
        echo "# Format: OS_KEY|IMAGE_PATH|KERNEL_NAME|TIMESTAMP" >> "${CONFIGS_DIR}/images.db"
    fi
    
    # CORREZIONE: Scrittura corretta del database immagini
    echo "${os_key}|${final_image}|kernel-qemu-${kernel_version}-${os_version}|$(date +%s)" >> "${CONFIGS_DIR}/images.db"
    
    echo "Image prepared successfully: $final_image"
    sleep 2
    
    rm -f "$extracted_img"
    [ -d "$TEMP_DIR" ] && find "$TEMP_DIR" -name "*.img" -delete
}

download_kernel() {
    local kernel_version=$1
    local os_version=$2
    
    local kernel_file="${KERNELS_DIR}/kernel-qemu-${kernel_version}-${os_version}"
    
    if [ ! -f "$kernel_file" ]; then
        echo "Downloading kernel for $os_version ($kernel_version)..."
        
        # Gestione intelligente dei kernel per tutte le versioni
        case $os_version in
            jessie)
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34-jessie" || \
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34"
                ;;
            stretch)
                # Per Stretch, usa il kernel jessie che è più stabile
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34-jessie" || \
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34"
                ;;
            buster)
                # Per Buster, prova diversi kernel in ordine di compatibilità
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.19.50-buster" || \
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34-jessie" || \
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34"
                ;;
            bullseye)
                # Per Bullseye, usa fallback al kernel buster o jessie
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-5.10.63-bullseye" || \
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.19.50-buster" || \
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34-jessie" || \
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34"
                ;;
            *)
                # Fallback generico al kernel jessie per versioni sconosciute
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34-jessie" || \
                wget -q -O "$kernel_file" "${KERNEL_REPO}/kernel-qemu-4.4.34"
                ;;
        esac
        
        if [ ! -f "$kernel_file" ] || [ ! -s "$kernel_file" ]; then
            echo "Failed to download kernel!"
            return 1
        fi
    fi
    
    echo "Kernel ready: $kernel_file"
}

# ==============================================================================
# INSTANCE MANAGEMENT
# ==============================================================================

#!/bin/bash

# ==============================================================================
# CORREZIONI PRINCIPALI
# ==============================================================================

# 1. CORREZIONE CREAZIONE ISTANZE - Database malformato
create_instance() {
    local name
    name=$(dialog --inputbox "Instance name:" 8 40 "rpi-$(date +%Y%m%d)" 2>&1 >/dev/tty)
    [ -z "$name" ] && return
    
    local images=$(ls -1 "$IMAGES_DIR"/*.img 2>/dev/null)
    if [ -z "$images" ]; then
        dialog --msgbox "No images available! Please download an OS image first." 8 50
        return
    fi
    
    local img_list=""
    local counter=1
    while IFS= read -r img; do
        local basename=$(basename "$img")
        img_list+="$counter \"$basename\" "
        ((counter++))
    done <<< "$images"
    
    local img_choice
    img_choice=$(eval dialog --title \"Select Image\" --menu \"Choose base image:\" 15 60 8 $img_list 2>&1 >/dev/tty)
    [ -z "$img_choice" ] && return
    
    local selected_image=$(echo "$images" | sed -n "${img_choice}p")
    
    local memory
    memory=$(dialog --inputbox "Memory (MB):" 8 40 "$DEFAULT_MEMORY" 2>&1 >/dev/tty)
    [ -z "$memory" ] && memory="$DEFAULT_MEMORY"
    
    local ssh_port
    ssh_port=$(dialog --inputbox "SSH Port:" 8 40 "$DEFAULT_SSH_PORT" 2>&1 >/dev/tty)
    [ -z "$ssh_port" ] && ssh_port="$DEFAULT_SSH_PORT"
    
    local instance_img="${IMAGES_DIR}/${name}.img"
    echo "Creating instance image..."
    cp "$selected_image" "$instance_img"
    
    # CORREZIONE: Lettura corretta del kernel dal database immagini
    local kernel_name=""
    if [ -f "${CONFIGS_DIR}/images.db" ]; then
        kernel_name=$(grep "$(basename "$selected_image" .img)" "${CONFIGS_DIR}/images.db" 2>/dev/null | cut -d'|' -f3 | head -1)
    fi
    
    # Fallback se non trovato nel database
    if [ -z "$kernel_name" ]; then
        kernel_name="kernel-qemu-4.4.34-jessie"
    fi
    
    local instance_id=$(date +%s)
    
    # CORREZIONE: Scrittura corretta in una sola riga
    echo "${instance_id}|${name}|${instance_img}|${kernel_name}|${memory}|${ssh_port}|created|$(date +%s)" >> "$INSTANCES_DB"
    
    dialog --msgbox "Instance '$name' created successfully!\n\nID: $instance_id" 10 50
    
    if dialog --yesno "Start instance now?" 8 30; then
        launch_instance "$instance_id"
    fi
}

list_instances() {
    local instances=""
    local counter=1
    local instance_ids=()
    
    while IFS='|' read -r id name image kernel memory ssh_port status created; do
        [[ "$id" =~ ^# ]] && continue
        [[ -z "$id" ]] && continue
        instances+="$counter \"$name [$status] (Port: $ssh_port)\" "
        instance_ids+=("$id")
        ((counter++))
    done < "$INSTANCES_DB"
    
    if [ -z "$instances" ]; then
        dialog --msgbox "No instances found!" 8 30
        return
    fi
    
    local choice
    choice=$(eval dialog --title \"Instances\" --menu \"Select instance:\" 15 70 8 $instances 2>&1 >/dev/tty)
    [ -z "$choice" ] && return
    
    local selected_id="${instance_ids[$((choice-1))]}"
    manage_instance_by_id "$selected_id"
}

manage_instance_by_id() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    
    if [ -z "$instance_data" ]; then
        dialog --msgbox "Instance not found!" 8 30
        return
    fi
    
    IFS='|' read -r id name image kernel memory ssh_port status created <<< "$instance_data"
    
    local action
    action=$(dialog --title "Instance: $name" --menu "Select action:" 15 50 6 \
        "1" "Start" \
        "2" "Stop" \
        "3" "SSH Connect" \
        "4" "Clone" \
        "5" "Delete" \
        "6" "Properties" \
        2>&1 >/dev/tty)
    
    case $action in
        1) launch_instance "$id" ;;
        2) stop_instance "$id" ;;
        3) connect_ssh "$ssh_port" ;;
        4) clone_instance "$id" ;;
        5) delete_instance "$id" ;;
        6) show_properties "$id" ;;
    esac
}

# ==============================================================================
# QEMU LAUNCHER - FIXED NETWORKING AND PERFORMANCE
# ==============================================================================

launch_instance() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    
    if [ -z "$instance_data" ]; then
        dialog --msgbox "Instance not found!" 8 30
        return 1
    fi
    
    IFS='|' read -r id name image kernel_name memory ssh_port status created <<< "$instance_data"
    
    if pgrep -f "$image" > /dev/null; then
        dialog --msgbox "Instance already running!" 8 30
        return
    fi
    
    local kernel_file="${KERNELS_DIR}/${kernel_name}"
    if [ ! -f "$kernel_file" ]; then
        kernel_file=$(ls -1 "$KERNELS_DIR"/kernel-qemu-* | head -1)
    fi
    
    if [ -z "$kernel_file" ] || [ ! -f "$kernel_file" ]; then
        dialog --msgbox "Kernel not found!" 8 30
        return 1
    fi
    
    # CORREZIONE: Rimuovi mount/unmount che causano problemi
    # Non montare l'immagine per avviarla, QEMU la gestisce direttamente
    
    clear
    echo "=========================================="
    echo " Starting Instance: $name"
    echo "=========================================="
    echo "Image: $(basename "$image")"
    echo "Kernel: $(basename "$kernel_file")"
    echo "Memory: ${memory}MB"
    echo "SSH Port: ${ssh_port}"
    echo ""
    echo "IMPORTANT: Boot may take 2-3 minutes!"
    echo "Default login: pi / raspberry"
    echo ""
    echo "To connect via SSH (after boot):"
    echo "ssh -p ${ssh_port} pi@localhost"
    echo ""
    echo "To exit QEMU: Press Ctrl+A, then X"
    echo "=========================================="
    echo ""
    echo "Starting QEMU with optimized settings..."
    sleep 3
    
    # Determina la versione OS dal nome del kernel per parametri appropriati
    local os_type="jessie"  # default fallback
    if [[ "$kernel_name" == *"stretch"* ]]; then
        os_type="stretch"
    elif [[ "$kernel_name" == *"buster"* ]]; then
        os_type="buster"
    elif [[ "$kernel_name" == *"bullseye"* ]]; then
        os_type="bullseye"
    fi
    
    # Parametri QEMU base per tutte le versioni (configurazione che funzionava)
    # local qemu_args=(
    #     -kernel "$kernel_file"
    #     -cpu arm1176
    #     -m "$memory"
    #     -M versatilepb
    #     -serial stdio
    #     -drive format=raw,file="$image",if=scsi,index=0
    #     -netdev user,id=net0,hostfwd=tcp::"${ssh_port}"-:22
    #     -device rtl8139,netdev=net0
    #     -no-reboot
    # )
    local qemu_args=(
        -kernel "$kernel_file"
        -cpu arm1176
        -m "$memory"
        -M versatilepb
        -serial stdio
        -drive format=raw,file="$image",if=scsi,index=0
        -nic user,hostfwd=tcp::"${DEFAULT_SSH_PORT}"-:22 \
        -no-reboot
    )

    # Parametri kernel specifici per versione
    case $os_type in
        jessie|stretch)
            qemu_args+=(-append "root=/dev/sda2 rootfstype=ext4 rw")
            ;;
        buster)
            qemu_args+=(-append "dwc_otg.lpm_enable=0 console=ttyAMA0,115200 console=tty1 root=/dev/sda2 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait")
            ;;
        bullseye)
            qemu_args+=(-append "dwc_otg.lpm_enable=0 console=ttyAMA0,115200 console=tty1 root=/dev/sda2 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait quiet")
            ;;
    esac
    
    # Avviso per versioni sperimentali
    if [[ "$os_type" == "buster" || "$os_type" == "bullseye" ]]; then
        echo "WARNING: $os_type is experimental and may not boot properly!"
        echo "If boot fails, use Jessie or Stretch for better compatibility."
        echo ""
        sleep 2
    fi
    
    # Esegui QEMU con tentativo KVM (fallback senza KVM)
    qemu-system-arm "${qemu_args[@]}" -enable-kvm 2>/dev/null || \
    qemu-system-arm "${qemu_args[@]}"
    
    local qemu_exit=$?
    
    if [ $qemu_exit -ne 0 ]; then
        echo ""
        echo "QEMU exited with code: $qemu_exit"
    fi
    
    echo ""
    read -p "Press ENTER to return to menu..."
}

stop_instance() {
    local instance_id=$1
    
    local qemu_pids=$(pgrep -f "qemu-system-arm.*$(basename "$(grep "^$instance_id" "$INSTANCES_DB" | cut -d'|' -f3)")" || true)
    
    if [ -n "$qemu_pids" ]; then
        echo "$qemu_pids" | xargs kill -TERM 2>/dev/null || true
        dialog --msgbox "Instance stopped." 8 30
    else
        dialog --msgbox "Instance not running!" 8 30
    fi
}

connect_ssh() {
    local port=$1
    dialog --msgbox "Connecting to SSH on port $port...\n\nPress OK to continue" 10 50
    clear
    ssh -p "$port" -o StrictHostKeyChecking=no pi@localhost
    read -p "Press ENTER to return to menu..."
}

clone_instance() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel_name memory ssh_port status created <<< "$instance_data"
    
    local new_name
    new_name=$(dialog --inputbox "Clone name:" 8 40 "${name}-clone" 2>&1 >/dev/tty)
    [ -z "$new_name" ] && return
    
    local new_image="${IMAGES_DIR}/${new_name}.img"
    echo "Cloning instance..."
    cp "$image" "$new_image"
    
    local new_id=$(date +%s)
    echo "${new_id}|${new_name}|${new_image}|${kernel_name}|${memory}|$((ssh_port + 1))|created|$(date +%s)" >> "$INSTANCES_DB"
    
    dialog --msgbox "Instance cloned successfully!" 8 40
}

delete_instance() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel_name memory ssh_port status created <<< "$instance_data"
    
    if dialog --yesno "Delete instance '$name'?\n\nThis will remove the image file!" 10 50; then
        rm -f "$image"
        sed -i "/^$instance_id/d" "$INSTANCES_DB"
        dialog --msgbox "Instance deleted!" 8 30
    fi
}

show_properties() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id" "$INSTANCES_DB")
    IFS='|' read -r id name image kernel_name memory ssh_port status created <<< "$instance_data"
    
    local props=""
    props+="Instance Properties:\n\n"
    props+="Name: $name\n"
    props+="ID: $id\n"
    props+="Image: $(basename "$image")\n"
    props+="Kernel: $kernel_name\n"
    props+="Memory: ${memory}MB\n"
    props+="SSH Port: $ssh_port\n"
    props+="Status: $status\n"
    props+="Created: $(date -d "@$created" 2>/dev/null || echo "$created")\n"
    
    if [ -f "$image" ]; then
        local size=$(du -h "$image" | cut -f1)
        props+="Image Size: $size\n"
    fi
    
    dialog --title "Properties" --msgbox "$props" 15 50
}

# ==============================================================================
# QUICK START - SAME NETWORK CONFIG AS INSTANCES
# ==============================================================================

quick_start() {
    dialog --title "Quick Start" --infobox "Preparing quick start..." 5 40
    
    local jessie_image="${IMAGES_DIR}/jessie_2017_full.img"
    local jessie_kernel="${KERNELS_DIR}/kernel-qemu-4.4.34-jessie"
    
    if [ ! -f "$jessie_image" ]; then
        dialog --msgbox "Jessie image not found. Downloading..." 8 50
        download_jessie_default
    fi
    
    if [ ! -f "$jessie_image" ]; then
        dialog --msgbox "Failed to prepare Jessie image!" 8 40
        return
    fi
    
    if [ ! -f "$jessie_kernel" ]; then
        dialog --msgbox "Kernel not found!" 8 30
        return
    fi
    
    clear
    echo "=========================================="
    echo " Quick Start - Raspbian Jessie 2017"
    echo "=========================================="
    echo "Memory: ${DEFAULT_MEMORY}MB"
    echo "SSH Port: ${DEFAULT_SSH_PORT}"
    echo ""
    echo "Default credentials:"
    echo "Username: pi"
    echo "Password: raspberry"
    echo ""
    echo "To connect via SSH (after boot):"
    echo "ssh -p ${DEFAULT_SSH_PORT} pi@localhost"
    echo ""
    echo "IMPORTANT: Boot may take 2-3 minutes!"
    echo "To exit QEMU: Press Ctrl+A, then X"
    echo "=========================================="
    echo ""
    echo "Starting QEMU with optimized settings..."
    sleep 3
    
    # Parametri QEMU ottimizzati per Jessie (configurazione originale)
    # local qemu_args=(
    #     -kernel "$jessie_kernel"
    #     -cpu arm1176
    #     -m "$DEFAULT_MEMORY"
    #     -M versatilepb
    #     -serial stdio
    #     -append "root=/dev/sda2 rootfstype=ext4 rw"
    #     -drive format=raw,file="$jessie_image",if=scsi,index=0
    #     -netdev user,id=net0,hostfwd=tcp::"${DEFAULT_SSH_PORT}"-:22
    #     -device rtl8139,netdev=net0
    #     -no-reboot
    # )
    local qemu_args=(
        -kernel "$jessie_kernel"
        -cpu arm1176
        -m "$DEFAULT_MEMORY"
        -M versatilepb
        -serial stdio
        -append "root=/dev/sda2 rootfstype=ext4 rw"
        -drive format=raw,file="$jessie_image",if=scsi,index=0
        -nic user,hostfwd=tcp::"${DEFAULT_SSH_PORT}"-:22 \
        -no-reboot
    )    
    
    # Esegui QEMU con tentativo KVM (fallback senza KVM)
    qemu-system-arm "${qemu_args[@]}" -enable-kvm 2>/dev/null || \
    qemu-system-arm "${qemu_args[@]}"
    
    local qemu_exit=$?
    
    if [ $qemu_exit -ne 0 ]; then
        echo ""
        echo "QEMU exited with code: $qemu_exit"
    fi
    
    echo ""
    read -p "Press ENTER to return to menu..."
}

download_jessie_default() {
    local url="http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/2017-04-10-raspbian-jessie.zip"
    download_and_prepare_image "jessie_2017_full" "$url" "4.4.34" "jessie"
}

# ==============================================================================
# PERFORMANCE TIPS
# ==============================================================================

show_performance_tips() {
    local tips=""
    tips+="QEMU Performance Optimization Tips:\n\n"
    tips+="1. CPU Cores: QEMU ARM emulation uses single core only\n"
    tips+="2. KVM: ARM KVM not available on x86 hosts\n"
    tips+="3. Memory: 512MB is optimal balance\n"
    tips+="4. Disk: Use raw format (already configured)\n"
    tips+="5. Network: rtl8139 provides best compatibility\n\n"
    tips+="Host System Optimizations:\n"
    tips+="- Ensure adequate RAM (4GB+ recommended)\n"
    tips+="- Close unnecessary applications\n"
    tips+="- Use SSD storage for images\n"
    tips+="- Disable swap if possible\n\n"
    tips+="Known Limitations:\n"
    tips+="- ARM emulation is inherently slower than native\n"
    tips+="- GPU acceleration not available\n"
    tips+="- Limited to single CPU core\n\n"
    tips+="Recommended OS Versions for QEMU:\n"
    tips+="✓ Raspbian Jessie 2017 (Best compatibility)\n"
    tips+="✓ Raspbian Stretch 2018 (Good compatibility)\n"
    tips+="⚠ Raspbian Buster 2020 (Experimental)\n"
    tips+="⚠ Raspbian Bullseye 2022 (Experimental)\n\n"
    tips+="Note: Newer versions may fail to boot due to\n"
    tips+="DTB/kernel compatibility issues with QEMU ARM.\n"
    
    dialog --title "Performance Tips" --msgbox "$tips" 22 70
}

# ==============================================================================
# WORKSPACE MANAGEMENT
# ==============================================================================

clean_workspace() {
    if dialog --yesno "This will remove ALL data including:\n- Images\n- Instances\n- Cache\n- Logs\n\nAre you sure?" 12 50; then
        echo "Cleaning workspace..."
        
        # Stop any running instances
        pkill -f qemu-system-arm 2>/dev/null || true
        
        # Remove workspace directory
        rm -rf "$WORK_DIR"
        
        dialog --msgbox "Workspace cleaned successfully!\nThe program will now exit." 8 40
        exit 0
    fi
}

# ==============================================================================
# UTILITIES
# ==============================================================================

system_diagnostics() {
    local diag_info=""
    
    diag_info+="QEMU Version:\n$(qemu-system-arm --version | head -1)\n\n"
    diag_info+="Host CPU: $(lscpu | grep "Model name" | cut -d: -f2 | xargs)\n"
    diag_info+="Host RAM: $(free -h | grep "Mem:" | awk '{print $2}')\n\n"
    diag_info+="Running Instances: $(pgrep -c qemu-system-arm || echo 0)\n\n"
    diag_info+="Disk Usage:\n"
    diag_info+="Images: $(du -sh "$IMAGES_DIR" 2>/dev/null | awk '{print $1}')\n"
    diag_info+="Cache: $(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')\n\n"
    diag_info+="Available Images: $(ls -1 "$IMAGES_DIR"/*.img 2>/dev/null | wc -l)\n"
    diag_info+="Available Kernels: $(ls -1 "$KERNELS_DIR"/kernel-* 2>/dev/null | wc -l)\n\n"
    
    # Check KVM availability
    if [ -r /dev/kvm ]; then
        diag_info+="KVM: Available (but not usable for ARM emulation)\n"
    else
        diag_info+="KVM: Not available\n"
    fi
    
    # Check disk space
    local free_space=$(df -h "$WORK_DIR" | tail -1 | awk '{print $4}')
    diag_info+="Free space: $free_space\n"
    
    dialog --title "System Diagnostics" --msgbox "$diag_info" 20 70
}

view_logs() {
    local log_files=$(ls -t "$LOGS_DIR"/*.log 2>/dev/null | head -10)
    
    if [ -z "$log_files" ]; then
        dialog --msgbox "No logs found!" 8 30
        return
    fi
    
    local log_menu=""
    local counter=1
    while IFS= read -r log; do
        local basename=$(basename "$log")
        log_menu+="$counter \"$basename\" "
        ((counter++))
    done <<< "$log_files"
    
    local log_choice
    log_choice=$(eval dialog --title \"Select Log\" --menu \"Choose log file:\" 15 70 10 $log_menu 2>&1 >/dev/tty)
    [ -z "$log_choice" ] && return
    
    local selected_log=$(echo "$log_files" | sed -n "${log_choice}p")
    
    dialog --title "Log: $(basename "$selected_log")" --textbox "$selected_log" 20 80
}

cleanup_and_exit() {
    #clear
    log INFO "QEMU RPi Manager terminated"
    echo "Thank you for using QEMU Raspberry Pi Manager!"
    exit 0
}

# ==============================================================================
# NETWORK TROUBLESHOOTING
# ==============================================================================

network_test() {
    local instance_id=$1
    local instance_data=$(grep "^$instance_id|" "$INSTANCES_DB")
    
    if [ -z "$instance_data" ]; then
        dialog --msgbox "Instance not found!" 8 30
        return
    fi
    
    IFS='|' read -r id name image kernel memory ssh_port status created <<< "$instance_data"
    
    echo "Testing network connectivity for instance: $name"
    echo "SSH Port: $ssh_port"
    echo ""
    
    # Test if port is listening
    if netstat -an | grep -q ":${ssh_port}.*LISTEN"; then
        echo "✓ QEMU is forwarding port $ssh_port"
    else
        echo "✗ Port $ssh_port not listening"
    fi
    
    # Test SSH connection
    echo "Testing SSH connection..."
    timeout 5 nc -z localhost "$ssh_port" && echo "✓ SSH port is reachable" || echo "✗ SSH port not reachable"
    
    read -p "Press ENTER to continue..."
}

# ==============================================================================
# ERROR HANDLING
# ==============================================================================

handle_error() {
    local exit_code=$?
    local line_num=${1:-0}
    
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 130 ]; then
        return
    fi
    
    log ERROR "Error occurred at line $line_num with exit code $exit_code"
    
    if command -v dialog &> /dev/null; then
        dialog --msgbox "An error occurred!\n\nLine: $line_num\nCode: $exit_code\n\nCheck logs for details." 10 50
    else
        echo "Error at line $line_num (exit code: $exit_code)"
    fi
}

trap 'handle_error $LINENO' ERR
trap 'cleanup_and_exit' EXIT INT TERM

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    if ! init_workspace; then
        echo "Failed to initialize workspace"
        exit 1
    fi
    
    log_init
    
    if ! check_dialog; then
        echo "Dialog is required but not available"
        exit 1
    fi
    
    if ! check_requirements; then
        echo "Failed to check/install requirements"
        exit 1
    fi
    
    while true; do
        choice=$(show_main_menu)
        
        case $choice in
            1) quick_start ;;
            2) create_instance ;;
            3) list_instances ;;
            4) download_os_image ;;
            5) system_diagnostics ;;
            6) view_logs ;;
            7) show_performance_tips ;;
            8) clean_workspace ;;
            0|"") break ;;
            *) dialog --msgbox "Invalid option!" 8 30 ;;
        esac
    done
    
    cleanup_and_exit
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

SUDO_CMD=""
if [ "$EUID" -ne 0 ]; then
    SUDO_CMD="sudo"
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "QEMU Raspberry Pi Manager v2.0.4 - Fixed Network & Performance"
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -h, --help      Show this help"
            echo "  -v, --verbose   Enable verbose output"
            echo "  -d, --debug     Enable debug mode"
            echo ""
            echo "Features:"
            echo "  - Fixed network configuration for all instances"
            echo "  - Optimized performance settings"
            echo "  - Compatible OS versions only (Jessie/Stretch)"
            echo "  - Performance tips and diagnostics"
            exit 0
            ;;
        -v|--verbose)
            export VERBOSE=1
            shift
            ;;
        -d|--debug)
            export DEBUG=1
            export VERBOSE=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    if ! sudo -n true 2>/dev/null; then
        echo "=================================================="
        echo " QEMU Raspberry Pi Manager v2.0.4"
        echo " Fixed Network & Performance Edition"
        echo "=================================================="
        echo ""
        echo "Sudo privileges are required for:"
        echo "  - Package installation"
        echo "  - Mounting/unmounting images"
        echo ""
        echo "Press ENTER to continue or Ctrl+C to exit..."
        read -r
    fi
fi

main "$@"