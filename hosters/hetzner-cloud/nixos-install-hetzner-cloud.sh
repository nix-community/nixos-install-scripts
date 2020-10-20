#! /usr/bin/env bash

# Script to install NixOS from the Hetzner Cloud NixOS bootable ISO image.
# (tested with Hetzner's `NixOS 20.03 (amd64/minimal)` ISO image).
# You must boot that image from the Hetzner Cloud GUI first.
# This script wipes the disk!
#
# To be able to SSH straight in (recommended), you must replace hardcoded pubkey
# further down in the section labelled "Replace this by your SSH pubkey" by you own,
# and host the modified script way under a URL of your choosing
# (e.g. gist.github.com with git.io as URL shortener service).
#
# Otherwise you'll be running with my pubkey, but you can change it afterwards
# by logging in via the Hetzner Cloud web terminal as `root` with empty password.
#
# Run like:
#
#     # Replace the URLs by your own that have your pubkey in
#     curl -L https://raw.githubusercontent.com/nix-community/nixos-install-scripts/master/hosters/hetzner-cloud/nixos-install-hetzner-cloud.sh | sudo bash
#     # or shorter:
#     curl -L https://git.io/JTspo | sudo bash
#
# To run it from the Hetzner Cloud web terminal without typing it down,
# you can either select it and then middle-click onto the web terminal, (that pastes
# to it), or se `xdotoool` (you have e.g. 3 seconds to focus the window):
#
#     sleep 3 && xdotool type --delay 50 'curl https://git.io/JTspo | sudo bash'
#
# (In the xdotool invocation you may have to replace chars so that
# the right chars appear on the US-English keyboard.)

set -e

# Hetzner Cloud OS images grow the root partition to the size of the local
# disk on first boot. In case the NixOS live ISO is booted immediately on
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
