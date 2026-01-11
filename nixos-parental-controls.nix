{ config, pkgs, lib, black-hosts, ... }:

with lib;

let
  cfg = config.services.parental-controls;
  perUserBlocky = (import ./per-user-blocky/default.nix) { inherit pkgs; };

  # Encode the nix module options into command line options for the
  # python script that controls the DNS proxy
  startDNSProxy = let

    ads-hosts   = "${black-hosts}/hosts";
    adult-hosts = "${black-hosts}/alternates/fakenews-gambling-porn/hosts";

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

  # Type definition for a time range (start and end time)
  timeRangeType = types.submodule {
    options = {
      start = mkOption {
        type = types.strMatching "[0-2][0-9]:[0-5][0-9]";
        description = ''
          Start time in HH:MM format (24-hour)
        '';
        example = "07:00";
      };
      end = mkOption {
        type = types.strMatching "[0-2][0-9]:[0-5][0-9]";
        description = ''
          End time in HH:MM format (24-hour)
        '';
        example = "20:00";
      };
    };
  };

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
      screen-time = mkOption {
        type = types.submodule {
          options = {
            enable = mkEnableOption "screen time limits for this user";

            warnings = mkOption {
              type = types.listOf types.int;
              default = [ 10 5 4 3 2 1 ];
              description = ''
                Minutes before screen time ends to show warnings.
                Warnings are displayed as desktop notifications.
              '';
              example = [ 15 10 5 1 ];
            };

            weekdays = mkOption {
              type = types.nullOr timeRangeType;
              default = null;
              description = ''
                Set schedule for Monday through Friday.
                Explicit day settings override this.
              '';
              example = { start = "15:00"; end = "19:00"; };
            };

            weekend = mkOption {
              type = types.nullOr timeRangeType;
              default = null;
              description = ''
                Set schedule for Saturday and Sunday.
                Explicit day settings override this.
              '';
              example = { start = "09:00"; end = "21:00"; };
            };

            monday = mkOption {
              type = types.nullOr timeRangeType;
              default = null;
              description = "Allowed screen time on Monday";
            };

            tuesday = mkOption {
              type = types.nullOr timeRangeType;
              default = null;
              description = "Allowed screen time on Tuesday";
            };

            wednesday = mkOption {
              type = types.nullOr timeRangeType;
              default = null;
              description = "Allowed screen time on Wednesday";
            };

            thursday = mkOption {
              type = types.nullOr timeRangeType;
              default = null;
              description = "Allowed screen time on Thursday";
            };

            friday = mkOption {
              type = types.nullOr timeRangeType;
              default = null;
              description = "Allowed screen time on Friday";
            };

            saturday = mkOption {
              type = types.nullOr timeRangeType;
              default = null;
              description = "Allowed screen time on Saturday";
            };

            sunday = mkOption {
              type = types.nullOr timeRangeType;
              default = null;
              description = "Allowed screen time on Sunday";
            };
          };
        };
        default = { enable = false; };
        description = ''
          Screen time schedule for this user. Users will be locked out
          (unable to login) outside of their allowed times. Active sessions
          will be terminated when screen time ends.

          Days without a schedule will keep the user locked all day.
        '';
      };
    };
  };

in

{
  imports = [
    ./net-nanny.nix
    ./screen-time.nix
  ];

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


}
