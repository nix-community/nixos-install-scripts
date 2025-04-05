#!/usr/bin/env bash

# Installs NixOS on a Hetzner server, wiping the server.
#
# This is for a specific server configuration; adjust where needed.
#
# Prerequisites:
#   * Update the script wherever FIXME is present
#
# Usage:
#     ssh root@YOUR_SERVERS_IP bash -s < hetzner-dedicated-wipe-and-install-nixos.sh
#
# When the script is done, make sure to boot the server from HD, not rescue mode again.

# Explanations:
#
# * Following largely https://nixos.org/nixos/manual/index.html#sec-installing-from-other-distro.
# * and https://nixos.wiki/wiki/NixOS_on_ZFS
# * **Important:** First you need to boot in legacy-BIOS mode. Then ask for
# hetzner support to enable UEFI for you.
# * We set a custom `configuration.nix` so that we can connect to the machine afterwards,
#   inspired by https://nixos.wiki/wiki/Install_NixOS_on_Hetzner_Online
# * This server has 2 SSDs.
#   We put everything on mirror (RAID1 equivalent).
# * A root user with empty password is created, so that you can just login
#   as root and press enter when using the Hetzner spider KVM.
#   Of course that empty-password login isn't exposed to the Internet.
#   Change the password afterwards to avoid anyone with physical access
#   being able to login without any authentication.
# * The script reboots at the end.
# * exports of env vars are added throughout the script in case you want to run it manually
export LC_ALL=C

# WARNING: on 2023/07/16 the rescue system of hetzner boots with kernel 6.3.7 which
# is by default not supported by the latest debian package. You need to update to debian
# unstable to proceed with the zfs installation.

cat > /etc/apt/preferences.d/90_zfs <<EOF
Package: libnvpair1linux libnvpair3linux libuutil1linux libuutil3linux libzfs2linux libzfs4linux libzpool2linux libzpool4linux spl-dkms zfs-dkms zfs-test zfsutils-linux zfsutils-linux-dev zfs-zed
Pin: release n=bullseye-backports
Pin-Priority: 990
EOF

apt update -y
apt install -y dpkg-dev linux-headers-$(uname -r) linux-image-amd64 sudo parted zfs-dkms zfsutils-linux

set -euox pipefail

# hetzner has some weird symlinks to make you install zfs with their script
rm /usr/local/sbin/zfs || true
rm /usr/local/sbin/zpool || true

# Inspect existing disks
# Should give you something like
# NAME        MAJ:MIN RM   SIZE RO TYPE  MOUNTPOINT
# nvme0n1     259:0    0 476.9G  0 disk
# ├─nvme0n1p1 259:2    0    32G  0 part
# │ └─md0       9:0    0    32G  0 raid1 [SWAP]
# ├─nvme0n1p2 259:3    0   512M  0 part
# │ └─md1       9:1    0   511M  0 raid1 /boot
# └─nvme0n1p3 259:4    0 444.4G  0 part
#   └─md2       9:2    0 444.3G  0 raid1 /
# nvme1n1     259:1    0 476.9G  0 disk
# ├─nvme1n1p1 259:5    0    32G  0 part
# │ └─md0       9:0    0    32G  0 raid1 [SWAP]
# ├─nvme1n1p2 259:6    0   512M  0 part
# │ └─md1       9:1    0   511M  0 raid1 /boot
# └─nvme1n1p3 259:7    0 444.4G  0 part
#   └─md2       9:2    0 444.3G  0 raid1 /
lsblk

# check the disks that you have available
# you have to use disks by ID with zfs
# see https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2020.04%20Root%20on%20ZFS.html#step-2-disk-formatting
ls /dev/disk/by-id
# should give you something like this
# md-name-rescue:0                             nvme-eui.0025388a01051b58-part1
# md-name-rescue:1                             nvme-eui.0025388a01051b58-part2
# md-name-rescue:2                             nvme-eui.0025388a01051b58-part3
# md-uuid-15391820:32e070f6:ecbfb99e:e983e018  nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00424
# md-uuid-48379d14:3c44fe11:e6528eec:ad784ade  nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00424-part1
# md-uuid-f2a894fc:9e90e3af:9af81d28:b120ae1f  nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00424-part2
# nvme-eui.0025388a01051b55                    nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00424-part3
# nvme-eui.0025388a01051b55-part1              nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00427
# nvme-eui.0025388a01051b55-part2              nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00427-part1
# nvme-eui.0025388a01051b55-part3              nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00427-part2
# nvme-eui.0025388a01051b58                    nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00427-part3
#
# we will use the two disks
# nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00424
# nvme-SAMSUNG_MZVLB512HBJQ-00000_S4GENA0NA00427

