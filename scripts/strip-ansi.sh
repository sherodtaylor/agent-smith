#!/usr/bin/env bash
#
# strip-ansi.sh — pipe-friendly ANSI escape sequence stripper.
#
# Reads stdin line by line and writes stdout with the common ANSI escape
# sequences removed, so log lines emitted by claude's TUI (and other
# terminal-aware programs) become readable when shipped to stdout-based
# log collectors like VictoriaLogs.
#
# Strips two classes of escape:
#   CSI: ESC [ <params> <final-byte>       (colors, cursor moves, clears)
#   OSC: ESC ] <body> BEL                  (window-title sets, hyperlinks)
#
# Streams line-by-line (`sed -u`) so logs flush in real time rather than
# being buffered into chunks.
#
# Usage:
#   <program> | strip-ansi.sh
#   tmux pipe-pane -t main:claude.0 -o "/opt/agent-smith/scripts/strip-ansi.sh >> /proc/1/fd/1"
#
set -euo pipefail
exec sed -u -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g; s/\x1b\\][^\x07]*\x07//g'
