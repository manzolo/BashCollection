# ==============================================================================
# IMAGE MANAGEMENT
# ==============================================================================

download_os_image() {
    local choice
    choice=$(dialog --title "Download OS Image" --menu "Select OS to download:" 15 70 9 \
        "1" "Download All Images" \
        "2" "Jessie 2017 Full (Best compatibility)" \
        "3" "Jessie 2017 Lite" \
        "4" "Stretch 2018 Full" \
        "5" "Stretch 2018 Lite" \
        "6" "Buster 2020 Full" \
        "7" "Buster 2020 Lite" \
        "8" "Bullseye 2022 Full" \
        "9" "Bullseye 2022 Lite" \
        "10" "Bookworm 2025 Full" \
        "11" "Bookworm 2025 Lite" \
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
        10) download_single_image "bookworm_2025_full" ;;
        11) download_single_image "bookworm_2025_lite" ;;
    esac
}

download_all_images() {
    dialog --title "Download All Images" --infobox "Downloading all OS images...\nThis will take some time!" 8 50
    sleep 2
    
    for key in "${!OS_CATALOG[@]}"; do
        IFS='|' read -r version date kernel type url <<< "${OS_CATALOG[$key]}"
        echo "Downloading: $key"
        download_and_prepare_image "$key" "$url" "$kernel" "$version"
    done
    
    dialog --msgbox "All images downloaded!" 8 40
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
    
    if [ -f "$final_image" ]; then
        dialog --msgbox "Image already exists: $final_image" 8 50
        return 0
    fi
    
    if [ -f "$dest_file" ]; then
        if dialog --yesno "Archive already downloaded. Re-download?" 8 40; then
            rm -f "$dest_file"
        else
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
        dialog --msgbox "Download failed!" 8 50
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
    
    # Download kernel
    download_kernel_version "$kernel_version"
    
    mkdir -p "${CONFIGS_DIR}"
    if [ ! -f "${CONFIGS_DIR}/images.db" ]; then
        echo "# Images Database" > "${CONFIGS_DIR}/images.db"
        echo "# Format: OS_KEY|IMAGE_PATH|KERNEL_NAME|TIMESTAMP" >> "${CONFIGS_DIR}/images.db"
    fi
    
    echo "${os_key}|${final_image}|kernel-qemu-${kernel_version}-${os_version}|$(date +%s)" >> "${CONFIGS_DIR}/images.db"
    
    echo "Image prepared: $final_image"
    sleep 2
    
    rm -f "$extracted_img"
    [ -d "$TEMP_DIR" ] && find "$TEMP_DIR" -name "*.img" -delete
}

download_jessie_default() {
    local url="http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/2017-04-10-raspbian-jessie.zip"
    download_and_prepare_image "jessie_2017_full" "$url" "4.4.34" "jessie"
}