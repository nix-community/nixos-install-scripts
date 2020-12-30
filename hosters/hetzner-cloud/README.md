# Instructions

1. Create a server with any distribution (Ubuntu for example) from the Hetzner UI.
2. In your server options on the Hetzner UI click on `Mount image`. Find the NixOS image and mount it. Reboot the server into it.
3. You won't be able to ssh into your server. You will have to do the following steps by logging in with the Hetzner UI.
    - On the top right of the server details click on the icon `>_`.
    - Fork this repo and replace your SSH public key in the script. For exapmle, make a commit on a new branch.
    - Get the URL of the script you created (might look like `https://raw.github.com/YOUR_USER_NAME/nixos-install-scripts/YOUR_BRANCH_NAME/hosters/hetzner-cloud/nixos-install-hetzner-cloud.sh`).
    - Paste the following command into your console gui `curl -L YOUR_URL | sudo bash`.
4. After the system reboots, power it off and unmount the NixOS image in the Hetzner settings, then power it on again.
5. When it boots, you can now SSH into the newly created machine from your own computer.

# Troubleshooting

## SSH `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`

if you have already ssh-ed into your server before installing NixOS, you will have to remove the server from your .know-hosts file.
Open the file (located in your .ssh directory) and delete the entry corresponding to the server.

## Curl 404 error

if you copy and paste a url from the Hetzner console GUI, some characters can get replaced (If you are using an English/US keyboard layout for example). Just replace the offending characters (check the punctuation especially, @:_ and the likes).