# FIXME The following variables should be replaced
export DISK1=/dev/disk/by-id/nvme-SAMSUNG_MZQLB3T8HALS-00007_S438NC0R804840
export DISK2=/dev/disk/by-id/nvme-SAMSUNG_MZQLB3T8HALS-00007_S438NC0R811800
# FIXME Replace this by your SSH pubkey!
export SSH_PUB_KEY="AAAAAAAAAAA..."
# choose whatever you want, it doesn't matter
export MY_HOSTNAME=htz
# this has to be a number in this format exactly. You can replace the numbers though
export MY_HOSTID=00000001

# Undo existing setups to allow running the script multiple times to iterate on it.
# We allow these operations to fail for the case the script runs the first time.
umount /mnt || true
vgchange -an || true

# Stop all mdadm arrays that the boot may have activated.
mdadm --stop --scan

# Prevent mdadm from auto-assembling arrays.
# Otherwise, as soon as we create the partition tables below, it will try to
# re-assemple a previous RAID if any remaining RAID signatures are present,
# before we even get the chance to wipe them.
# From:
#     https://unix.stackexchange.com/questions/166688/prevent-debian-from-auto-assembling-raid-at-boot/504035#504035
# We use `>` because the file may already contain some detected RAID arrays,
# which would take precedence over our `<ignore>`.
echo 'AUTO -all
ARRAY <ignore> UUID=00000000:00000000:00000000:00000000' > /etc/mdadm/mdadm.conf

# Create wrapper for parted >= 3.3 that does not exit 1 when it cannot inform
# the kernel of partitions changing (we use partprobe for that).
echo -e "#! /usr/bin/env bash\nset -e\n" 'parted $@ 2> parted-stderr.txt || grep "unable to inform the kernel of the change" parted-stderr.txt && echo "This is expected, continuing" || echo >&2 "Parted failed; stderr: $(< parted-stderr.txt)"' > parted-ignoring-partprobe-error.sh && chmod +x parted-ignoring-partprobe-error.sh

# Create partition tables (--script to not ask)
./parted-ignoring-partprobe-error.sh --script $DISK1 mklabel gpt
./parted-ignoring-partprobe-error.sh --script $DISK2 mklabel gpt

# Create partitions (--script to not ask)
#
# We create the 1MB BIOS boot partition at the front.
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
# TODO the bios partition should not be this big
# however if it's less the installation fails with
# cannot copy /nix/store/d4xbrrailkn179cdp90v4m57mqd73hvh-linux-5.4.100/bzImage to /boot/kernels/d4xbrrailkn179cdp90v4m57mqd73hvh-linux-5.4.100-bzImage.tmp: No space left on device
./parted-ignoring-partprobe-error.sh --script --align optimal $DISK1 -- mklabel gpt \
    mkpart 'BIOS-boot-partition' 1MB 2MB set 1 bios_grub on \
    mkpart 'EFI-system-partition' 2MB 512MB set 2 esp on \
    mkpart 'data-partition' 512MB '100%'

./parted-ignoring-partprobe-error.sh --script --align optimal $DISK2 -- mklabel gpt \
    mkpart 'BIOS-boot-partition' 1MB 2MB set 1 bios_grub on \
    mkpart 'EFI-system-partition' 2MB 512MB set 2 esp on \
    mkpart 'data-partition' 512MB '100%'

# Reload partitions
partprobe

# Wait for all devices to exist
udevadm settle --timeout=5 --exit-if-exists=$DISK1-part1
udevadm settle --timeout=5 --exit-if-exists=$DISK1-part2
udevadm settle --timeout=5 --exit-if-exists=$DISK1-part3
udevadm settle --timeout=5 --exit-if-exists=$DISK2-part1
udevadm settle --timeout=5 --exit-if-exists=$DISK2-part2
udevadm settle --timeout=5 --exit-if-exists=$DISK2-part3

# Wipe any previous RAID signatures
# sometimes they are not on a specific disk for some reason
mdadm --zero-superblock --force $DISK1-part1 || true
mdadm --zero-superblock --force $DISK1-part2 || true
mdadm --zero-superblock --force $DISK1-part3 || true
mdadm --zero-superblock --force $DISK2-part1 || true
mdadm --zero-superblock --force $DISK2-part2 || true
mdadm --zero-superblock --force $DISK2-part3 || true

# Creating file systems changes their UUIDs.
# Trigger udev so that the entries in /dev/disk/by-uuid get refreshed.
# `nixos-generate-config` depends on those being up-to-date.
# See https://github.com/NixOS/nixpkgs/issues/62444
udevadm trigger

# taken from https://nixos.wiki/wiki/NixOS_on_ZFS
# somehow there is a weird symlink in the default zfs
zpool create -O mountpoint=none \
    -O atime=off \
    -O compression=lz4 \
    -O xattr=sa \
    -O acltype=posixacl \
    -o ashift=12 \
    -f \
    root_pool mirror $DISK1-part3 $DISK2-part3

