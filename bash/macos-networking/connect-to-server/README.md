# Connect to Remote Server

## Overview
A zsh script that prompts the current user with a GUI dialog to enter 
their credentials and automatically connects them to a remote file server.

## What this script does
- Presents the user with an AppleScript dialog requesting their username
- Presents a second dialog requesting their password (hidden input)
- Constructs the server connection URL using the provided credentials
- Opens the connection via the specified protocol
- Displays a confirmation dialog on successful connection
- Clears credentials from memory on exit

## Why this script exists
Originally built to automate connections to a Rackspace-hosted file server. 
The GUI dialog approach was intentional — rather than silently mounting 
a drive, the visible prompt served two purposes: notifying users that 
a connection was being established, and giving them the satisfying sense 
that IT had built something polished for them.

One of the earlier scripts in this collection — included as a reference 
for using `osascript` to create user-facing dialogs from shell scripts, 
a technique that has proven useful across many subsequent workflows.

## Customization
Before deploying, update the variables at the top of the script:

| Variable | Replace With |
|----------|-------------|
| `server` | Your server IP or hostname and path |
| `protocol` | Connection protocol (e.g. `smb`, `afp`, `ftp`) |

## Usage
```bash
bash connect-to-server.sh
```

## File
[connect-to-server.sh](./connect-to-server.sh)