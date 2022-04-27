#!/usr/bin/env bash

# Installs NixOS on a Leaseweb server, wiping the server.
#
# This is for a specific server configuration; adjust where needed.
# Originally written for a Leaseweb HP DL120 G7 server.
#
# Prerequisites:
#   * Update the script to put in your SSH pubkey, adjust hostname, NixOS version etc.
#
# Usage:
#     ssh root@YOUR_SERVERS_IP bash -s < leaseweb-dedicated-wipe-and-install-nixos.sh
#
# When the script is done, make sure to boot the server from HD, not rescue mode again.

# Explanations:
#
# * Following largely https://nixos.org/nixos/manual/index.html#sec-installing-from-other-distro.
# * Adapted from https://gist.github.com/nh2/78d1c65e33806e7728622dbe748c2b6a
# * Following largely https://nixos.org/nixos/manual/index.html#sec-installing-from-other-distro.
# * **Important:** We boot in legacy-BIOS mode, not UEFI, because that's what the HP DL120 G7 supports,
#   see https://lists.freebsd.org/pipermail/freebsd-proliant/2014-June/000666.html.
#   * NVMe devices aren't supported for booting (those require EFI boot)
# * We set a custom `configuration.nix` so that we can connect to the machine afterwards.
# * This server has 2 HDDs.
#   We put everything on RAID1.
#   Storage scheme: `partitions -> RAID -> LVM -> ext4`.
# * A root user with empty password is created, so that you can just login
#   as root and press enter when using a KVM.
#   Of course that empty-password login isn't exposed to the Internet.
#   Change the password afterwards to avoid anyone with physical access
#   being able to login without any authentication.
# * The script reboots at the end.

set -eu
set -o pipefail

set -x

# Inspect existing disks
lsblk

# Undo existing setups to allow running the script multiple times to iterate on it.
# We allow these operations to fail for the case the script runs the first time.
set +e
umount /mnt
vgchange -an
set -e

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
./parted-ignoring-partprobe-error.sh /dev/sda mklabel gpt
./parted-ignoring-partprobe-error.sh /dev/sdb mklabel gpt

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
./parted-ignoring-partprobe-error.sh --align optimal /dev/sda -- mklabel gpt mkpart 'BIOS-boot-partition' 1MB 2MB set 1 bios_grub on mkpart 'data-partition' 2MB '100%'
./parted-ignoring-partprobe-error.sh --align optimal /dev/sdb -- mklabel gpt mkpart 'BIOS-boot-partition' 1MB 2MB set 1 bios_grub on mkpart 'data-partition' 2MB '100%'

# Relaod partitions
partprobe

# Wait for all devices to exist
udevadm settle --timeout=5 --exit-if-exists=/dev/sda1
udevadm settle --timeout=5 --exit-if-exists=/dev/sda2
udevadm settle --timeout=5 --exit-if-exists=/dev/sdb1
udevadm settle --timeout=5 --exit-if-exists=/dev/sdb2

# Wipe any previous RAID signatures
mdadm --zero-superblock --force /dev/sda2
mdadm --zero-superblock --force /dev/sdb2

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
mdadm --create --run --verbose /dev/md0 --level=1 --raid-devices=2 --homehost=leaseweb --name=root0 /dev/sda2 /dev/sdb2

# Assembling the RAID can result in auto-activation of previously-existing LVM
# groups, preventing the RAID block device wiping below with
# `Device or resource busy`. So disable all VGs first.
vgchange -an

# Wipe filesystem signatures that might be on the RAID from some
# possibly existing older use of the disks (RAID creation does not do that).
# See https://serverfault.com/questions/911370/why-does-mdadm-zero-superblock-preserve-file-system-information
wipefs -a /dev/md0

# Disable RAID recovery. We don't want this to slow down machine provisioning
# in the rescue mode. It can run in normal operation after reboot.
echo 0 > /proc/sys/dev/raid/speed_limit_max

# LVM
# PVs
pvcreate /dev/md0
# VGs
vgcreate vg0 /dev/md0
# LVs (--yes to automatically wipe detected file system signatures)
lvcreate --yes --extents 95%FREE -n root0 vg0  # 5% slack space

# Filesystems (-F to not ask on preexisting FS)
mkfs.ext4 -F -L root /dev/mapper/vg0-root0

# Creating file systems changes their UUIDs.
# Trigger udev so that the entries in /dev/disk/by-uuid get refreshed.
# `nixos-generate-config` depends on those being up-to-date.
# See https://github.com/NixOS/nixpkgs/issues/62444
udevadm trigger

# Wait for FS labels to appear
udevadm settle --timeout=5 --exit-if-exists=/dev/disk/by-label/root

# NixOS pre-installation mounts

# Mount target root partition
mount /dev/disk/by-label/root /mnt

# Installing nix

# Allow installing nix as root, see
#   https://github.com/NixOS/nix/issues/936#issuecomment-475795730
mkdir -p /etc/nix
echo "build-users-group =" > /etc/nix/nix.conf

