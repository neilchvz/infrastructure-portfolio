#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Device Fact: Internet Upload Speed
# Author:      Neil Chavez
# Platform:    macOS (Addigy MDM)
# Purpose:     Returns the current WAN upload speed in Mbps.
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

UPLOAD=$(echo "$RESULT" | grep -i "Upload" | sed -E 's/[^0-9\.]//g')

if [[ "$UPLOAD" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo $UPLOAD
else
    echo 0
fi