# Create the filesystems. This layout is designed so that /home is separate from the root
# filesystem, as you'll likely want to snapshot it differently for backup purposes. It also
# makes a "nixos" filesystem underneath the root, to support installing multiple OSes if
# that's something you choose to do in future.
zfs create -o mountpoint=legacy root_pool/root
zfs create -o mountpoint=legacy root_pool/root/nixos
zfs create -o mountpoint=legacy root_pool/home
# add 1G of reseved space in case the disk gets full
# zfs needs space to delete files
zfs create -o refreservation=1G -o mountpoint=none root_pool/reserved
# this creates a special volume for db data see https://wiki.archlinux.org/index.php/ZFS#Databases
zfs create -o mountpoint=legacy \
    -o recordsize=8K \
    -o primarycache=metadata \
    -o logbias=throughput \
    root_pool/postgres

# NixOS pre-installation mounts
#
# Mount the filesystems manually. The nixos installer will detect these mountpoints
# and save them to /mnt/nixos/hardware-configuration.nix during the install process.
mount -t zfs root_pool/root/nixos /mnt
mkdir /mnt/home
mount -t zfs root_pool/home /mnt/home
mkdir -p /mnt/var/lib/postgres
mount -t zfs root_pool/postgres /mnt/var/lib/postgres

# Create a raid mirror for the efi boot
# see https://docs.hetzner.com/robot/dedicated-server/operating-systems/efi-system-partition/
# TODO check this though the following article says it doesn't work properly
# https://outflux.net/blog/archives/2018/04/19/uefi-booting-and-raid1/ 
mdadm --create --run --verbose /dev/md127 \
    --level 1 \
    --raid-disks 2 \
    --metadata 1.0 \
    --homehost=$MY_HOSTNAME \
    --name=boot_efi \
    $DISK1-part2 $DISK2-part2

# Assembling the RAID can result in auto-activation of previously-existing LVM
# groups, preventing the RAID block device wiping below with
# `Device or resource busy`. So disable all VGs first.
vgchange -an

# Wipe filesystem signatures that might be on the RAID from some
# possibly existing older use of the disks (RAID creation does not do that).
# See https://serverfault.com/questions/911370/why-does-mdadm-zero-superblock-preserve-file-system-information
wipefs -a /dev/md127

# Disable RAID recovery. We don't want this to slow down machine provisioning
# in the rescue mode. It can run in normal operation after reboot.
echo 0 > /proc/sys/dev/raid/speed_limit_max

# Filesystems (-F to not ask on preexisting FS)
mkfs.vfat -F 32 /dev/md127

# Creating file systems changes their UUIDs.
# Trigger udev so that the entries in /dev/disk/by-uuid get refreshed.
# `nixos-generate-config` depends on those being up-to-date.
# See https://github.com/NixOS/nixpkgs/issues/62444
udevadm trigger

mkdir -p /mnt/boot/efi
mount /dev/md127 /mnt/boot/efi

# Installing nix

# Allow installing nix as root, see
#   https://github.com/NixOS/nix/issues/936#issuecomment-475795730
mkdir -p /etc/nix
echo "build-users-group =" > /etc/nix/nix.conf

# using determinate systems installer, for more information
# check https://github.com/DeterminateSystems/nix-installer
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

# FIXME Keep in sync with `system.stateVersion` set below!
nix-channel --add https://nixos.org/channels/nixos-24.11 nixpkgs
nix-channel --update

# TODO use something like nix shell nixpkgs#nixos-generate-config nixpkgs#nixos-install nixpkgs#nixos-enter nixpkgs#manual.manpages
# Getting NixOS installation tools
nix-env -iE "_: with import <nixpkgs/nixos> { configuration = {}; }; (with config.system.build; [ nixos-generate-config nixos-install ]) ++ (with pkgs; [ nixos-enter ])"

# TODO
# perl: warning: Please check that your locale settings:
#         LANGUAGE = (unset),
#         LC_ALL = "en_US.UTF-8",
#         LANG = "en_US.UTF-8"
#     are supported and installed on your system.
nixos-generate-config --root /mnt

