# Screen time limiting implementation for parental controls
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.parental-controls;

  # Helper script to send notifications to a user's graphical sessions
  mkNotifyScript = userName: message: pkgs.writeShellScript "notify-${userName}" ''
    uid=$(${pkgs.coreutils}/bin/id -u ${userName})
    ${pkgs.sudo}/bin/sudo -u ${userName} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
      ${pkgs.libnotify}/bin/notify-send -u critical -t 10000 "Screen Time" "${message}"
  '';

  # Helper function to merge weekdays/weekend shortcuts with explicit day settings
  mergeSchedule = userSchedule:
    let
      # Start with empty schedule
      base = {
        monday = null; tuesday = null; wednesday = null;
        thursday = null; friday = null; saturday = null; sunday = null;
      };

      # Apply weekdays if set (Mon-Fri)
      withWeekdays = if userSchedule.weekdays != null then
        base // {
          monday = userSchedule.weekdays;
          tuesday = userSchedule.weekdays;
          wednesday = userSchedule.weekdays;
          thursday = userSchedule.weekdays;
          friday = userSchedule.weekdays;
        }
      else base;

      # Apply weekend if set (Sat-Sun)
      withWeekend = if userSchedule.weekend != null then
        withWeekdays // {
          saturday = userSchedule.weekend;
          sunday = userSchedule.weekend;
        }
      else withWeekdays;

      # Apply explicit day settings (these override weekdays/weekend)
      explicitDays = builtins.removeAttrs userSchedule ["enable" "weekdays" "weekend" "warnings"];
      final = withWeekend // explicitDays;
    in
      final;


  # Generate initialization script to set correct lock state on boot
  mkInitScript = userName: schedule:
    let
      # Map day names to numbers (1=Monday, 7=Sunday)
      dayNumbers = {
        monday = "1"; tuesday = "2"; wednesday = "3";
        thursday = "4"; friday = "5"; saturday = "6"; sunday = "7";
      };

      # Generate a case branch for each day
      mkDayCase = day: timeRange:
        if timeRange == null then ""
        else ''
          ${dayNumbers.${day}})
            START_TIME="${builtins.replaceStrings [":"] [""] timeRange.start}"
            END_TIME="${builtins.replaceStrings [":"] [""] timeRange.end}"
            if [ "$CURRENT_TIME" -ge "$START_TIME" ] && [ "$CURRENT_TIME" -lt "$END_TIME" ]; then
              echo "Unlocking ${userName} (within allowed time)"
              ${pkgs.shadow}/bin/passwd -u ${userName} 2>/dev/null || true
            else
              echo "Locking ${userName} (outside allowed time)"
              ${pkgs.systemd}/bin/loginctl terminate-user ${userName} 2>/dev/null || true
              ${pkgs.shadow}/bin/passwd -l ${userName} 2>/dev/null || true
            fi
            ;;
        '';

      allDayCases = lib.concatStrings (lib.mapAttrsToList mkDayCase schedule);

    in ''
      # Initialize ${userName}
      CURRENT_DAY=$(date +%u)
      CURRENT_TIME=$(date +%H%M)

      case $CURRENT_DAY in
        ${allDayCases}
        *)
          # No schedule for this day, lock the user
          echo "Locking ${userName} (no schedule for this day)"
          ${pkgs.systemd}/bin/loginctl terminate-user ${userName} 2>/dev/null || true
          ${pkgs.shadow}/bin/passwd -l ${userName} 2>/dev/null || true
          ;;
      esac
    '';


  # Generate systemd timer units for a user's screen time schedule
  mkScreenTimeTimers = userName: userOpts:
    let
      schedule = mergeSchedule userOpts.screen-time;

      # Convert day name to systemd day abbreviation
      dayToSystemd = {
        monday = "Mon"; tuesday = "Tue"; wednesday = "Wed";
        thursday = "Thu"; friday = "Fri"; saturday = "Sat"; sunday = "Sun";
      };

      # Generate unlock timer for a specific day
      mkUnlockTimer = day: timeRange: {
        name = "parental-controls-unlock-${userName}-${day}";
        value = {
          description = "Unlock ${userName} on ${day}";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "${dayToSystemd.${day}} *-*-* ${timeRange.start}:00";
            Persistent = true;
            Unit = "parental-controls-unlock-${userName}.service";
          };
        };
      };

      # Generate lock timer for a specific day
      mkLockTimer = day: timeRange: {
        name = "parental-controls-lock-${userName}-${day}";
        value = {
          description = "Lock ${userName} on ${day}";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "${dayToSystemd.${day}} *-*-* ${timeRange.end}:00";
            Persistent = true;
            Unit = "parental-controls-lock-${userName}.service";
          };
        };
      };

      # Filter out days with no schedule and generate timers
      daysWithSchedule = lib.filterAttrs (day: range: range != null) schedule;
      unlockTimers = lib.mapAttrsToList mkUnlockTimer daysWithSchedule;
      lockTimers = lib.mapAttrsToList mkLockTimer daysWithSchedule;

    in
      lib.listToAttrs (unlockTimers ++ lockTimers);


  # Helper to calculate time in minutes from HH:MM format
  timeToMinutes = timeStr:
    let
      parts = lib.splitString ":" timeStr;
      hours = lib.toIntBase10 (builtins.elemAt parts 0);
      minutes = lib.toIntBase10 (builtins.elemAt parts 1);
    in
      hours * 60 + minutes;

  # Helper to convert minutes back to HH:MM format
  minutesToTime = totalMinutes:
    let
      hours = totalMinutes / 60;
      minutes = lib.mod totalMinutes 60;
      padZero = n: if n < 10 then "0${toString n}" else toString n;
    in
      "${padZero hours}:${padZero minutes}";

  # Generate warning timers and services for a user
  mkWarningTimers = userName: userOpts:
    let
      schedule = mergeSchedule userOpts.screen-time;
      warnings = userOpts.screen-time.warnings;

      # Convert day name to systemd day abbreviation
      dayToSystemd = {
        monday = "Mon"; tuesday = "Tue"; wednesday = "Wed";
        thursday = "Thu"; friday = "Fri"; saturday = "Sat"; sunday = "Sun";
      };

      # Generate warning timers for a specific day
      mkDayWarnings = day: timeRange:
        let
          endMinutes = timeToMinutes timeRange.end;

          # Generate a warning timer for a specific warning interval
          mkWarning = warningMinutes:
            let
              warningTimeMinutes = endMinutes - warningMinutes;
            in
              # Only create warning if it's after the start time
              if warningTimeMinutes >= (timeToMinutes timeRange.start) then {
                name = "parental-controls-warn-${userName}-${day}-${toString warningMinutes}min";
                value = {
                  description = "Warn ${userName} on ${day} (${toString warningMinutes} min before logout)";
                  wantedBy = [ "timers.target" ];
                  timerConfig = {
                    OnCalendar = "${dayToSystemd.${day}} *-*-* ${minutesToTime warningTimeMinutes}:00";
                    Persistent = false;  # Don't fire if system was off
                    Unit = "parental-controls-warn-${userName}-${toString warningMinutes}min.service";
                  };
                };
              } else null;

          warningTimers = builtins.filter (x: x != null) (map mkWarning warnings);
        in
          warningTimers;

      # Filter out days with no schedule and generate warning timers
      daysWithSchedule = lib.filterAttrs (day: range: range != null) schedule;
      allWarnings = builtins.filter (x: x != null) (lib.flatten (lib.mapAttrsToList mkDayWarnings daysWithSchedule));

    in
      if allWarnings == [] then {} else lib.listToAttrs allWarnings;


  # Generate warning services for a user
  mkWarningServices = userName: userOpts:
    let
      warnings = userOpts.screen-time.warnings;

      # Generate a warning service for a specific warning interval
      mkWarningService = warningMinutes:
        let
          message = if warningMinutes == 1 then
            "Screen time ends in 1 minute!"
          else
            "Screen time ends in ${toString warningMinutes} minutes!";
        in {
          name = "parental-controls-warn-${userName}-${toString warningMinutes}min";
          value = {
            description = "Warn ${userName} (${toString warningMinutes} min before logout)";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = mkNotifyScript userName message;
            };
          };
        };

    in
      if warnings == [] then {} else lib.listToAttrs (map mkWarningService warnings);

