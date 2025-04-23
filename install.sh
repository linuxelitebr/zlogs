#!/bin/bash

set -e

SERVICE_NAME="zram-clean"
INSTALL_PATH="/usr/local/sbin"
SYSTEMD_PATH="/etc/systemd/system"
DEFAULT_LOG_DIR="/var/log/debug-zram"
DEFAULT_ZRAM_DEV="zram1"
ALGO="lzo"

REPO_RAW_BASE="https://raw.githubusercontent.com/linuxelitebr/zlogs/main"

function download_file() {
  local src="$1"
  local dest="$2"
  echo "[+] Downloading $src -> $dest"
  curl -sSL "$REPO_RAW_BASE/$src" -o "$dest"
  if [[ $? -ne 0 || ! -s "$dest" ]]; then
    echo "[✘] Failed to download $src"
    exit 1
  fi
  echo "[✔] $src installed"
}

# 1. Prompt for Zram Size
read -p "Enter zram size in M (e.g., 512, 1024, default is 512): " ZRAM_SIZE
ZRAM_SIZE=${ZRAM_SIZE:-512}

# 2. Prompt for Log Directory
read -p "Enter log directory path (default is $DEFAULT_LOG_DIR): " LOG_DIR_INPUT
LOG_DIR="${LOG_DIR_INPUT:-$DEFAULT_LOG_DIR}"

echo "[+] Installing zram log cleaner with systemd..."
echo "[+] Using log directory: $LOG_DIR"

# 3. Download and install the main cleaner script
sudo mkdir -p "$INSTALL_PATH" && \
download_file "clean-zram-logs.sh" "$INSTALL_PATH/clean-zram-logs.sh" && \
sudo chmod 755 "$INSTALL_PATH/clean-zram-logs.sh" && \
echo "[✔] Script installed at $INSTALL_PATH/clean-zram-logs.sh"

# 4. Create log directory if it doesn't exist
sudo mkdir -p "$LOG_DIR" && \
sudo chown root:root "$LOG_DIR" && \
sudo chmod 755 "$LOG_DIR" && \
echo "[✔] Log directory created at $LOG_DIR"

# 5. Download and install systemd unit, path, and timer
sudo mkdir -p "$SYSTEMD_PATH" && \
download_file "zram-clean.service" "$SYSTEMD_PATH/zram-clean.service" && \
download_file "zram-clean.path" "$SYSTEMD_PATH/zram-clean.path" && \
download_file "zram-clean.timer" "$SYSTEMD_PATH/zram-clean.timer" && \
echo "[✔] systemd units installed"

# 6. Update systemd files to use the custom log directory
sudo sed -i "s|/var/log/debug-zram|$LOG_DIR|g" "$SYSTEMD_PATH/zram-clean.service"
sudo sed -i "s|/var/log/debug-zram|$LOG_DIR|g" "$SYSTEMD_PATH/zram-clean.path"
echo "[✔] systemd units updated with custom log directory"

# 7. Prompt for threshold percentage
read -p "Enter threshold percentage for zram usage (default is 80): " THRESHOLD_INPUT
THRESHOLD=${THRESHOLD_INPUT:-80}
sudo sed -i "s|THRESHOLD=80|THRESHOLD=$THRESHOLD|g" "$INSTALL_PATH/clean-zram-logs.sh"
echo "[✔] Threshold set to $THRESHOLD%"

# 8. Reload systemd and enable services
sudo systemctl daemon-reexec && \
sudo systemctl daemon-reload && \
sudo systemctl enable zram-clean.path && \
sudo systemctl enable zram-clean.timer && \
sudo systemctl start zram-clean.path && \
echo "[✔] Path monitor and backup timer enabled and running"

# 8. (Optional) Setup rsyslog config for separate log file
if curl --output /dev/null --silent --head --fail "$REPO_RAW_BASE/rsyslog.d/30-zram-clean.conf"; then
  sudo mkdir -p /etc/rsyslog.d
  curl -sSL "$REPO_RAW_BASE/rsyslog.d/30-zram-clean.conf" -o /etc/rsyslog.d/30-zram-clean.conf
  
  # Update rsyslog config to use custom log directory
  sudo sed -i "s|/var/log/debug-zram|$LOG_DIR|g" /etc/rsyslog.d/30-zram-clean.conf
  
  sudo systemctl restart rsyslog
  echo "[✔] rsyslog configured for dedicated log file with custom directory"
fi

