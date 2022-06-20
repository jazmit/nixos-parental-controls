# NixOS Parental Controls

## Who is it for?

If you want to give young children access to your NixOS desktop machines, this might be useful for you.

## What does it do?

It allows you to set different parental controls on a per-user basis.  For example, in the example below `child1` (this is their username) is restricted to a whitelist of educational sites, `child2` just has a blacklist of known adult sites and ad-serving domains blocked and all other users just block ads.

## How do I use it?

As a NixOS module:

````nix
{ config, pkgs, lib, ... }: {
  imports = [ ./nixos-parental-controls/nixos-parental-controls.nix ];
  services.parental-controls = {
    enable = true;
    upstream-dns = ["1.1.1.1" "8.8.8.8"];
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
          "/googleapis/"
          "/cloudflare/"
          "/lichess/"
          "/prismatic.io/"
          "/gstatic.com/"
          "/typingclub.com/"
          "/hs-scripts.com/"
        ];
      };
      child2 = {
        mode = "blacklist";
        block-adult = true;
      };
    };
  };
}
````

# How does it work?

We run the Blocky DNS proxy server locally and restart it with different configurations when different users log in or out.  Therefore it won't work well for a system where multiple users log on simultaneously.  The module sets `networking.nameservers` so you might want to be careful if you have complex network setup.

# TODO

- Screen-time limits using timekpr
