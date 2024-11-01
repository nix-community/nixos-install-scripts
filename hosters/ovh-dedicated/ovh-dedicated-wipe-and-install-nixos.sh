#!/usr/bin/env bash

# Installs NixOS on an OVH server, wiping the server.
#
# This is for a specific server configuration; adjust where needed.
# Originally written for an OVH STOR-1 server.
#
# Prerequisites:
#   * Create a LUKS key file at $LUKS_KEYFILE_PATH
#     e.g. by copying it up.
#     See https://wiki.archlinux.org/title/Dm-crypt/Device_encryption#Keyfiles
#   * Update the script to put in your SSH pubkey, adjust hostname, NixOS version etc.
#
# Usage:
#     ssh root@YOUR_SERVERS_IP bash -s < ovh-dedicated-wipe-and-install-nixos.sh
#
# When the script is done, make sure to boot the server from HD, not rescue mode again.

# Explanations:
#
# * Following largely https://nixos.org/nixos/manual/index.html#sec-installing-from-other-distro.
# * **Important:** We boot in UEFI mode, thus requiring an ESP.
#    Booting in LEGACY mode (non-UEFI boot, without ESP) would require that:
#   * `/boot` is on the same device as GRUB
#   * NVMe devices aren not used for booting (those require EFI boot)
#   We also did not manage to boot our OVH server in LEGACY mode on our SuperMicro mainboard, even when we installed `/` (including `/boot`) directly to a simple RAID1ed GPT partition. The screen just stayed black.
# * We set a custom `configuration.nix` so that we can connect to the machine afterwards.
# * This server has 1 SSD and 4 HDDs.
#   We'll ignore the SSD, putting the OS on the HDDs as well, so that everything is on RAID1.
#   We wipe the SSD though, so that if it had some boot partitions on it, they don't interfere.
#   Storage scheme: `partitions -> RAID -> LUKS -> LVM -> ext4`.
# * A root user with empty password is created, so that you can just login
#   as root and press enter when using the OVH KVM.
#   Of course that empty-password login isn't exposed to the Internet.
#   Change the password afterwards to avoid anyone with physical access
#   being able to login without any authentication.
# * The script reboots at the end.

# Edit those variables to your need
LUKS_KEYFILE_PATH="/root/benacofs-luks-key"
FS_NAME="benacofs"
HOSTNAME="benaco-cdn-na1"
HOMEHOST="benaco-cdn"

set -eu
set -o pipefail

set -x

# Inspect existing disks
lsblk

# Undo existing setups to allow running the script multiple times to iterate on it.
# We allow these operations to fail for the case the script runs the first time.
set +e
umount /mnt/boot/ESP*
umount /mnt
vgchange -an
cryptsetup luksClose data0-unencrypted
cryptsetup luksClose data1-unencrypted
set -e

# Stop all mdadm arrays that the boot may have activated.
mdadm --stop --scan

# Create wrapper for parted >= 3.3 that does not exit 1 when it cannot inform
# the kernel of partitions changing (we use partprobe for that).
echo -e "#! /usr/bin/env bash\nset -e\n" 'parted $@ 2> parted-stderr.txt || grep "unable to inform the kernel of the change" parted-stderr.txt && echo "This is expected, continuing" || echo >&2 "Parted failed; stderr: $(< parted-stderr.txt)"' > parted-ignoring-partprobe-error.sh && chmod +x parted-ignoring-partprobe-error.sh

# Create partition tables (--script to not ask)
./parted-ignoring-partprobe-error.sh --script /dev/sda mklabel gpt
./parted-ignoring-partprobe-error.sh --script /dev/sdb mklabel gpt
./parted-ignoring-partprobe-error.sh --script /dev/sdc mklabel gpt
./parted-ignoring-partprobe-error.sh --script /dev/sdd mklabel gpt
./parted-ignoring-partprobe-error.sh --script /dev/nvme0n1 mklabel gpt