# 9. Setup ZRAM
# Function to remove existing zram device
remove_zram_device() {
    local zram_dev="$1"
    local zram_path="/dev/$zram_dev"
    local sys_path="/sys/block/$zram_dev"

    echo "[+] Removing existing zram device..."

    # Check if mounted and unmount
    if mount | grep -q "$zram_path"; then
        local mount_point=$(mount | grep "$zram_path" | awk '{print $3}')
        echo "[+] Unmounting $zram_path from $mount_point"
        umount "$zram_path" || {
            echo "❌ Failed to unmount. The device may be in use."
            return 1
        }
        echo "[+] Device unmounted."
    fi

    # Reset the device
    echo "[+] Resetting the device..."
    echo 1 > "$sys_path/reset" || {
        echo "❌ Failed to reset device."
        return 1
    }

    echo "[+] Device $zram_dev successfully removed."
    return 0
}

# Function to show zram device statistics
show_zram_stats() {
    local zram_dev="$1"
    local sys_path="/sys/block/$zram_dev"

    echo -e "\n📊 Zram usage stats for /dev/$zram_dev:"

    # Configured size
    echo -n "Configured size:     "
    if [ -f "$sys_path/disksize" ]; then
        cat "$sys_path/disksize" 2>/dev/null | numfmt --to=iec || echo "Unknown"
    else
        echo "Unknown (file not found)"
    fi

    # Check possible paths for usage statistics
    echo -n "Memory used (actual): "
    if [ -f "$sys_path/mem_used_total" ]; then
        cat "$sys_path/mem_used_total" 2>/dev/null | numfmt --to=iec || echo "Unknown"
    elif [ -f "$sys_path/mm_stat" ]; then
        # In some kernels, stats are in mm_stat
        awk '{print $3}' "$sys_path/mm_stat" 2>/dev/null | numfmt --to=iec || echo "Unknown"
    elif [ -f "$sys_path/stat" ]; then
        # Another alternative
        echo "Available, use 'zramctl' for detailed info"
    else
        echo "Unknown (stats file not found)"
    fi

    # Original data size
    echo -n "Original data size:  "
    if [ -f "$sys_path/orig_data_size" ]; then
        cat "$sys_path/orig_data_size" 2>/dev/null | numfmt --to=iec || echo "Unknown"
    elif [ -f "$sys_path/mm_stat" ]; then
        # In some kernels, stats are in mm_stat
        awk '{print $1}' "$sys_path/mm_stat" 2>/dev/null | numfmt --to=iec || echo "Unknown"
    else
        echo "Unknown (file not found)"
    fi

    # Use zramctl if available to show more statistics
    if command -v zramctl >/dev/null 2>&1; then
        echo -e "\nDetailed stats from zramctl:"
        zramctl "/dev/$zram_dev"
        echo
    fi
}

# Ask user for the device
read -p "Which zram device to use? (default: $DEFAULT_ZRAM_DEV): " ZRAM_DEV_INPUT
ZRAM_DEV="${ZRAM_DEV_INPUT:-$DEFAULT_ZRAM_DEV}"

# Remove /dev/ if the user typed it
ZRAM_DEV="${ZRAM_DEV#/dev/}"
ZRAM_DEV_PATH="/dev/$ZRAM_DEV"
SYS_DEV_PATH="/sys/block/$ZRAM_DEV"

# Check if device already exists
if [ -e "$SYS_DEV_PATH" ]; then
    echo "⚠️  Device /dev/$ZRAM_DEV already exists."
    read -p "Do you want to remove and recreate it? [y/N]: " RECREATE_RESPONSE

    if [[ "$RECREATE_RESPONSE" =~ ^[Yy]$ ]]; then
        remove_zram_device "$ZRAM_DEV" || {
            echo "❌ Failed to remove existing zram device. Exiting."
            exit 1
        }
    else
        echo "Operation cancelled. Exiting."
        exit 0
    fi
fi

echo "[+] Loading zram module"
modprobe zram num_devices=4 2>/dev/null || true

# Extract the numeric index of the zram device
DEV_INDEX="${ZRAM_DEV//[!0-9]/}"

# Alternative approach: use zramctl command directly
echo "[+] Creating zram device using zramctl"
if command -v zramctl >/dev/null 2>&1; then
    zramctl --find --size "${ZRAM_SIZE}M" --algorithm "$ALGO" || {
        echo "❌ Failed to create zram device with zramctl"
        exit 1
    }

    # Wait a moment to ensure device is ready
    sleep 1
