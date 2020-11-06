# Instructions

1. Create a server with any distribution (Ubuntu for exemple) from the Hetzner UI.
2. In your server options on the Hetzner UI click on `Mount image`. Find the NixOS image and mount it.
3. You won't be able to ssh into your server. You will have to do the following steps by logging in with the Hetzner UI.
- On the top right of the server details click on the icon `>_`.
- fork this repo and replace your SSH public key in the script. Make a commit on a new branch for example.
- get the url of the script you created (should look like https://raw.github.com/YOUR_USER_NAME/nixos-install-scripts/YOUR_BRANCH_NAME/hosters/hetzner-cloud/nixos-install-hetzner-cloud.sh).
- paste the following command into your console gui `curl -L YOUR_URL | sudo bash`.
4. on your own computer you can now ssh into the newly created machine.

# Troubleshooting

## SSH `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`

if you have already ssh-ed into your server before installing NixOS, you will have to remove the server from your .know-hosts file.
Open the file (located in your .ssh directory) and delete the entry corresponding to the server.

## Curl 404 error

if you copy and paste a url from the Hetzner console GUI, some characters can get replaced (If you are using an English/US keyboard layout for example). Just replace the offending characters (check the punctuation especially, @:_ and the likes).