# Create partitions (--script to not ask)
#
# Create EFI system partition (ESP) and main partition for each boot device.
# We make it 550 M as recommended by the author of gdisk (https://www.rodsbooks.com/linux-uefi/);
# using 550 ensures it's greater than 512 MiB, no matter if Mi or M were used.
# For the non-boot devices, we still make space for an ESP partition
# (in case the disks get repurposed for that at some point) but mark
# it as `off` and label it `*-unused` to avoid confusion.
#
# Note we use "MB" instead of "MiB" because otherwise `--align optimal` has no effect;
# as per documentation https://www.gnu.org/software/parted/manual/html_node/unit.html#unit:
# > Note that as of parted-2.4, when you specify start and/or end values using IEC
# > binary units like "MiB", "GiB", "TiB", etc., parted treats those values as exact
#
# Note: When using `mkpart` on GPT, as per
#   https://www.gnu.org/software/parted/manual/html_node/mkpart.html#mkpart
# the first argument to `mkpart` is not a `part-type`, but the GPT partition name:
#   ... part-type is one of 'primary', 'extended' or 'logical', and may be specified only with 'msdos' or 'dvh' partition tables.
#   A name must be specified for a 'gpt' partition table.
# GPT partition names are limited to 36 UTF-16 chars, see https://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_entries_(LBA_2-33).
./parted-ignoring-partprobe-error.sh --script --align optimal /dev/sda -- mklabel gpt mkpart 'ESP-partition0'        fat32 1MB 551MB set 1 esp on  mkpart 'OS-partition0' 551MB 500GB mkpart 'data-partition0' 500GB '100%'
./parted-ignoring-partprobe-error.sh --script --align optimal /dev/sdb -- mklabel gpt mkpart 'ESP-partition1'        fat32 1MB 551MB set 1 esp on  mkpart 'OS-partition1' 551MB 500GB mkpart 'data-partition1' 500GB '100%'
./parted-ignoring-partprobe-error.sh --script --align optimal /dev/sdc -- mklabel gpt mkpart 'ESP-partition2-unused' fat32 1MB 551MB set 1 esp off                                    mkpart 'data-partition2' 551MB '100%'
./parted-ignoring-partprobe-error.sh --script --align optimal /dev/sdd -- mklabel gpt mkpart 'ESP-partition3-unused' fat32 1MB 551MB set 1 esp off                                    mkpart 'data-partition3' 551MB '100%'

# Relaod partitions
partprobe

# Wait for all devices to exist
udevadm settle --timeout=5 --exit-if-exists=/dev/sda1
udevadm settle --timeout=5 --exit-if-exists=/dev/sda2
udevadm settle --timeout=5 --exit-if-exists=/dev/sda3
udevadm settle --timeout=5 --exit-if-exists=/dev/sdb1
udevadm settle --timeout=5 --exit-if-exists=/dev/sdb2
udevadm settle --timeout=5 --exit-if-exists=/dev/sdb3
udevadm settle --timeout=5 --exit-if-exists=/dev/sdc1
udevadm settle --timeout=5 --exit-if-exists=/dev/sdc2
udevadm settle --timeout=5 --exit-if-exists=/dev/sdd1
udevadm settle --timeout=5 --exit-if-exists=/dev/sdd2

# Array gets created automatically
# Stop it so mdadm can zero the superblock
for f in $(ls -p /dev | grep -v / | grep md); do
  mdadm --stop /dev/$f
done

# Wipe any previous RAID signatures
mdadm --zero-superblock /dev/sda2
mdadm --zero-superblock /dev/sda3
mdadm --zero-superblock /dev/sdb2
mdadm --zero-superblock /dev/sdb3
mdadm --zero-superblock /dev/sdc2
mdadm --zero-superblock /dev/sdd2

# Create RAIDs
# Note that during creating and boot-time assembly, mdadm cares about the
# host name, and the existence and contents of `mdadm.conf`!
# This also affects the names appearing in /dev/md/ being different
# before and after reboot in general (but we take extra care here
# to pass explicit names, and set HOMEHOST for the rebooting system further
# down, so that the names appear the same).
# Almost all details of this are explained in
#   https://bugzilla.redhat.com/show_bug.cgi?id=606481#c14
# and the followup comments by Doug Ledford.
mdadm --create --run --verbose /dev/md/root0           --level=1 --raid-devices=2 --homehost=benaco-cdn --name=root0           /dev/sda2 /dev/sdb2
mdadm --create --run --verbose /dev/md/data0-encrypted --level=1 --raid-devices=2 --homehost=benaco-cdn --name=data0-encrypted /dev/sda3 /dev/sdb3
mdadm --create --run --verbose /dev/md/data1-encrypted --level=1 --raid-devices=2 --homehost=benaco-cdn --name=data1-encrypted /dev/sdc2 /dev/sdd2