else
    # If zramctl is not available, try the original method
    echo "[+] zramctl not available, trying alternative method"

    # Try to create device directly
    if [ ! -e "$SYS_DEV_PATH" ]; then
        # If device doesn't exist, try to create through sysfs files
        if [ -e "/sys/class/zram-control/hot_add" ]; then
            echo "[+] Using zram-control to create device"
            # Try without specifying a specific index
            cat /sys/class/zram-control/hot_add > /dev/null
        else
            echo "❌ Cannot create zram device: zram-control not available"
            exit 1
        fi
    fi

    # Configure the zram device that was found
    for zdev in /dev/zram*; do
        if [ "$zdev" == "$ZRAM_DEV_PATH" ]; then
            echo "[+] Configuring $zdev"
            echo "$ALGO" > "/sys/block/${zdev#/dev/}/comp_algorithm" 2>/dev/null || true
            echo "$((ZRAM_SIZE * 1024 * 1024))" > "/sys/block/${zdev#/dev/}/disksize" 2>/dev/null || true
            break
        fi
    done
fi

# Check if device exists now
if [ ! -e "$ZRAM_DEV_PATH" ]; then
    echo "❌ Failed to create or find zram device $ZRAM_DEV_PATH"
    echo "Available zram devices:"
    ls -l /dev/zram* 2>/dev/null || echo "None found"
    exit 1
fi

echo "[+] Formatting zram as ext4"
mkfs.ext4 -q -O ^has_journal "$ZRAM_DEV_PATH"

echo "[+] Mounting $ZRAM_DEV_PATH at $LOG_DIR"
mkdir -p "$LOG_DIR"
mount -t ext4 "$ZRAM_DEV_PATH" "$LOG_DIR"

echo "[+] Setting permissions"
# Use the current user or root as fallback
# First check if common log users exist
if id -u syslog &>/dev/null && getent group adm &>/dev/null; then
    chown syslog:adm "$LOG_DIR"
elif id -u root &>/dev/null; then
    chown root:root "$LOG_DIR"
else
    # Use current user as fallback
    current_user=$(whoami)
    current_group=$(id -gn)
    chown $current_user:$current_group "$LOG_DIR"
fi
chmod 750 "$LOG_DIR"

echo -e "\n✅ Zram device /dev/$ZRAM_DEV is ready and mounted at $LOG_DIR"

# Show statistics
show_zram_stats "$ZRAM_DEV"

# 10. (Optional) Setup rsyslog config for separate log file
if [ -f "rsyslog.d/30-zram-clean.conf" ]; then
  sudo mkdir -p /etc/rsyslog.d
  sudo install -Dm644 rsyslog.d/30-zram-clean.conf /etc/rsyslog.d/30-zram-clean.conf
  
  # Update rsyslog config to use custom log directory
  sudo sed -i "s|/var/log/debug-zram|$LOG_DIR|g" /etc/rsyslog.d/30-zram-clean.conf
  
  sudo systemctl restart rsyslog
  echo "[✔] rsyslog configured for dedicated log file with custom directory"
fi

# 11. Update clean-zram-logs.sh script to use the custom log directory
sudo sed -i "s|/var/log/debug-zram|$LOG_DIR|g" "$INSTALL_PATH/clean-zram-logs.sh"
echo "[✔] Clean script updated with custom log directory"

####################################

# 12. Setup persistent zram with systemd

