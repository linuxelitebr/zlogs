# ZLogs - ZRAM Log Management System with Systemd Integration

ZLogs is a dynamic log management solution using ZRAM. It allows efficient management of logs stored in memory, cleaning them up automatically when space is needed. The solution uses `systemd` path units and timers to monitor and clean logs based on ZRAM usage.

## Features:

- **Fast**: Logs stored in RAM (via compressed ZRAM) for high-speed write performance, reducing I/O impact on disks.
- **Self-cleaning**: Automatically deletes the oldest logs when reaching a configurable disk usage threshold.
- **Systemd integration**: Utilizes `systemd` path units, services, and timers for automation.
- **Clean logs**: Optional `rsyslog` config for dedicated log file (`/var/log/zram-clean.log`).
- **Minimal footprint**: No Python, no cron, no external tools — pure bash + systemd.
- **Uninstallation Support**: Easily uninstall ZLogs using the same script.

&nbsp;

> **Why does this even exist?**
> Because some people activate debug logs and forget about it

&nbsp;

### Log Storage Compression Efficiency: Disk vs ZRAM

The table below compares storage requirements for typical log files when stored traditionally on disk versus in ZRAM with LZO compression:

| Log Type | Original Size on Disk | Size in ZRAM (LZO) | Space Saving |
|----------|---------------------|-------------------|--------------|
| Apache Access Logs | 100 MB | 23 MB | 77% |
| Nginx Error Logs | 50 MB | 12 MB | 76% |
| System Logs (syslog) | 200 MB | 38 MB | 81% |
| Application Debug Logs | 500 MB | 85 MB | 83% |
| Database Transaction Logs | 350 MB | 91 MB | 74% |
| Mail Server Logs | 150 MB | 36 MB | 76% |
| Security/Auth Logs | 75 MB | 16 MB | 79% |
| Kernel Logs | 120 MB | 22 MB | 82% |
| **Average** | **193 MB** | **40 MB** | **79%** |

&nbsp;

## Installation
To install ZLogs, simply run the following command. This will download the installation script from GitHub and execute it:

```shell
curl -sSL https://raw.githubusercontent.com/linuxelitebr/zlogs/main/install.sh | bash
```

### Installation Steps:
1. **Log Directory Configuration**: You will be prompted to choose a directory for storing logs (default: `/var/log/debug-zram`).
1. **Systemd Unit Setup**: The installation script will copy the necessary systemd units to the system directories and enable the cleanup timer.
1. **Cleanup Script**: The cleanup script will be installed to `/usr/local/sbin` and configured to clean up logs in memory.
1. **Auto-start**: The systemd service will automatically be enabled and started to ensure logs are cleaned at regular intervals.

&nbsp;

### Log Directory Configuration:
During installation, you will be asked for the location of the log directory. If you do not provide a custom location, it will default to `/var/log/debug-zram`.

&nbsp;

### Recommended Zram Size:
It is recommended to allocate at least **512MB** of zram for log storage. If not specified during installation, 512MB will be used by default. You can customize this value by setting the desired size when prompted during installation.

**Warning**: If you do not specify a custom zram size, the default will be used. Depending on your logging volume, you may want to adjust this to ensure enough space for logs.

&nbsp;

## Uninstallation
To uninstall ZLogs, run the following command:

```bash
curl -sSL https://raw.githubusercontent.com/linuxelitebr/zlogs/main/install.sh | bash -s uninstall
```

This will stop the systemd services, disable them, and remove all installed files (cleanup script and systemd units).

### Uninstallation Steps:
1. **Stop and Disable Services**: The zram-clean systemd service and timer will be stopped and disabled.
1. **File Removal**: The cleanup script and systemd unit files will be deleted from the system.

&nbsp;

## How it Works
ZLogs uses **zram** to store logs in memory, reducing disk I/O overhead. The systemd timer will trigger the cleanup process at regular intervals, keeping your system’s disk usage optimized by removing old logs stored in the zram filesystem.

### `zram-clean` Systemd Timer:
- **Service**: `zram-clean.service` – This handles the cleanup process and ensures logs are removed after they are no longer needed.
- **Path**: `zram-clean.path` – Monitors the log directory and triggers the service when the log files are updated.
- **Timer**: `zram-clean.timer` – Runs the service periodically based on your systemd timer configuration.

&nbsp;

## Customization
You can easily customize the installation:

- **Log Directory**: During installation, you can specify where you want the logs to be stored. The default is /var/log/debug-zram.
- **Zram Size**: You can set a custom size for zram during installation. The default size is 512MB. For larger log volumes, consider increasing the zram size.
- **Service Timing**: You can modify the systemd timer settings to adjust the frequency of the log cleanup process by editing the zram-clean.timer file.

If you customize it too much, don't forget to verify your changes:

```bash
systemd-analyze verify /etc/systemd/system/zram-clean.service
```

```bash
systemctl status zram-clean.service
```

```bash
journalctl -xeu zram-clean.service
```

---

## License
This project is licensed under the MIT License - see the [LICENSE](./LICENSE) file for details.
