#!/bin/bash

TARGET_DIR="/var/log/debug-zram"
MAX_SIZE_MB=400
FILE_SIZE_KB=1024  # Each file will be ~1MB

check_dir() {
    echo "[+] Checking if $TARGET_DIR exists and is mounted..."
    if [ ! -d "$TARGET_DIR" ]; then
        echo "[!] Directory does not exist. Creating it..."
        mkdir -p "$TARGET_DIR"
        echo "[✔] Directory created."
    fi

    mountpoint -q "$TARGET_DIR"
    if [ $? -ne 0 ]; then
        echo "[⚠️] Warning: $TARGET_DIR is not a mountpoint. You might be writing to disk instead of zram."
    else
        echo "[✔] Directory is mounted (good zram citizen detected)."
    fi
}

generate_files() {
    echo "Generating random files in $TARGET_DIR until it reaches ${MAX_SIZE_MB}MB..."

    i=0
    while true; do
        dd if=/dev/urandom of="$TARGET_DIR/random_$i.log" bs=1K count=$FILE_SIZE_KB status=none
        current_size=$(du -sm "$TARGET_DIR" | awk '{print $1}')
        if [ "$current_size" -ge "$MAX_SIZE_MB" ]; then
            echo "Reached $current_size MB. Stopping."
            break
        fi
        ((i++))
    done
}

# Execute functions
check_dir
generate_files