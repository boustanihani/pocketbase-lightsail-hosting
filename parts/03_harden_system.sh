#!/bin/bash
# Hardens SSH and the network. Both settings are drop-in files, so the
# system's own configs stay untouched and package upgrades leave them alone.
#
# SSH: key-based logins only. After this, password logins are refused — have
# your keys ready. (Lightsail's default key and its browser SSH both use keys.)
#   Verify:  sudo sshd -T | grep -iE 'passwordauthentication|kbdinteractive'
#
#   Why "00-" and not "99-"? sshd takes the first value it reads, and its
#   Include sits at the top of sshd_config, so the lowest-numbered drop-in
#   wins: "00-" beats the image's own 60-cloudimg-settings.conf. That's the
#   opposite of /etc/sysctl.d/, where the last file read wins.
#
# Network kernel settings, for every network interface: the * also covers
# "all" and "default", which alone don't reach an existing interface for
# some of these settings.
#   rp_filter=1         drop packets from implausible sources (anti-spoofing)
#   accept_redirects=0  ignore ICMP route redirects, a man-in-the-middle
#                       trick — on IPv4 and IPv6, since the instance has both
#   send_redirects=0    this is an app server, not a router
#   log_martians=1      log packets with impossible source addresses
#   (rp_filter, send_redirects and log_martians exist for IPv4 only.)
#   Applied right away; at boot, systemd reads all of /etc/sysctl.d/, also
#   for network interfaces that appear later.
#   Verify:  sysctl -a 2>/dev/null | grep -E 'rp_filter|_redirects|martians'
#
# SSHGuard (installed by 02) also bans IPs that keep failing SSH logins.

source "$(dirname "$0")/common.sh"

write_file /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF
systemctl restart ssh   # open sessions stay connected

write_file /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.conf.*.rp_filter=1
net.ipv4.conf.*.accept_redirects=0
net.ipv6.conf.*.accept_redirects=0
net.ipv4.conf.*.send_redirects=0
net.ipv4.conf.*.log_martians=1
EOF
sysctl -p /etc/sysctl.d/99-hardening.conf
