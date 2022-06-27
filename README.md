# NixOS Parental Controls

## Who is it for?

If you want to give young children access to your NixOS desktop machines, this might be useful for you.

## What does it do?

It allows you to set different parental controls on a per-user basis.  For example, in the example below `child1` (this is their username) is restricted to a whitelist of educational sites, `child2` just has a blacklist of known adult sites and youtube and all users have ads blocked.

## How do I use it?

As a NixOS module:

````nix
{ config, pkgs, lib, ... }: {
  imports = [ ./nixos-parental-controls/nixos-parental-controls.nix ];
  services.parental-controls = {
    enable = true;
    default = {
      mode = "blacklist";
      block-ads = true;
    };
    per-user = {
      child1 = {
        mode = "whitelist";
        whitelist = [
          "/numbots/"
          "/ttrockstars/"
          "/lichess/"
          "/typingclub.com/"
          "/cloudflare/"
          "/googleapis/"
          "/gstatic.com/"
          "/prismatic.io/"
          "/hs-scripts.com/"
        ];
      };
      child2 = {
        mode = "blacklist";
        block-adult = true;
        blacklist = [
            "/youtube/"
        ];
      };
    };
  };
}
````

# How does it work?

We run the Blocky DNS proxy server locally and restart it with different configuration files as different users log in or out.  Therefore it won't work well for a system where multiple users log on simultaneously.  The module sets `networking.nameservers` so you might want to be careful if you have complex network setup. Also, the default upstream DNS servers use the CloudFlare and Google DNS, please use the `services.parental-controls.upstream-dns` option to set a different upstream.

The blacklists for the `block-ads` and `block-adult` options come from Steven Black's [hosts project](https://github.com/StevenBlack/hosts).


# TODO

- Screen-time limits using timekpr