# Find the name of the network interface that connects us to the Internet.
# Inspired by https://unix.stackexchange.com/questions/14961/how-to-find-out-which-interface-am-i-using-for-connecting-to-the-internet/302613#302613
export RESCUE_INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)')
# Find what its name will be under NixOS, which uses stable interface names.
# See https://major.io/2015/08/21/understanding-systemds-predictable-network-device-names/#comment-545626
# NICs for most Hetzner servers are not onboard, which is why we use
# `ID_NET_NAME_PATH`otherwise it would be `ID_NET_NAME_ONBOARD`.
export INTERFACE_DEVICE_PATH=$(udevadm info -e | grep -Po "(?<=^P: )(.*${RESCUE_INTERFACE})")
export UDEVADM_PROPERTIES_FOR_INTERFACE=$(udevadm info --query=property "--path=$INTERFACE_DEVICE_PATH")
export NIXOS_INTERFACE=$(echo "$UDEVADM_PROPERTIES_FOR_INTERFACE" | grep -o -E 'ID_NET_NAME_PATH=\w+' | cut -d= -f2)
echo "Determined NIXOS_INTERFACE as '$NIXOS_INTERFACE'"
export IP_V4=$(ip route get 8.8.8.8 | grep -Po '(?<=src )(\S+)')
echo "Determined IP_V4 as $IP_V4"
# Find what its name will be under NixOS, which uses stable interface names.
# See https://major.io/2015/08/21/understanding-systemds-predictable-network-device-names/#comment-545626
# NICs for most Hetzner servers are not onboard, which is why we use
# `ID_NET_NAME_PATH`otherwise it would be `ID_NET_NAME_ONBOARD`.
export INTERFACE_DEVICE_PATH=$(udevadm info -e | grep -Po "(?<=^P: )(.*${RESCUE_INTERFACE})")
export UDEVADM_PROPERTIES_FOR_INTERFACE=$(udevadm info --query=property "--path=$INTERFACE_DEVICE_PATH")
export NIXOS_INTERFACE=$(echo "$UDEVADM_PROPERTIES_FOR_INTERFACE" | grep -o -E 'ID_NET_NAME_PATH=\w+' | cut -d= -f2)
echo "Determined NIXOS_INTERFACE as '$NIXOS_INTERFACE'"

# Determine Internet IPv6 by checking route, and using ::1
# (because Hetzner rescue mode uses ::2 by default).
# The `ip -6 route get` output on Hetzner looks like:
#   # ip -6 route get 2001:4860:4860:0:0:0:0:8888
#   2001:4860:4860::8888 via fe80::1 dev eth0 src 2a01:4f8:151:62aa::2 metric 1024  pref medium
export IP_V6="$(ip route get 2001:4860:4860::8888 | head -1 | cut -d' ' -f7 | cut -d: -f1-4)::1"
echo "Determined IP_V6 as $IP_V6"

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

  # Use GRUB2 as the boot loader.
  # We don't use systemd-boot because Hetzner uses BIOS legacy boot.
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
    devices = ["$DISK1" "$DISK2"];
    copyKernels = true; 
  };
  boot.supportedFilesystems = [ "zfs" ];

  networking.hostName = "$MY_HOSTNAME";
  networking.hostId = "$MY_HOSTID";
  
  # enable flakes by default
  nix = {
    package = pkgs.nixFlakes;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  # Set your time zone.
  time.timeZone = "Etc/UTC";

  environment = {
    enableDebugInfo = true;
    # just a couple of packages to make our lives easier
    systemPackages = with pkgs; [ vim ];
  };

  # Network (Hetzner uses static IP assignments, and we don't use DHCP here)
  networking.useDHCP = false;
  networking.interfaces."$NIXOS_INTERFACE".ipv4.addresses = [
    {
      address = "$IP_V4";
      prefixLength = 24;
    }
  ];
  networking.interfaces."$NIXOS_INTERFACE".ipv6.addresses = [
    {
      address = "$IP_V6";
      prefixLength = 64;
    }
  ];
  networking.defaultGateway = "$DEFAULT_GATEWAY";
  networking.defaultGateway6 = { address = "fe80::1"; interface = "$NIXOS_INTERFACE"; };
  networking.nameservers = [
    # cloudflare
    "1.1.1.1"
    "2606:4700:4700::1111"
    "2606:4700:4700::1001"
    # google
    "8.8.8.8"
    "2001:4860:4860::8888"
    "2001:4860:4860::8844"
  ];

  # Initial empty root password for easy login:
  users.users.root.initialHashedPassword = "";
  services.openssh.permitRootLogin = "prohibit-password";

  users.users.root.openssh.authorizedKeys.keys = ["$SSH_PUB_KEY"];

  services.openssh.enable = true;

  # FIXME
  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "24.11"; # Did you read the comment?
}
EOF

# Install NixOS
PATH="$PATH" $(which nixos-install) \
  --no-root-passwd --root /mnt --max-jobs 40

umount /mnt

reboot

# if you need to debug something
# - connect to the rescue system
# - install zfs
# ```
# zpool import -f root_pool temp_pool
# mount -t zfs temp_pool/root/nixos /mnt
# journalctl --directory=/mnt/var/log/journal
