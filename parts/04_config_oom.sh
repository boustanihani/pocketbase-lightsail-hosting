#!/bin/bash
# Protection against running out of memory. The Lightsail image has no swap
# on disk, so:
#
# zram-config (installed by 02, nothing to set up) adds compressed swap in
# RAM as a first buffer.
#
# earlyoom is the backstop. Without it the kernel's own OOM killer reacts too
# late: the server freezes for minutes and may kill sshd, locking you out.
# Its defaults protect nothing in particular, so:
#   -m 10 -s 10  act when free RAM *and* free swap both drop below 10%
#   --avoid      never kill sshd, supervisord, systemd, sudo or bash, so you
#                keep access and Supervisor keeps running the services
#   --prefer     kill the Node app first: it's the likeliest leak, and
#                autorestart=true brings it back
#   -r 3600      an hourly memory report in the journal
#
# Check:
#   systemctl status earlyoom                         # shows the running args
#   journalctl -u earlyoom | grep -i kill             # what earlyoom killed
#   journalctl -k | grep -iE 'oom|killed process'     # the kernel's OOM killer
# /etc/default/earlyoom is yours: package updates don't overwrite it.

source "$(dirname "$0")/common.sh"

write_file /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-r 3600 -m 10 -s 10 --avoid '(^|/)(sshd|supervisord|systemd|sudo|bash)$' --prefer '^node$'"
EOF
systemctl restart earlyoom
