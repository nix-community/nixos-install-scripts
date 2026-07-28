#!/usr/bin/env bash
# Run this on the NixOS server to verify installation parameters
set -euo pipefail

echo "=== NixOS Installation Diagnostics ==="
echo ""

echo "--- OS Version ---"
cat /etc/os-release | grep -E "^(NAME|VERSION|VERSION_ID)=|^(ID)="
echo ""

echo "--- Hostname ---"
hostname
hostname -f
echo ""

echo "--- Kernel ---"
uname -r
echo ""

echo "--- Disk IDs ---"
ls -1 /dev/disk/by-id/nvme-* 2>/dev/null | grep -v part | sort
echo ""

echo "--- ZFS Pool Status ---"
zpool status
echo ""

echo "--- ZFS Pool Key Properties ---"
zpool get size,capacity,health,ashift,compatibility root_pool
echo ""

echo "--- ZFS Filesystems ---"
zfs list
echo ""

echo "--- Disk Layout ---"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
echo ""

echo "--- Partition Types ---"
blkid /dev/nvme0n1p* /dev/nvme1n1p* 2>/dev/null || echo "(blkid failed)"
echo ""

echo "--- Mount Points ---"
mount | grep -E "root_pool|/boot|/home|/var" || echo "(no matches)"
echo ""

echo "--- Network ---"
echo "Interfaces:"
ip -brief addr show
echo ""
echo "Routes:"
ip route
echo ""
echo "Default gateway:"
ip route | grep default || echo "(no default route)"
echo ""

echo "--- SSH Config ---"
echo "SSH daemon status:"
systemctl is-active sshd
echo ""
echo "Root authorized keys:"
if [ -f /etc/ssh/authorized_keys.d/root ]; then
    echo "  File: /etc/ssh/authorized_keys.d/root ($(wc -l < /etc/ssh/authorized_keys.d/root) key(s))"
    cut -d' ' -f1-2 /etc/ssh/authorized_keys.d/root
elif [ -f /etc/ssh/root_authorized_keys ]; then
    echo "  File: /etc/ssh/root_authorized_keys ($(wc -l < /etc/ssh/root_authorized_keys) key(s))"
    cut -d' ' -f1-2 /etc/ssh/root_authorized_keys
elif [ -f /root/.ssh/authorized_keys ]; then
    echo "  File: /root/.ssh/authorized_keys ($(wc -l < /root/.ssh/authorized_keys) key(s))"
    cut -d' ' -f1-2 /root/.ssh/authorized_keys
else
    echo "  (no authorized keys file found)"
fi
echo ""

echo "--- Boot Loader ---"
echo "Config:"
grep -E "boot\.loader\." /etc/nixos/configuration.nix 2>/dev/null || echo "  (config not accessible)"
echo ""
echo "GRUB installation:"
if [ -d /boot/grub ]; then
    echo "  /boot/grub exists"
    if [ -f /boot/grub/i386-pc/core.img ]; then
        echo "  GRUB BIOS mode (i386-pc) installed"
    elif [ -d /boot/grub/x86_64-efi ]; then
        echo "  GRUB UEFI mode installed"
    else
        echo "  GRUB directory present, mode unclear"
    fi
else
    echo "  (no /boot/grub found)"
fi
echo ""

echo "--- System Services ---"
echo "Critical services:"
for svc in systemd-journald sshd dbus zfs-mount zfs-share; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "not found")
    echo "  $svc: $status"
done
echo ""

echo "--- Nix Store ---"
echo "Store size: $(du -sh /nix/store | cut -f1)"
echo ""

echo "=== Diagnostics complete ==="
