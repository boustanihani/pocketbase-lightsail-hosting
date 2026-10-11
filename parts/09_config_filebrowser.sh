#!/bin/bash
# Filebrowser: a web file manager at /filebrowser/. It's FileBrowser Quantum
# (github.com/gtsteffaniak/filebrowser), the maintained fork of the archived
# original, and shows two sources: all of /myapps, and /etc/supervisor/conf.d
# (named "supervisor"). Both are writable.
#
# First login: user admin, with a one-time password Filebrowser logs at its
# first start. You choose a new one when you log in.
#   sudo grep 'admin password' /myapps/filebrowser/filebrowser.out.log
# The ffmpeg and cacheDir warnings in that log are harmless: there are just
# no video thumbnails, and the 20 GB of free space it recommends doesn't fit
# a small server.
#
# config.yaml, since Filebrowser takes no command-line flags for any of this:
#   baseURL            it's served under /filebrowser/, so its pages, assets
#                      and API need the prefix
#   listen: 127.0.0.1  goes together with trustProxyHeaders. Behind Caddy,
#                      every request comes from 127.0.0.1, so without trusting
#                      X-Forwarded-For, the login rate limit would treat all
#                      visitors as one: eight wrong passwords from anyone
#                      would lock admin out for everybody. Trusting that
#                      header is only safe because Filebrowser listens on
#                      localhost only, and Caddy replaces any X-Forwarded-For
#                      a client sends.
#   name: supervisor   the source's label in the sidebar (else "conf.d")
# Its database (filebrowser.sqlite) and cache (tmp/) are created in
# /myapps/filebrowser.
#
# Login rate limit (built in): 10 attempts per minute per IP and per user;
# 8 wrong passwords in a row lock that IP out of that account for 15 minutes.
# Getting 429 answers? Wait, or clear the counters, which live in memory:
#   sudo supervisorctl restart filebrowser
#
# Forgot the password? Set a new one (it asks for it). Stop the service
# first, or the running Filebrowser keeps its cached users:
#   sudo supervisorctl stop filebrowser
#   cd /myapps/filebrowser && sudo ./filebrowser -c config.yaml user set admin --password
#   sudo supervisorctl start filebrowser
# Or start over with a fresh admin and a new one-time password:
#   sudo supervisorctl stop filebrowser
#   sudo rm /myapps/filebrowser/filebrowser.sqlite*
#   sudo supervisorctl start filebrowser

source "$(dirname "$0")/common.sh"

write_file /myapps/filebrowser/config.yaml <<EOF
# Written by $SETUP_DIR/09_config_filebrowser.sh.
# Change it there and run it again; edits here get overwritten.
http:
  port: 8091
  listen: 127.0.0.1
  baseURL: /filebrowser
  trustProxyHeaders: true
server:
  sources:
    - path: /myapps
    - path: /etc/supervisor/conf.d
      name: supervisor
EOF

write_file /etc/supervisor/conf.d/filebrowser.conf <<EOF
; Written by $SETUP_DIR/09_config_filebrowser.sh from 00_config.cfg.
[program:filebrowser]
directory=/myapps/filebrowser
command=/myapps/filebrowser/filebrowser -c /myapps/filebrowser/config.yaml
autostart=${AUTOSTART_FILEBROWSER}
autorestart=true
stderr_logfile=/myapps/filebrowser/filebrowser.err.log
stdout_logfile=/myapps/filebrowser/filebrowser.out.log
user=root
EOF

apply_program filebrowser
