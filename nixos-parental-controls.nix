{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.parental-controls;
  perUserBlocky = (import ./per-user-blocky/default.nix) { inherit pkgs; };

  # Encode the nix module options into command line options for the
  # python script that controls the DNS proxy
  startDNSProxy = let

    ads-hosts   = builtins.fetchurl "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
    adult-hosts = builtins.fetchurl "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts";

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
                  else userOpts.uid; # Does this always work?
            blockyConfig = mkBlockyConfig "blocky-${userName}.conf" userOpts;
        in  "--uid ${builtins.toString uid} ${blockyConfig}";

    allUserCLIOptions =
      concatStringsSep " " (lib.mapAttrsToList mkUserCLIOptions cfg.per-user);

    in "${perUserBlocky}/bin/per-user-blocky ${defaultBlockyConfig} ${allUserCLIOptions}";


  parentalConfigOptions = {
    options = {
      uid = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          User id of the user for this parental control config
          If omitted, will try to lookup the user id from the nixos config
        '';
      };
      mode = mkOption {
        type = types.enum ["whitelist" "blacklist"];
        default = "blacklist";
        description = ''
          whitelist: block all sites except those in the whitelist
          blacklist: block sites in the blacklist but not in the whitelist
        '';
      };
      whitelist = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Whitelist of sites to be allowed. Surround with '/' to do a regex match
        '';
      };
      blacklist = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Blacklist of sites to be blocked. Surround with '/' to do a regex match
        '';
      };
      block-ads = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to block commonly known ad-serving domains
          Currently TODO
        '';
      };
      block-adult = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to block commonly known domains serving adult content
          Currently TODO
        '';
      };
    };
  };

in

{
  options = {
    services.parental-controls = {
      enable = mkEnableOption "Per-user parental controls";
      upstream-dns = mkOption {
        type = types.listOf types.str;
        default = ["1.1.1.1" "8.8.8.8"];
        description = ''
          Upstream DNS servers used by the DNS proxy.
        '';
        example = [ "192.168.1.1" "1.1.1.1" "8.8.8.8" ];
      };
      default = mkOption {
        type = types.submodule parentalConfigOptions;
        default = {};
        description = ''
          Default configuration which applies to all users
        '';
      };
      per-user = mkOption {
        type = types.attrsOf (types.submodule parentalConfigOptions);
        default = {};
        description = ''
          Allows configuration of parental controls on a per-user basis
        '';
      };
    };
  };

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
