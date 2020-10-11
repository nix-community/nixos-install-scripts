#! /usr/bin/env bash

# Script to install NixOS from the Hetzner Cloud NixOS bootable ISO image.
# Wipes the disk!
# Tested with Hetzner's `NixOS 20.03 (amd64/minimal)` ISO image.
#
# Run like:
#
#     curl https://nh2.me/nixos-install-hetzner-cloud.sh | sudo bash
#
# To run it from the Hetzner Cloud web terminal without typing it down,
# use `xdotoool` (you have e.g. 3 seconds to focus the window):
#
#     sleep 3 && xdotool type --delay 50 'curl https://nh2.me/nixos-install-hetzner-cloud.sh | sudo bash'
#
# (In the xdotool invocation you may have to replace chars so that
# the right chars appear on the US-English keyboard.)
#
# If you want to be able to SSH straight in,
# do not forget to replace the SSH key below by yours
# (in the section labelled "Replace this by your SSH pubkey"),
# and host script modified this way under and URL of your choosing.
# Otherwise you'l be running with my pubkey, but you can change it
# afterwards by logging in via the Hetzner Cloud web terminal as `root`
# with empty password.

set -e

# Hetzner Cloud OS images grow the root partition to the size of the local
# disk on first book. In case the NixOS live ISO is booted immediately on
# first powerup, that does not happen. Thus we need to grow the partition
# by deleting and re-creating it.
sgdisk -d 1 /dev/sda
sgdisk -N 1 /dev/sda
partprobe /dev/sda

mkfs.ext4 -F /dev/sda1 # wipes all data!

mount /dev/sda1 /mnt

nixos-generate-config --root /mnt

# Delete trailing `}` from `configuration.nix` so that we can append more to it.
sed -i -E 's:^\}\s*$::g' /mnt/etc/nixos/configuration.nix

# Extend/override default `configuration.nix`:
echo '
  boot.loader.grub.devices = [ "/dev/sda" ];

  # Initial empty root password for easy login:
  users.users.root.initialHashedPassword = "";
  services.openssh.permitRootLogin = "prohibit-password";

  services.openssh.enable = true;

  # Replace this by your SSH pubkey
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAtwCIGPYJlD2eeUtxngmT+4yR7BMlK0F5kzj+84uHsxxsy+PXFrP/tScCpwmuoiEYNv/9WKnPJJfCA9XlIDr6cla1MLpaW6eg672TRYMmKzH6SLlkg+kyDmPxSIJw+KdKfnPYyva+Y/VocACYJo0voabUeLAVgtSKGz/AFzccjfOR0GmFO911zjAaR+jFb9M7t7dveNVKm9KbuBfu3giMgGg3/mKz1TKY8yk2ZOxpT5CllBb+B5BcEf+7IGNvNxr1Z0zz5cFXQ3LyBIZklnC/OaQCnD78BSiyPTkIXcmBFal2TaFwTDvki6PuCRpJy+dU1fDdgWLql97D0SVnjmmomw=="
  ];
}
' >> /mnt/etc/nixos/configuration.nix

nixos-install --no-root-passwd

reboot
