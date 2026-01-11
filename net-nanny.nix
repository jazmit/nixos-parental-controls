# DNS filtering implementation for parental controls
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.parental-controls;
  perUserBlocky = (import ./per-user-blocky/default.nix) { inherit pkgs; };

  # Encode the nix module options into command line options for the
  # python script that controls the DNS proxy
  startDNSProxy = let

    ads-hosts   = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
      sha256 = "13m33rfx5rg3n6h8p2wk7qpzpi159dkdnp0jchk46r3v6iv4vnh6";
    };
    adult-hosts = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts";
      sha256 = "17rjvhcf1ivmhr457xyka848s3zhgp0x5bngpjc08zh4z9gr56kv";
    };

    # Convert nixos module options into configuration files for the blocky DNS service
    mkBlockyConfig = name: thisCfg: (pkgs.writeText name ''
      upstream:
        default:
      ${builtins.concatStringsSep "\n" (map (d: "    - " + d) cfg.upstream-dns)}
      caching:
        maxTime: -1m
      ${if (thisCfg.mode == "whitelist") then ''
        blocking:
          whiteLists:
            myWhitelist:
              - |
        ${builtins.concatStringsSep "\n" (map (d: "        " + d) thisCfg.whitelist)}
          clientGroupsBlock:
            default:
              - myWhitelist
      '' else ''
        blocking:
          blackLists:
            ads:
              - ${ads-hosts}
            adult:
              - ${adult-hosts}
            custom:
              - |
        ${builtins.concatStringsSep "\n" (map (d: "        " + d) thisCfg.blacklist)}
          clientGroupsBlock:
            default:
              - custom
              ${ if (thisCfg.block-ads) then "- ads" else "" }
              ${ if (thisCfg.block-adult) then "- adult" else "" }
      ''
      }
    '');

    defaultBlockyConfig =
      mkBlockyConfig "blocky-default.conf" cfg.default;

    mkUserCLIOptions =
      userName: userOpts:
        let uid = if userOpts.uid == null
                  then config.users.users.${userName}.uid
                  else userOpts.uid;
            blockyConfig = mkBlockyConfig "blocky-${userName}.conf" userOpts;
        in  "--uid ${builtins.toString uid} ${blockyConfig}";

    allUserCLIOptions =
      concatStringsSep " " (lib.mapAttrsToList mkUserCLIOptions cfg.per-user);

    in "${perUserBlocky}/bin/per-user-blocky ${defaultBlockyConfig} ${allUserCLIOptions}";

in

{
  config = mkIf cfg.enable {
    networking.nameservers = [ "127.0.0.1" ];

    systemd.services.per-user-blocky = {
      description = "DNS Proxy which switches configuration based on logged in users";
      serviceConfig = {
        WorkingDirectory = "${perUserBlocky}";
        ExecStart = startDNSProxy;
        AmbientCapabilities   = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
