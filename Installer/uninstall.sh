#!/bin/sh
# Removes FCP AutoSubs from this Mac.
APP="/Applications/FCP AutoSubs.app"
pluginkit -r "$APP/Contents/PlugIns/FCPAutoSubsExtension.appex" 2>/dev/null
sudo rm -rf "$APP"
sudo pkgutil --forget com.fcpautosubs.app.pkg 2>/dev/null
echo "FCP AutoSubs removed. Generated files remain in ~/Movies/FCP AutoSubs."
