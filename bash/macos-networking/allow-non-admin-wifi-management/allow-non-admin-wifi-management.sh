#!/bin/bash

# Allows non-admin users to manage their WiFi configuration.

/usr/bin/security authorizationdb write system.preferences.network allow
/usr/bin/security authorizationdb write system.settings.network allow
/usr/bin/security authorizationdb write system.services.systemconfiguration.network allow
/usr/bin/security authorizationdb write com.apple.wifi allow
/usr/libexec/airportd prefs RequireAdminNetworkChange=NO RequireAdminIBSS=NO