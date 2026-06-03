#!/bin/bash

SSID=$(/Sy*/L*/Priv*/Apple8*/V*/C*/R*/airport -I | grep SSID | grep -v BSSID | awk '{print $2,$3,$4,$5}')

networksetup -removepreferredwirelessnetwork en0 $SSID
networksetup -setnetworkserviceenabled Wi-Fi off
networksetup -setnetworkserviceenabled Wi-Fi on
unset SSID

exit 0