in

{
  config = mkIf cfg.enable {
    # Generate all systemd services for screen time
    systemd.services = lib.mkMerge ([
      # Boot-time initialization service to set correct lock state
      {
        parental-controls-init = {
          description = "Initialize parental controls screen time state at boot";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-logind.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "parental-controls-init" ''
              echo "Initializing parental controls screen time state..."

              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (userName: userOpts:
                  if userOpts.screen-time.enable then
                    mkInitScript userName (mergeSchedule userOpts.screen-time)
                  else ""
                ) cfg.per-user
              )}

              echo "Parental controls initialization complete"
            '';
          };
        };
      }
    ] ++ (
      # Screen time lock/unlock services for each user
      lib.mapAttrsToList (userName: userOpts:
        if userOpts.screen-time.enable then
          # Merge lock/unlock services with warning services
          (mkWarningServices userName userOpts) // {
          # Unlock service
          "parental-controls-unlock-${userName}" = {
            description = "Unlock user ${userName} for screen time";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = pkgs.writeShellScript "unlock-user-${userName}" ''
                # Unlock the user account
                ${pkgs.shadow}/bin/passwd -u ${userName}

                # Log the event
                ${pkgs.systemd}/bin/systemd-cat -t parental-controls echo "Unlocked user ${userName}"
              '';
            };
          };

          # Lock service
          "parental-controls-lock-${userName}" = {
            description = "Lock user ${userName} - screen time ended";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = pkgs.writeShellScript "lock-user-${userName}" ''
                # Terminate all user sessions (GUI, TTY, SSH, etc.)
                ${pkgs.systemd}/bin/loginctl terminate-user ${userName} 2>/dev/null || true

                # Lock the user account to prevent new logins
                ${pkgs.shadow}/bin/passwd -l ${userName}

                # Log the event
                ${pkgs.systemd}/bin/systemd-cat -t parental-controls echo "Locked user ${userName}"
              '';
            };
          };
        } else {}
      ) cfg.per-user
    ));

    # Generate systemd timers for screen time
    systemd.timers = lib.mkMerge (
      lib.mapAttrsToList (userName: userOpts:
        if userOpts.screen-time.enable then
          # Merge lock/unlock timers with warning timers
          (mkScreenTimeTimers userName userOpts) // (mkWarningTimers userName userOpts)
        else {}
      ) cfg.per-user
    );
  };
}
