# Install Speedtest CLI

## Overview
A shell script that downloads and installs the Ookla Speedtest CLI 
on macOS devices, enabling technicians to run internet speed tests 
remotely via terminal without end user involvement.

## What this script does
- Creates a temporary working directory
- Downloads the official Ookla Speedtest CLI binary via curl
- Extracts the tarball
- Moves the binary to `/usr/local/bin` and sets executable permissions
- Speedtest CLI is then available system-wide via terminal

## Why this script exists
Monitoring client ISP performance required a consistent, reliable way 
to run speed tests remotely. Rather than asking end users to locate 
and run an app, this script deployed the Speedtest CLI silently via 
RMM — allowing L2 technicians to call `speedtest` directly through 
a backstage terminal session and pull results without any user 
interaction.

## Origin and context
Originally deployed via RMM before the fleet transitioned to Addigy. 
Kept as a reference — Addigy includes its own built-in Speedtest 
functionality, making this script largely legacy. Included here to 
document the evolution of the tooling approach.

## Usage
```bash
sudo bash install-speedtest-cli.sh
```

After installation:
```bash
speedtest
```

## File
[install-speedtest-cli.sh](./install-speedtest-cli.sh)