# Function to setup persistent $DEFAULT_ZRAM_DEV with systemd
setup_persistent_zram() {
  local zram_size="$1"
  local log_dir="$2"
  local algo="$3"
  local zram_dev="$DEFAULT_ZRAM_DEV"

  echo "[+] Setting up persistent $DEFAULT_ZRAM_DEV device via systemd..."
  
  # Determine appropriate user and group for log directory
  local owner="root"
  local group="root"
  if id -u syslog &>/dev/null && getent group adm &>/dev/null; then
    owner="syslog"
    group="adm"
  fi
  
  # Create systemd service file for zram
  local zram_service_path="$SYSTEMD_PATH/$DEFAULT_ZRAM_DEV-setup.service"
  
  # Copy the service template and replace variables
  cat > "$zram_service_path" << 'EOL'
[Unit]
Description=Setup %ZRAM_DEV% device for log storage
DefaultDependencies=no
Before=local-fs.target
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStartPre=/sbin/modprobe zram


# Clean up any existing mounts and reset the device
ExecStart=/bin/bash -c 'if mountpoint -q %LOG_DIR%; then umount -f %LOG_DIR% || true; fi'
ExecStart=/bin/bash -c 'if [ -e /sys/block/%ZRAM_DEV%/reset ] && [ -e /dev/%ZRAM_DEV% ]; then echo 1 > /sys/block/%ZRAM_DEV%/reset || true; fi'
ExecStart=/bin/bash -c 'sleep 1'

# Create fresh zram with specific size and algorithm
ExecStart=/bin/bash -c 'if [ ! -e /dev/%ZRAM_DEV% ]; then \
    NEW_DEV=$(zramctl --find --size 512M --algorithm lzo --streams 4); \
    if [ "$NEW_DEV" != "/dev/%ZRAM_DEV%" ]; then \
        if [ -e /dev/%ZRAM_DEV% ]; then rm -f /dev/%ZRAM_DEV%; fi; \
        ln -sf "$NEW_DEV" /dev/%ZRAM_DEV%; \
    fi; \
else \
    zramctl /dev/%ZRAM_DEV% --size 512M --algorithm lzo --streams 4; \
fi'

ExecStart=/bin/bash -c 'mkfs.ext4 -q -O ^has_journal /dev/%ZRAM_DEV%'
ExecStart=/bin/bash -c 'mkdir -p %LOG_DIR%'
ExecStart=/bin/bash -c 'mount -t ext4 /dev/%ZRAM_DEV% %LOG_DIR%'
ExecStart=/bin/bash -c 'chown %OWNER%:%GROUP% %LOG_DIR% && chmod 750 %LOG_DIR%'

RemainAfterExit=yes

# Clean up on shutdown
ExecStop=/bin/bash -c 'if mountpoint -q %LOG_DIR%; then umount -f %LOG_DIR% || true; fi'
ExecStop=/bin/bash -c 'if [ -e /sys/block/%ZRAM_DEV%/reset ]; then echo 1 > /sys/block/%ZRAM_DEV%/reset || true; fi'

[Install]
WantedBy=local-fs.target
EOL

  # Replace variables in the service file
  sudo sed -i "s|%SIZE%|${zram_size}M|g" "$zram_service_path"
  sudo sed -i "s|%ALGO%|$algo|g" "$zram_service_path"
  sudo sed -i "s|%LOG_DIR%|$log_dir|g" "$zram_service_path"
  sudo sed -i "s|%OWNER%|$owner|g" "$zram_service_path"
  sudo sed -i "s|%GROUP%|$group|g" "$zram_service_path"
  sudo sed -i "s|%ZRAM_DEV%|$zram_dev|g" "$zram_service_path"
  
  # Enable and start the service
  sudo systemctl daemon-reload
  sudo systemctl enable $DEFAULT_ZRAM_DEV-setup.service
  
  # Check if $DEFAULT_ZRAM_DEV is already mounted
  if [ -e "/dev/$DEFAULT_ZRAM_DEV" ] && mount | grep -q "/dev/$DEFAULT_ZRAM_DEV"; then
    echo "[!] A $DEFAULT_ZRAM_DEV device is already mounted. The persistent service will take effect after reboot."
    echo "[!] To apply changes immediately, you may need to restart your system."
  else
    echo "[+] Starting $DEFAULT_ZRAM_DEV-setup service..."
    sudo systemctl start $DEFAULT_ZRAM_DEV-setup.service
    if [ $? -eq 0 ]; then
      echo "[✔] Persistent $DEFAULT_ZRAM_DEV device created and mounted at $log_dir"
    else
      echo "[✘] Failed to start $DEFAULT_ZRAM_DEV-setup service. Check with 'systemctl status $DEFAULT_ZRAM_DEV-setup.service'"
    fi
  fi
}

echo

read -p "Do you want to setup persistent $DEFAULT_ZRAM_DEV device via systemd? [y/N]: " PERSISTENT_ZRAM
if [[ "$PERSISTENT_ZRAM" =~ ^[Yy]$ ]]; then
  setup_persistent_zram "$ZRAM_SIZE" "$LOG_DIR" "$ALGO"
  SKIP_MANUAL_ZRAM_SETUP=true
  
  # Reload systemd and enable only the timer (path not needed with persistent zram)
  sudo systemctl daemon-reexec && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable $DEFAULT_ZRAM_DEV-setup.service && \
  sudo systemctl start $DEFAULT_ZRAM_DEV-setup.service && \
  echo "[✔] Persistent zram enabled and running"
else
  # Reload systemd and enable services (original method)
  sudo systemctl daemon-reexec && \
  sudo systemctl daemon-reload
fi

####################################

# setup_persistent_zram
# sudo systemctl daemon-reload

####################################

# 13. Finish installation
echo -e "\n✅ Installation complete!"
echo "Use 'journalctl -u zram-clean.service' or 'journalctl -t zram-clean' to view logs."
echo "Your logs are being saved to: $LOG_DIR"
