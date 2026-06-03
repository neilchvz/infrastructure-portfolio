#!/bin/bash

sudo dscl . -merge /Groups/admin GroupMembership $(stat -f "%Su" /dev/console)