curl -L https://nixos.org/nix/install | sh
set +u +x # sourcing this may refer to unset variables that we have no control over
. $HOME/.nix-profile/etc/profile.d/nix.sh
set -u -x

# Keep in sync with `system.stateVersion` set below!
# nix-channel --add https://nixos.org/channels/nixos-20.03 nixpkgs
nix-channel --add https://nixos.org/channels/nixos-20.03 nixpkgs
nix-channel --update

# Getting NixOS installation tools
nix-env -iE "_: with import <nixpkgs/nixos> { configuration = {}; }; with config.system.build; [ nixos-generate-config nixos-install nixos-enter manual.manpages ]"

nixos-generate-config --root /mnt

# Find the name of the network interface that connects us to the Internet.
# Inspired by https://unix.stackexchange.com/questions/14961/how-to-find-out-which-interface-am-i-using-for-connecting-to-the-internet/302613#302613
RESCUE_INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)')

# Find what its name will be under NixOS, which uses stable interface names.
# See https://major.io/2015/08/21/understanding-systemds-predictable-network-device-names/#comment-545626
#
# IMPORTANT:
# There is a known complication in that Linux somewhere between 4.19 and 5.4.27
# switched from classifying only 1 of the 2 network interfaces of the server as
# "onboard" to classifying both as "onboard", thus "enp2s0" shows up as "eno0"
# instead in newer kernels.
# See:
#     https://gist.github.com/nh2/71854c40a1a1a7c15bc8a8105e854f88#file-analysis-md
# So once the Leaseweb GRML rescue mode upgrades to a newer kernel, the value of
# `NIXOS_INTERFACE` should be successfully found from `RESCUE_INTERFACE` using
# the `ID_NET_NAME_ONBOARD` grep below; but until then (when the grep is empty)
# we have to detect this situation, turning `enp2s0` into `eno0` ourselves,
# because we want to boot a NixOS that uses the new kernel (>= 5.4.27) of which
# we know that it will detect the card as "onboard" and thus call it "eno".
INTERFACE_DEVICE_PATH=$(udevadm info -e | grep -Po "(?<=^P: )(.*${RESCUE_INTERFACE})")
UDEVADM_PROPERTIES_FOR_INTERFACE=$(udevadm info --query=property "--path=$INTERFACE_DEVICE_PATH")
set +o pipefail # allow the grep to fail, see comment above
NIXOS_INTERFACE=$(echo "$UDEVADM_PROPERTIES_FOR_INTERFACE" | grep -o -E 'ID_NET_NAME_ONBOARD=\w+' | cut -d= -f2)
set -o pipefail
# The following `if` logic can be deleted once versions < 20.03 are no longer relevant.
if [ -z "$NIXOS_INTERFACE" ]; then
  echo "Could not determine NIXOS_INTERFACE from udevadm, RESCUE_INTERFACE is '$RESCUE_INTERFACE'"
  # Set this to 1 iff you are installing a newer kernel as described in the comment above:
  INSTALLING_NEWER_KERNEL=1
  if [ "$INSTALLING_NEWER_KERNEL" == "1" ]; then
    echo "INSTALLING_NEWER_KERNEL=1 is active, setting NIXOS_INTERFACE=eno0"
    NIXOS_INTERFACE="eno0"
  else
    echo "INSTALLING_NEWER_KERNEL=1 is NOT active, setting NIXOS_INTERFACE=$RESCUE_INTERFACE"
    NIXOS_INTERFACE="$RESCUE_INTERFACE"
  fi
else
  echo "Determined NIXOS_INTERFACE as '$NIXOS_INTERFACE'"
fi

IP_V4=$(ip route get 8.8.8.8 | grep -Po '(?<=src )(\S+)')
echo "Determined IP_V4 as $IP_V4"

# From https://stackoverflow.com/questions/1204629/how-do-i-get-the-default-gateway-in-linux-given-the-destination/15973156#15973156
read _ _ DEFAULT_GATEWAY _ < <(ip route list match 0/0); echo "$DEFAULT_GATEWAY"
echo "Determined DEFAULT_GATEWAY as $DEFAULT_GATEWAY"

# The Leaseweb GRML Rescue mode as of writing has no IPv6 connectivity,
# so we cannot get the IPv6 address here.


