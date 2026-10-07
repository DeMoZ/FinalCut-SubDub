#!/bin/sh
# Removes SubDub from this Mac.
APP="/Applications/SubDub.app"
pluginkit -r "$APP/Contents/PlugIns/SubDubExtension.appex" 2>/dev/null
sudo rm -rf "$APP"
sudo pkgutil --forget com.subdub.app.pkg 2>/dev/null
echo "SubDub removed. Generated files remain in ~/Movies/SubDub."
