# NixOS Parental Controls

## Development

Changes made by Mycroft in its local checkout are committed as
`Mycroft <jazmit@users.noreply.github.com>`.

## Who is it for?

If you want to give young children access to your NixOS desktop machines, this might be useful for you.

## What does it do?

It allows you to set different parental controls on a per-user basis, including:
- **DNS filtering**: Whitelist or blacklist websites per user
- **Screen time limits**: Set allowed login times per day of the week, with automatic logout when time expires

For example, in the example below `child1` (this is their username) is restricted to a whitelist of educational sites with weekday evening access only, `child2` has a blacklist of known adult sites and youtube with different weekend hours, and all users have ads blocked.

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

        # Screen time: only after school on weekdays
        screen-time = {
          enable = true;
          weekdays = { start = "15:00"; end = "19:00"; };
          weekend = { start = "09:00"; end = "21:00"; };
          # Show warnings at 10, 5, 4, 3, 2, and 1 minutes before logout (default)
          warnings = [ 10 5 4 3 2 1 ];
        };
      };
      child2 = {
        mode = "blacklist";
        block-adult = true;
        blacklist = [
            "/youtube/"
        ];

        # Screen time: different hours for each day
        screen-time = {
          enable = true;
          monday = { start = "16:00"; end = "20:00"; };
          tuesday = { start = "16:00"; end = "20:00"; };
          wednesday = { start = "16:00"; end = "20:00"; };
          thursday = { start = "16:00"; end = "20:00"; };
          friday = { start = "16:00"; end = "21:00"; };
          saturday = { start = "10:00"; end = "22:00"; };
          sunday = { start = "10:00"; end = "20:00"; };
        };
      };
    };
  };
}
````

# How does it work?

## DNS Filtering

We run the Blocky DNS proxy server locally and restart it with different configuration files as different users log in or out.  Therefore it won't work well for a system where multiple users log on simultaneously.  The module sets `networking.nameservers` so you might want to be careful if you have complex network setup. Also, the default upstream DNS servers use the CloudFlare and Google DNS, please use the `services.parental-controls.upstream-dns` option to set a different upstream.

The blacklists for the `block-ads` and `block-adult` options come from Steven Black's [hosts project](https://github.com/StevenBlack/hosts).

## Screen Time Limits

Screen time limits use systemd timers and services to:
1. Lock and unlock user accounts at scheduled times using `passwd -l/-u`
2. Force logout all user sessions (GUI, TTY, SSH) when screen time ends using `loginctl terminate-user`
3. Initialize the correct lock state on boot based on current day and time

### Configuration

- **Time format**: Use 24-hour HH:MM format (e.g., "15:00" for 3 PM)
- **Helper options**: Use `weekdays` to set Monday-Friday, `weekend` for Saturday-Sunday
- **Override**: Explicit day settings (e.g., `monday`, `tuesday`) override helper options
- **Unscheduled days**: Days without a schedule keep the user locked all day
- **Warnings**: Customize warning times by setting the `warnings` list (in minutes before logout)

### Behavior

- **Countdown warnings**: Desktop notifications are shown before screen time ends (default: 10, 5, 4, 3, 2, and 1 minutes)
- **Logout**: When screen time ends, all active sessions are terminated
- **All session types**: Restrictions apply to GUI, TTY, and SSH sessions (warnings only show in graphical sessions)
- **Boot state**: System sets correct lock/unlock state on boot based on current time
- **Persistent timers**: If system is off during a scheduled time, the timer fires on next boot

### Limitations

- **No overnight schedules**: Cannot set schedules that span midnight (e.g., 22:00-02:00)
- **Unsaved work**: Any unsaved work will be lost when sessions are terminated at logout time
- **Authentication messages**: Locked users see "Authentication failure" when trying to login
- **Time accuracy**: Assumes system time is accurate (enable NTP)
- **Physical access**: Children with physical access can boot from USB or change system time
- **Notification reliability**: Warnings may not appear if the desktop environment doesn't support notifications or if notification daemon is not running

Each scheduled user has one calendar timer for all configured warning times.
The warning service only attempts to notify a user with an available session
bus; a missing bus or failed desktop notification is logged and does not mark
the service failed. Account locking and unlocking use separate timers and
services, so warning delivery cannot prevent the scheduled lock.
