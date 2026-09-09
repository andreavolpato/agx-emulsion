#!/bin/sh
#  design/snapshot.sh — kept as the one-command entry point; the harness now
#  lives in Spektrafilm/Tools/snapshot.sh and captures the real app window.
exec "$(dirname "$0")/../Spektrafilm/Tools/snapshot.sh" "$@"
