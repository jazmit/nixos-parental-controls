# Screen time limiting implementation for parental controls
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.parental-controls;

  # Helper script to send notifications to a user's graphical sessions
  mkNotifyScript = userName: pkgs.writeShellScript "notify-${userName}" ''
    uid=$(${pkgs.coreutils}/bin/id -u ${userName})
    bus=/run/user/$uid/bus
    if [ ! -S "$bus" ]; then
      echo "Skipping screen time warning for ${userName}: no user DBus session"
      exit 0
    fi

    if ! ${pkgs.sudo}/bin/sudo -u ${userName} \
      XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=$bus \
      ${pkgs.libnotify}/bin/notify-send -u critical -t 10000 "Screen Time" "$1"; then
      echo "Screen time warning for ${userName} could not be delivered"
    fi
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

  # One calendar timer per user covers every configured warning time.
  mkWarningEvents = userOpts:
    let
      schedule = mergeSchedule userOpts.screen-time;
      warnings = userOpts.screen-time.warnings;
      dayToSystemd = {
        monday = "Mon"; tuesday = "Tue"; wednesday = "Wed";
        thursday = "Thu"; friday = "Fri"; saturday = "Sat"; sunday = "Sun";
      };
      dayNumber = {
        monday = "1"; tuesday = "2"; wednesday = "3";
        thursday = "4"; friday = "5"; saturday = "6"; sunday = "7";
      };
      mkDayEvents = day: timeRange:
        if timeRange == null then [] else
        let
          endMinutes = timeToMinutes timeRange.end;
          validWarnings = builtins.filter
            (minutes: endMinutes - minutes >= timeToMinutes timeRange.start)
            warnings;
        in
          map (minutes: let clock = minutesToTime (endMinutes - minutes); in {
            inherit clock minutes;
            day = dayNumber.${day};
            calendar = "${dayToSystemd.${day}} *-*-* ${clock}:00";
          }) validWarnings;
    in
      lib.flatten (lib.mapAttrsToList mkDayEvents schedule);

  mkWarningTimer = userName: events: {
    "parental-controls-warn-${userName}" = {
      description = "Screen time warnings for ${userName}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = map (event: event.calendar) events;
        AccuracySec = "1s";
        Persistent = false;
        Unit = "parental-controls-warn-${userName}.service";
      };
    };
  };

  mkWarningService = userName: events: {
    "parental-controls-warn-${userName}" = {
      description = "Warn ${userName} before screen time ends";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "warn-${userName}" ''
          case "$(${pkgs.coreutils}/bin/date '+%u %H:%M')" in
            ${lib.concatMapStringsSep "\n" (event: ''
              "${event.day} ${event.clock}")
                message="Screen time ends in ${toString event.minutes} minute${if event.minutes == 1 then "" else "s"}!"
                ;;
            '') events}
            *)
              echo "Skipping stale screen time warning for ${userName}"
              exit 0
              ;;
          esac
          exec ${mkNotifyScript userName} "$message"
        '';
      };
    };
  };

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
          (let events = mkWarningEvents userOpts;
           in if events == [] then {} else mkWarningService userName events) // {
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
          (mkScreenTimeTimers userName userOpts) //
          (let events = mkWarningEvents userOpts;
           in if events == [] then {} else mkWarningTimer userName events)
        else {}
      ) cfg.per-user
    );
  };
}