# Assembling the RAID can result in auto-activation of previously-existing LVM
# groups, preventing the RAID block device wiping below with
# `Device or resource busy`. So disable all VGs first.
vgchange -an

# Wipe filesystem signatures that might be on the RAID from some
# possibly existing older use of the disks (RAID creation does not do that).
# See https://serverfault.com/questions/911370/why-does-mdadm-zero-superblock-preserve-file-system-information
wipefs -a /dev/md/root0
wipefs -a /dev/md/data0-encrypted
wipefs -a /dev/md/data1-encrypted

# Disable RAID recovery. We don't want this to slow down machine provisioning
# in the rescue mode. It can run in normal operation after reboot.
echo 0 > /proc/sys/dev/raid/speed_limit_max

# LUKS encryption (--batch-mode to not ask)
cryptsetup --batch-mode luksFormat /dev/md/data0-encrypted $LUKS_KEYFILE_PATH
cryptsetup --batch-mode luksFormat /dev/md/data1-encrypted $LUKS_KEYFILE_PATH

# Decrypt
cryptsetup luksOpen /dev/md/data0-encrypted data0-unencrypted --key-file $LUKS_KEYFILE_PATH
cryptsetup luksOpen /dev/md/data1-encrypted data1-unencrypted --key-file $LUKS_KEYFILE_PATH

# LVM
# PVs
pvcreate /dev/mapper/data0-unencrypted
pvcreate /dev/mapper/data1-unencrypted
# VGs
vgcreate vg0 /dev/mapper/data0-unencrypted /dev/mapper/data1-unencrypted
# LVs
lvcreate --extents 95%FREE -n $FS_NAME vg0  # 5% slack space

# Filesystems (-F to not ask on preexisting FS)
mkfs.fat -F 32 -n esp0 /dev/disk/by-partlabel/ESP-partition0
mkfs.fat -F 32 -n esp1 /dev/disk/by-partlabel/ESP-partition1
mkfs.ext4 -F -L root /dev/md/root0
mkfs.ext4 -F -L $FS_NAME /dev/mapper/vg0-$FS_NAME

# Creating file systems changes their UUIDs.
# Trigger udev so that the entries in /dev/disk/by-uuid get refreshed.
# `nixos-generate-config` depends on those being up-to-date.
# See https://github.com/NixOS/nixpkgs/issues/62444
udevadm trigger

# Wait for FS labels to appear
udevadm settle --timeout=5 --exit-if-exists=/dev/disk/by-label/root
udevadm settle --timeout=5 --exit-if-exists=/dev/disk/by-label/$FS_NAME

# NixOS pre-installation mounts

# Mount target root partition
mount /dev/disk/by-label/root /mnt
# Mount efivars unless already mounted
# (OVH rescue doesn't have them by default and the NixOS installer needs this)
mount | grep efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars
# Mount our ESP partitions
mkdir -p /mnt/boot/ESP0
mkdir -p /mnt/boot/ESP1
mount /dev/disk/by-label/esp0 /mnt/boot/ESP0
mount /dev/disk/by-label/esp1 /mnt/boot/ESP1

# Installing nix

# Allow installing nix as root, see
#   https://github.com/NixOS/nix/issues/936#issuecomment-475795730
mkdir -p /etc/nix
echo "build-users-group =" > /etc/nix/nix.conf
echo "sandbox = false" >> /etc/nix/nix.conf

# https://github.com/NixOS/nix/issues/7790#issuecomment-1451990482
mount --bind / /

curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
set +u +x # sourcing this may refer to unset variables that we have no control over
. $HOME/.nix-profile/etc/profile.d/nix.sh
set -u -x

nix-channel --add https://nixos.org/channels/nixos-24.05 nixpkgs
nix-channel --update

# Getting NixOS installation tools
nix-env -iE "_: with import <nixpkgs/nixos> { configuration = {}; }; with config.system.build; [ nixos-generate-config nixos-install nixos-enter manual.manpages ]"