# Generate `configuration.nix`. Note that we splice in shell variables.
cat > /mnt/etc/nixos/configuration.nix <<EOF
{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Use GRUB2 as the boot loader.
  # We don't use systemd-boot because this Leaseweb server model uses BIOS legacy boot.
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
    devices = [ "/dev/sda" "/dev/sdb" ];
  };
  boot.loader.grub.extraGrubInstallArgs = [
    # The HP DL120 G7 server's BIOS has a bug that it apparently cannot
    # correctly address disk contents past 2 TiB. This makes booting fail
    # when booting from a single big "/" disk. Booting from a small "/boot"
    # is one workaround, but another is to use GRUB2's "nativedisk" disk
    # driver module instead of the ones the BIOS provides.
    # Because we cannot load those modules from disk before the disk is
    # accessible, we need to bake them into the GRUB2 "core.img" kernel
    # using the following commands, also providing the device specific
    # disk drivers (we give both "ahci" for SATA and "pata" for IDE, and
    # both "part_gpt" and "part_msdos", to support more configurations).
    # Requires:
    #     https://github.com/NixOS/nixpkgs/pull/85895
    "--modules=nativedisk ahci pata part_gpt part_msdos diskfilter mdraid1x lvm ext2"
  ];
  # Switch GRUB2 to console output.
  # This disables the graphical (pixel-based) menu with the custom boot splash
  # ("terminal_output gfxterm") and renders the simpler console-based menu instead.
  # This allows it to appear on remote administration consoles like "TEXTCONS".
  # See also:
  #     https://superuser.com/questions/1541093/hp-ilo-how-to-fix-monitor-is-in-graphics-mode-or-an-unsupported-text-mode/1541094#1541094
  # At least in NixOS 20.03, an alternative would be to set
  # "boot.loader.grub.font = null;", because that not being null by default is
  # what enables "gfxterm" in the first place (which I think is bad and unclear).
  # See https://github.com/NixOS/nixpkgs/issues/85828 for that.
  boot.loader.grub.extraConfig = ''
    terminal_output console
    terminal_input console
  '' +
  # Enable serial input/ouput in addition, and use it.
  # This enables administering the machine via serial, e.g. HP's iLO3 "VSP" command.
  # (We do not combine this with the above but do it afterwards, so that in case
  # any serial-related activation fails, we at least still have console output.)
  # Note that using e.g. "TEXTCONS" first and then switching to "VSP" (serial)
  # in the same GRUB2 session may not work (likely, GRUB2 detects at start whether
  # a serial is attached).
  ''
    serial
    terminal_output --append serial
    terminal_input --append serial
  '';

  boot.kernelParams = [
    # * "vga=normal" because e.g. HP's iLO3 "TEXTCONS" does
    #   apparently not support extended VGA modes.
    #   GRUB2 will print something about "vga=normal" being deprecated, but that
    #   is just its own opinion, Linux did not deprecate the boot option.
    # * "nomodeset" to prevent the kernel to switch away from normal VGA display
    # Without them, one gets after a short time:
    #     Monitor is in graphics mode or an unsupported text mode.
    "vga=normal" "nomodeset"
  ];

  networking.hostName = "leaseweb";

  # The mdadm RAID1s were created with 'mdadm --create ... --homehost=leaseweb',
  # but the hostname for each machine may be different, and mdadm's HOMEHOST
  # setting defaults to '<system>' (using the system hostname).
  # This results mdadm considering such disks as "foreign" as opposed to
  # "local", and showing them as e.g. '/dev/md/leaseweb:root0'
  # instead of '/dev/md/root0'.
  # This is mdadm's protection against accidentally putting a RAID disk
  # into the wrong machine and corrupting data by accidental sync, see
  # https://bugzilla.redhat.com/show_bug.cgi?id=606481#c14 and onward.
  # We set the HOMEHOST manually go get the short '/dev/md' names,
  # and so that things look and are configured the same on all such
  # machines irrespective of host names.
  # We do not worry about plugging disks into the wrong machine because
  # we will never exchange disks between machines.
  environment.etc."mdadm.conf".text = ''
    HOMEHOST leaseweb
  '';
  # The RAIDs are assembled in stage1, so we need to make the config
  # available there.
  boot.initrd.mdadmConf = config.environment.etc."mdadm.conf".text;

  # Network
  # Leaseweb uses static IP assignments only, see:
  #     https://kb.leaseweb.com/network/ipv4-address-assignment-and-usage-guidelines#IPv4addressassignmentandusageguidelines-DHCP
  networking.useDHCP = false;
  networking.interfaces."$NIXOS_INTERFACE".ipv4.addresses = [
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
  system.stateVersion = "20.03"; # Did you read the comment?

}
EOF

# TODO Remove once https://github.com/NixOS/nixpkgs/pull/85895 is merged and
#      backported to 20.03, or this script installs a newer version that has it.
rm -f extra-grub-install-flags-20.03.tar.gz
wget 'https://github.com/nh2/nixpkgs/archive/extra-grub-install-flags-20.03.tar.gz'
rm -rf nixpkgs-extra-grub-install-flags-20.03
tar xf extra-grub-install-flags-20.03.tar.gz
NIX_PATH=nixpkgs=$PWD/nixpkgs-extra-grub-install-flags-20.03


# Install NixOS
PATH="$PATH" NIX_PATH="$NIX_PATH" `which nixos-install` --no-root-passwd --root /mnt --max-jobs 40

umount /mnt

reboot
