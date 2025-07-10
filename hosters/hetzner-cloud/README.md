# hetzner-cloud

## Instructions

1. Create a server with any distribution (Ubuntu for example) from the Hetzner UI.
2. In your server options on the Hetzner UI click on `Mount image`. Find the NixOS image and mount it. Reboot the server into it.
3. You won't be able to ssh into your server. You will have to do the following steps by logging in with the Hetzner UI.
    - On the top right of the server details click on the icon `>_`.
    - Fork this repo and replace your SSH public key in the script. For exapmle, make a commit on a new branch.
    - Get the URL of the script you created (might look like `https://raw.github.com/YOUR_USER_NAME/nixos-install-scripts/YOUR_BRANCH_NAME/hosters/hetzner-cloud/nixos-install-hetzner-cloud.sh`).
    - Paste the following command into your console gui `curl -L YOUR_URL | sudo bash`.
   This will install NixOS and turn the server off.
4. In your server options on the Hetzner UI click on `Unmount`, and turn the server back on using the big power-switch button in the top right.
5. On your own computer you can now ssh into the newly created machine.


## Custom IP setup

`nixos-install-hetzner-cloud.sh` configures no network settings, which defaults to DHCP (which works out of the box on Hetzner Cloud).

If you want to use Hetzner Cloud Floating IP addresses, you cannot use DHCP because it does not assign the floating address.

Below you can find a config that sets the normal and 1 floating address explicitly.

It also configures the route.

The example includes IPv4 + IPv6; if you don't want to use one of those, remove the corresponding parts (also for the routes and nameservers).

```nix
  # The global useDHCP flag is deprecated, therefore explicitly set to false here.
  # Per-interface useDHCP will be mandatory in the future, so this generated config
  # replicates the default behaviour.
  networking.useDHCP = false;

  # See https://docs.hetzner.com/cloud/servers/static-configuration/
  #
  # IP address order:
  # The order of floating vs non-floating IPs given here is important,
  # because outgoing traffic is sent from the first IP in the list by default
  # (unless an application sends it from a specific explicitly configured IP).
  # This is explained on: http://linux-ip.net/html/routing-saddr-selection.html
  # This means that e.g. UDP-based VPNs like Nebula will succeed to ping
  # in only 1 direction:
  # If a peer of this machine
  #   * is e.g. behind a NAT that allows UDP packets in only from sources that
  #     UDP was sent to before (this is common),
  #   * and the peer knows this machine only under its floating
  #     (thus stable, non-changing) IP,
  #   * and sends a ping to that floating IP,
  # and this machine sends outgoing response packet from the non-floating IP,
  # then the NAT will reject it as coming from an unknown, untrusted IP.
  # Thus, when you use a floating IP, you usually want to use them for everything,
  # and it should be the first entry in the addresses list.
  # An alternative would be to specity the `src` attribute to select which IP
  # is used for initiating outbound traffic, as described on:
  # https://serverfault.com/questions/451601/ip-route-show-src-field/511685#511685
  # However, NixOS does not currently have a convenient option for `src`.
  networking.interfaces.enp1s0.ipv4.addresses = [
    # Floating IP
    {
      address = floatingIPv4;
      prefixLength = 32;
    }
    # non-floating IP
    {
      address = nonFloatingIPv4;
      prefixLength = 32;
    }
  ];
  networking.interfaces.enp1s0.ipv6.addresses = [
    # Floating IP
    {
      address = floatingIPv6;
      prefixLength = 64;
    }
    # non-floating IP
    {
      address = nonFloatingIPv6;
      prefixLength = 64;
    }
  ];

  # Hetzner Cloud route.
  networking.defaultGateway = { address = "172.31.1.1"; interface = "enp1s0"; };
  networking.defaultGateway6 = { address = "fe80::1"; interface = "enp1s0"; };

  # Hetzner nameservers.
  # See: https://docs.hetzner.com/dns-console/dns/general/recursive-name-servers/
  # You could also pick others such as Google's 8.8.8.8 or CloudFlare's 1.1.1.1.
  #
  # Note glibc `MAXNS = 3` (`man resolv.conf`) only considers
  # the first 3 entries and ignores the others.
  # This limitation can be worked around using a local DNS resolver server
  # without this limit, such as `systemd-resolved`.
  # That one also solves that the glibc resolver for each request
  # tries all name servers in order (including waiting for timeout)
  # which makes fallback on nameserver failure extremely slow.
  networking.nameservers = [
    # IPv4
    "185.12.64.1"
    "185.12.64.2"
    # IPv6
    "2a01:4ff:ff00::add:1"
    "2a01:4ff:ff00::add:2"
  ];
  services.resolved.enable = true;
```

Note:

If you (for some reason) set static addresses and enable DHCP _in addition_, and then forget to set a `defaultGateway`, your server will lose connectivity after 12 hours during the DHCP lease renewal half-time, with a `journalctl` log such as:

```
Jul 09 16:55:57 nixos dhcpcd[1080]: enp1s0: pid 0 deleted host route to 172.31.1.1
Jul 09 16:55:57 nixos dhcpcd[1080]: enp1s0: pid 0 deleted default route via 172.31.1.1
```


## Troubleshooting

### SSH `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`

If you have already ssh-ed into your server before installing NixOS, you will have to remove the server from your .know-hosts file.
Open the file (located in your .ssh directory) and delete the entry corresponding to the server.

### Curl 404 error

If you copy and paste a url from the Hetzner console GUI, some characters can get replaced (If you are using an English/US keyboard layout for example). Just replace the offending characters (check the punctuation especially, @:_ and the likes).
