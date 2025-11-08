#!/bin/bash

# Abilita il tracciamento degli errori. Lo script terminerà immediatamente se un comando fallisce.
set -e

# Funzione per comprimere un'immagine in formato qcow2
# Accetta il percorso del file di input, il percorso del file di output e un flag per la cancellazione dell'originale
compress_image() {
    local input_image="$1"
    local output_image="$2"
    local delete_original="$3"

    # Verifica la presenza di qemu-img
    if ! command -v qemu-img &> /dev/null; then
        echo "Error: qemu-img is not installed. Please install it to use this script." >&2
        return 1
    fi

    # Verifica che il file di input esista
    if [ ! -f "$input_image" ]; then
        echo "Error: Input image file not found at $input_image." >&2
        return 1
    fi

    echo "Starting compression of '$input_image' to '$output_image'..."

    # Comprimi l'immagine.
    qemu-img convert -c -O qcow2 -p "$input_image" "$output_image"

    echo "Compression successful. New image created at '$output_image'."

    # Cancella l'originale e rinomina il file compresso, se richiesto
    if [ "$delete_original" = true ]; then
        # Se il file compresso e l'originale hanno lo stesso nome, non facciamo nulla
        if [ "$input_image" != "$output_image" ]; then
            echo "Deleting original file: '$input_image'"
            rm -f "$input_image"
            if [ $? -eq 0 ]; then
                echo "Original file deleted successfully."
            else
                echo "Warning: Failed to delete original file '$input_image'. Skipping." >&2
            fi
        fi
    fi
}

# Funzione principale per processare una directory
process_directory() {
    local directory="$1"
    local delete_original="$2"

    if [ -z "$directory" ]; then
        echo "Error: Directory path is required." >&2
        echo "Usage: $0 <directory> [--delete-original]" >&2
        exit 1
    fi

    if [ ! -d "$directory" ]; then
        echo "Error: Directory not found at $directory." >&2
        exit 1
    fi

    echo "Processing directory: '$directory'"
    echo "Delete original files: $delete_original"
    echo "----------------------------------------"

    # Abilita nullglob per evitare che il ciclo for processi un pattern come stringa se non trova file
    shopt -s nullglob

    # Usa un array per gestire i file in modo sicuro (anche con spazi nei nomi)
    local files=( "$directory"/*.{img,qcow2,raw} )
    if [ ${#files[@]} -eq 0 ]; then
        echo "No image files (.img, .qcow2, .raw) found in '$directory'."
        return
    fi
    
    for input_file in "${files[@]}"; do
        # Determina il nome del file di output
        local output_file=""
        local filename=$(basename -- "$input_file")
        local dirname=$(dirname -- "$input_file")
        local extension="${filename##*.}"
        local base="${filename%.*}"

        if [ "$delete_original" = true ]; then
            # Se l'originale è già qcow2, lo comprimiamo in un file temporaneo
            if [ "$extension" = "qcow2" ]; then
                output_file="${dirname}/${base}_temp.qcow2"
            else
                # Altrimenti, il nome di output è direttamente quello finale
                output_file="${dirname}/${base}.qcow2"
            fi
        else
            output_file="${dirname}/${base}_compressed.qcow2"
        fi

        # Comprimi l'immagine
        compress_image "$input_file" "$output_file" "$delete_original"

        # Se abbiamo compresso in un file temporaneo, rinominiamolo
        if [ "$delete_original" = true ] && [ "$extension" = "qcow2" ]; then
            echo "Renaming '$output_file' to '${dirname}/${base}.qcow2'..."
            mv -f "$output_file" "${dirname}/${base}.qcow2"
            echo "Renaming complete."
        fi

        echo "----------------------------------------"
    done

    echo "Processing completed."
}

# Gestione degli argomenti
if [ $# -lt 1 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: $0 <directory> [--delete-original]"
    echo ""
    echo "Options:"
    echo "  <directory>         Directory containing the images to compress."
    echo "  --delete-original   Delete original files after compression and replace"
    echo "                      them with the compressed .qcow2 file."
    exit 0
fi

TARGET_DIR="$1"
DELETE_ORIGINAL=false

# Controlla se è stato specificato l'argomento per cancellare gli originali
if [ "$2" = "--delete-original" ]; then
    DELETE_ORIGINAL=true
elif [ $# -gt 2 ]; then
    echo "Error: Too many arguments." >&2
    exit 1
fi

# Esegui il processing della directory
process_directory "$TARGET_DIR" "$DELETE_ORIGINAL"

#./compress-qemu-hd-folder "/home/manzolo/Workspaces/qemu/storage/hd" --delete-original
