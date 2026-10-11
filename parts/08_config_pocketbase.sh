#!/bin/bash
# Pocketbase: database, auth and file storage, served at / through Caddy.
#
#   Admin UI:  http://YOUR_IP/_/   (with the underscore and trailing slash)
#   Data:      /myapps/pocketbase/pb_data/     the database — back it up
#   Website:   /myapps/pocketbase/pb_public/   static files served at /
#   Logs:      /myapps/pocketbase/pocketbase.err.log and .out.log
#
# It listens on 127.0.0.1:8090 only; everyone else comes through Caddy.
#
# The superuser POCKETBASE_EMAIL:
#   - With POCKETBASE_PASS set (in 00_config.cfg, or typed into 01's step-by-
#     step setup), it's created, or gets that password if it exists.
#   - With POCKETBASE_PASS empty, it's created with a random password, shown
#     once at the end. If it exists already, nothing changes, so running this
#     again never resets your password.
# Forgot it? Set a new one:
#   sudo /myapps/pocketbase/pocketbase superuser upsert you@example.com 'new-password'
#
# The sample page is only written if pb_public/index.html doesn't exist yet,
# so your own page is never overwritten.
#
# Start over with an empty database (deletes all data!):
#   sudo supervisorctl stop pocketbase && sudo rm -rf /myapps/pocketbase
#   sudo bash /myapps/setup/06_install_or_update_binaries.sh --first-run
#   sudo bash /myapps/setup/08_config_pocketbase.sh

source "$(dirname "$0")/common.sh"

PB=/myapps/pocketbase/pocketbase

# Before the service starts, so the two don't set up a new database at once.
if [ -n "$POCKETBASE_PASS" ]; then
    "$PB" superuser upsert "$POCKETBASE_EMAIL" "$POCKETBASE_PASS"
else
    # Letters and digits only, so a double-click selects all of it.
    pass=$(head -c 64 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9')
    pass=${pass:0:20}
    if out=$("$PB" superuser create "$POCKETBASE_EMAIL" "$pass" 2>&1); then
        echo "$out"
        show_secret "Pocketbase superuser: $POCKETBASE_EMAIL / $pass"
    elif [[ $out == *"must be unique"* ]]; then
        echo "Superuser $POCKETBASE_EMAIL exists already; its password stays as it is."
    else
        echo "$out" >&2
        exit 1
    fi
fi

if [ ! -e /myapps/pocketbase/pb_public/index.html ]; then
    mkdir -p /myapps/pocketbase/pb_public
    cat > /myapps/pocketbase/pb_public/index.html <<'EOF'
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"></head><body><h1>Seite in Arbeit...</h1></body></html>
EOF
    echo "Wrote: /myapps/pocketbase/pb_public/index.html"
fi

write_file /etc/supervisor/conf.d/pocketbase.conf <<EOF
; Written by $SETUP_DIR/08_config_pocketbase.sh from 00_config.cfg.
[program:pocketbase]
directory=/myapps/pocketbase
command=/myapps/pocketbase/pocketbase serve --http=127.0.0.1:8090
autostart=${AUTOSTART_POCKETBASE}
autorestart=true
stderr_logfile=/myapps/pocketbase/pocketbase.err.log
stdout_logfile=/myapps/pocketbase/pocketbase.out.log
user=root
EOF

apply_program pocketbase
