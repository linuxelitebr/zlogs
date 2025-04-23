# Experiment

Redirect journal logs to zram. In practice this is useless, but it's an easy way to test whether ZLog is working.


## Creating directories

```bash
sudo mkdir -p -m2775 /var/log/debug-zram/journal
sudo chown ":systemd-journal" /var/log/debug-zram/journal
killall -USR1 systemd-journald
```


## Setting up journald

Change (or uncomment) the following lines:

```bash
egrep -v "^#" /etc/systemd/journald.conf

[Journal]
Storage=persistent
SystemMaxUse=475M
SystemKeepFree=25M
SystemMaxFileSize=2M
SystemMaxFiles=100
```


## Then edit (or create) a drop-in override to define the new path:

```bash
sudo mkdir -p /etc/systemd/journald.conf.d/

cat /etc/systemd/journald.conf.d/zram-override.conf

[Journal]
Storage=persistent
SystemKeepFree=25M
SystemMaxUse=475M
```


## Bindmount

```bash
sudo mount --bind /var/log/debug-zram/journal /var/log/journal

mount | grep zram
 /dev/zram1 on /var/log/debug-zram type ext4 (rw,relatime,seclabel)
 /dev/zram1 on /var/log/journal type ext4 (rw,relatime,seclabel)
```


## SELinux

```bash
/sbin/restorecon -v /var/log/journal
/sbin/restorecon -R -v /var/log/journal
setsebool -P logging_syslogd_list_non_security_dirs 1
service auditd rotate
```


## Restarting journald safely

```bash
sudo systemctl stop systemd-journald
sudo systemd-tmpfiles --create --prefix /var/log/debug-zram/journal
sudo systemctl start systemd-journald
dmesg
```