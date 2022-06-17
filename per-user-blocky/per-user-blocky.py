#!/usr/bin/env python3
# This script monitors user login/logout events and starts the
# `blocky` DNS proxy server with a corresponding configuration
# matched to the user's id
import dbus
import dbus.mainloop.glib
import sys
from subprocess import Popen
from gi.repository import GLib

# Read command line arguments
# TODO check arguments properly

userConfigs = {}

print("Passed arguments: ",sys.argv)

try:
    executableName = sys.argv.pop(0)
    defaultConfig  = sys.argv.pop(0)
    while len(sys.argv) > 0:
        confType = sys.argv.pop(0)
        userId   = int(sys.argv.pop(0))
        userConf = sys.argv.pop(0)
        assert confType == '--uid' # For now only --uid supported
        userConfigs[userId] = userConf
except:
    print("Syntax: per-user-blocky [DEFAULT_CONFIG_FILE] [--uid USERID CONFIG_FILE]...")
    sys.exit()

print("Starting per-user-blocky service, default config is " + defaultConfig)
print("Per-user configurations: ", userConfigs)

blockyProcess = None
currentConfig = None # TODO get currently logged in users at startup

# Stop the blocky process and restart with a new configuration
def switchBlockyConf(confFile):
    global blockyProcess
    global currentConfig
    if blockyProcess != None:
        print("*** Stopping old blocky process ***")
        blockyProcess.terminate()
        blockyProcess.wait()
        print("*** Blocky exited ***")
        # TODO purge DNS caches
        # systemctl restart nscd
    print("*** Starting new blocky process using "+confFile)
    currentConfig = confFile
    blockyProcess = Popen(["blocky", "--config", confFile])

# This gets called when a new user logs in
def userNew (userId, userPath):
    print("User ",userId," logged in")
    nextConfig = userConfigs[userId] if userId in userConfigs else defaultConfig
    print(nextConfig)
    if nextConfig != currentConfig:
        print("Switching configuration to "+nextConfig)
        switchBlockyConf(nextConfig)

# This gets called when a user logs out
def userRemoved (userId, userPath):
    print("User ",userId," logged out")
    if (userId in userConfigs and userConfigs[userId] == currentConfig):
        print("Switching to default configuration")
        switchBlockyConf(defaultConfig)

# Start the blocky process with the default config
switchBlockyConf(defaultConfig)

# Subscribe to login and logout events
dbus.mainloop.glib.DBusGMainLoop(set_as_default = True)
bus = dbus.SystemBus ()
proxy = bus.get_object("org.freedesktop.login1", "/org/freedesktop/login1")
manager = dbus.Interface(proxy, "org.freedesktop.login1.Manager")
manager.connect_to_signal("UserNew", userNew)
manager.connect_to_signal("UserRemoved", userRemoved)

# Run the GLib event loop to process DBus signals as they arrive
mainloop = GLib.MainLoop ()
mainloop.run ()
