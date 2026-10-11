#!/bin/bash
# Updates the system and installs what the other parts rely on:
#
#   supervisor             keeps Caddy, Pocketbase, Filebrowser and the Node
#                          app running (07–10)
#   curl, jq, unzip        fetch and unpack the binaries (06)
#   sshguard               bans IPs that keep failing SSH logins, via nftables —
#                          so the bans don't show in Lightsail's firewall
#   unattended-upgrades    installs security updates by itself
#   earlyoom, zram-config  memory protection (04)
#   tilde, btop            an easy text editor and a process viewer, for you
#
# Node.js isn't here: 06 installs it from NodeSource, since Ubuntu's package
# is outdated.

source "$(dirname "$0")/common.sh"

apt_get update
apt_get --with-new-pkgs upgrade
apt_get install curl jq supervisor unzip sshguard tilde btop unattended-upgrades earlyoom zram-config
