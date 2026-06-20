#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Device Fact: Internet Download Speed
# Author:      Neil Chavez
# Platform:    macOS (Addigy MDM)
# Purpose:     Returns the current WAN download speed in Mbps.
#              Used as an Addigy Device Fact evaluated by a
#              monitoring alert to detect ISP degradation.
#
# Output:      Numeric value (Mbps) or 0 on parse failure.
#              Addigy stores this value against the device record
#              and evaluates it against a defined threshold.
#
# Deployment:  Assigned to a Flex Policy scoped to a single
#              designated stationary office device by serial number.
#              Must not be deployed fleet-wide — mobile and remote
#              devices will produce inconsistent results.
# ─────────────────────────────────────────────────────────────

RESULT=$(/Library/Addigy/speedtest-cli)

DOWNLOAD=$(echo "$RESULT" | grep -i "Download" | sed -E 's/[^0-9\.]//g')

if [[ "$DOWNLOAD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo $DOWNLOAD
else
    echo 0
fi
