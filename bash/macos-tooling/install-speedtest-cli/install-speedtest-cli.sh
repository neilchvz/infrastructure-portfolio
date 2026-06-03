#!/bin/bash

INSTALL_DIR="/usr/local/bin"
TMP_DIR="/tmp/speedtest"

mkdir -p $TMP_DIR
cd $TMP_DIR

# Download official binary
curl -s -O https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-macosx-universal.tgz

# Extract
tar -xvzf ookla-speedtest-1.2.0-macosx-universal.tgz

# Move binary
cp speedtest $INSTALL_DIR/speedtest
chmod +x $INSTALL_DIR/speedtest

echo "Speedtest CLI installed"