nixos-generate-config --root /mnt

# On the OVH rescue mode, the default Internet interface is called `eth0`.
# Find what its name will be under NixOS, which uses stable interface names.
# See https://major.io/2015/08/21/understanding-systemds-predictable-network-device-names/#comment-545626
INTERFACE=$(udevadm info -e | grep -A 11 ^P.*eth0 | grep -o -E 'ID_NET_NAME_ONBOARD=\w+' | cut -d= -f2)
echo "Determined INTERFACE as $INTERFACE"

IP_V4=$(ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
echo "Determined IP_V4 as $IP_V4"

# From https://stackoverflow.com/questions/1204629/how-do-i-get-the-default-gateway-in-linux-given-the-destination/15973156#15973156
read _ _ DEFAULT_GATEWAY _ < <(ip route list match 0/0); echo "$DEFAULT_GATEWAY"
echo "Determined DEFAULT_GATEWAY as $DEFAULT_GATEWAY"


# Generate `configuration.nix`. Note that we splice in shell variables.
cat > /mnt/etc/nixos/configuration.nix <<EOF
{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Use GRUB2 as the EFI boot loader.
  # We don't use systemd-boot because then
  # * we can't use boot.loader.grub.mirroredBoots to mirror the ESP over multiple disks
  # * we can't put /boot on the same partition as /
  #   (boot.loader.efi.efiSysMountPoint = "/boot/EFI" apparently does not have
  #   the desired outcome then, just puts all of /boot under /boot/EFI instead)
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    mirroredBoots = [
      { devices = [ "nodev" ]; path = "/boot/ESP0"; }
      { devices = [ "nodev" ]; path = "/boot/ESP1"; }
    ];
  };

  boot.loader.efi.canTouchEfiVariables = true;

  # Don't put NixOS kernels, initrds etc. on the ESP, because
  # the ESP is not RAID1ed.
  # Mount the ESP at /boot/efi instead of the default /boot so that
  # boot is just on the / partition.
  boot.loader.efi.efiSysMountPoint = "/boot/EFI";

  networking.hostName = "$HOSTNAME;

  # The mdadm RAID1s were created with 'mdadm --create ... --homehost=benaco-cdn',
  # but the hostname for each CDN machine is different, and mdadm's HOMEHOST
  # setting defaults to '<system>' (using the system hostname).
  # This results mdadm considering such disks as "foreign" as opposed to
  # "local", and showing them as e.g. '/dev/md/benaco-cdn:data0'
  # instead of '/dev/md/data0'.
  # This is mdadm's protection against accidentally putting a RAID disk
  # into the wrong machine and corrupting data by accidental sync, see
  # https://bugzilla.redhat.com/show_bug.cgi?id=606481#c14 and onward.
  # We set the HOMEHOST manually go get the short '/dev/md' names,
  # and so that things look and are configured the same on all such CDN
  # machines irrespective of host names.
  # We do not worry about plugging disks into the wrong machine because
  # we will never exchange disks between CDN machines.
  environment.etc."mdadm.conf".text = ''
    HOMEHOST $HOMEHOST
  '';
  # The RAIDs are assembled in stage1, so we need to make the config
  # available there.
  boot.initrd.mdadmConf = config.environment.etc."mdadm.conf".text;

  # Network (OVH uses static IP assignments, no DHCP)
  networking.useDHCP = false;
  networking.interfaces."$INTERFACE".ipv4.addresses = [
    {
      address = "$IP_V4";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "$DEFAULT_GATEWAY";
  networking.nameservers = [ "8.8.8.8" ];

  # Initial empty root password for easy login:
  users.users.root.initialHashedPassword = "";
  services.openssh.permitRootLogin = "prohibit-password";

  users.users.root.openssh.authorizedKeys.keys = [
    # Replace this by your pubkey!
    "ssh-rsa AAAAAAAAAAA..."
  ];

  services.openssh.enable = true;

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "24.05"; # Did you read the comment?

}
EOF

# Install NixOS
PATH="$PATH" NIX_PATH="$NIX_PATH" `which nixos-install` --no-root-passwd --root /mnt --max-jobs 40

reboot
