#!/bin/bash
#
# AWS Lightsail launch script - Pocketbase + Filebrowser + Caddy + Node.js
# Keep under ~12KB raw (Lightsail limits base64-encoded user-data to 16KB)

# sudo cat /var/log/cloud-init-output.log
# sudo tail -f /var/log/cloud-init-output.log (FOLLOW LIVE)
# sudo cat /var/log/cloud-init-output.log | curl -s -F "content=<-" https://dpaste.com/api/v2/
# sudo cat /myapps/filebrowser/filebrowser.err.log | grep -i password

AUTOSTART_CADDY=true
AUTOSTART_FILEBROWSER=true
AUTOSTART_POCKETBASE=true
AUTOSTART_NODEAPP=false

POCKETBASE_EMAIL="user@provider.com"
POCKETBASE_PASS="12345678"

# For HTTPS: replace ":80" with your domain & open port 443
CUSTOM_DOMAIN=":80"

NODEAPP_RUN=index.js
NODEAPP_PORT=8092

export DEBIAN_FRONTEND=noninteractive # Do not ask questions
export NEEDRESTART_MODE=a # Restart systemd services if needed

apt update && apt upgrade -y
apt install -y curl jq supervisor unzip sshguard tilde btop unattended-upgrades
mkdir -p /myapps/caddy /myapps/pocketbase /myapps/filebrowser /myapps/nodeapp

# Quoted heredoc — no var expansion
cat > /myapps/install-update-binaries.sh <<'BINEOF'
#!/bin/bash
# pipefail catches `curl | bash` failures (e.g. NodeSource bailing on debconf).
set -eo pipefail

NODE_MAJOR=22

# --first-run is passed by script.sh on initial install.
# In that mode we skip stop/backup/restart logic since there's nothing running yet.
FIRST_RUN=false
[ "$1" = "--first-run" ] && FIRST_RUN=true

# Start a Supervisor program only if its config has autostart=true.
start_if_autostart() {
    local prog="$1" conf="/etc/supervisor/conf.d/$1.conf"
    if [ -f "$conf" ] && grep -qE '^autostart\s*=\s*true\s*$' "$conf"; then
        supervisorctl start "$prog"
    else
        echo "($prog skipped — autostart not true)"
    fi
}

echo "=== Fetching latest versions ==="

POCKETBASE_LATEST=$(curl -s https://api.github.com/repos/pocketbase/pocketbase/releases/latest | jq -r '.tag_name | ltrimstr("v")')
FILEBROWSER_LATEST=$(curl -s https://api.github.com/repos/filebrowser/filebrowser/releases/latest | jq -r '.tag_name | ltrimstr("v")')

if [ -z "$POCKETBASE_LATEST" ] || [ "$POCKETBASE_LATEST" = "null" ]; then
    echo "ERROR: Failed to fetch Pocketbase version. Aborting." >&2; exit 1
fi
if [ -z "$FILEBROWSER_LATEST" ] || [ "$FILEBROWSER_LATEST" = "null" ]; then
    echo "ERROR: Failed to fetch Filebrowser version. Aborting." >&2; exit 1
fi

# X.Y.Z semver match, first hit only (filebrowser appends a commit hash).
POCKETBASE_CURRENT=$(/myapps/pocketbase/pocketbase --version 2>/dev/null | grep -oP 'v?\K\d+\.\d+\.\d+' | head -n1 || echo "none")
FILEBROWSER_CURRENT=$(/myapps/filebrowser/filebrowser version 2>/dev/null | grep -oP 'v?\K\d+\.\d+\.\d+' | head -n1 || echo "none")
CADDY_CURRENT=$(/myapps/caddy/caddy version 2>/dev/null | grep -oP 'v?\K\d+\.\d+\.\d+' | head -n1 || echo "none")
NODE_CURRENT=$(node -v 2>/dev/null | sed 's/^v//' || echo "none")
NODE_INSTALLED_MAJOR=$(echo "$NODE_CURRENT" | grep -oE '^[0-9]+' || echo "none")

echo "Pocketbase:  ${POCKETBASE_CURRENT} → ${POCKETBASE_LATEST}"
echo "Filebrowser: ${FILEBROWSER_CURRENT} → ${FILEBROWSER_LATEST}"
echo "Caddy:       ${CADDY_CURRENT} → latest build"
echo "Node.js:     ${NODE_CURRENT} → latest ${NODE_MAJOR}.x"
echo ""

if [ -t 0 ]; then # Only run inside interactive terminals (0 = stdin)
    read -p "Proceed? (y/N) " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
fi

mkdir -p /myapps/caddy /myapps/pocketbase /myapps/filebrowser /myapps/nodeapp

if ! $FIRST_RUN; then
    echo ""
    echo "=== Stopping services ==="
    supervisorctl stop nodeapp filebrowser pocketbase caddy

    echo ""
    echo "=== Backing up current binaries ==="
    cp /myapps/caddy/caddy             /myapps/caddy/caddy.bak
    cp /myapps/pocketbase/pocketbase   /myapps/pocketbase/pocketbase.bak
    cp /myapps/filebrowser/filebrowser /myapps/filebrowser/filebrowser.bak
fi

echo ""
echo "=== Downloading binaries ==="

# Capture exit codes manually so we can clean up partial files before exit.
DOWNLOAD_FAILED=0
curl -fsSL -o /myapps/caddy/caddy.tmp "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/mholt/caddy-ratelimit" || DOWNLOAD_FAILED=1
wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${POCKETBASE_LATEST}/pocketbase_${POCKETBASE_LATEST}_linux_amd64.zip" -O /myapps/pocketbase/pocketbase.zip || DOWNLOAD_FAILED=1
wget -q "https://github.com/filebrowser/filebrowser/releases/download/v${FILEBROWSER_LATEST}/linux-amd64-filebrowser.tar.gz" -O /myapps/filebrowser/filebrowser.tar.gz || DOWNLOAD_FAILED=1

for f in /myapps/caddy/caddy.tmp /myapps/pocketbase/pocketbase.zip /myapps/filebrowser/filebrowser.tar.gz; do
    [ ! -s "$f" ] && DOWNLOAD_FAILED=1
done

if [ "$DOWNLOAD_FAILED" -eq 1 ]; then
    echo "ERROR: One or more downloads failed." >&2
    rm -f /myapps/caddy/caddy.tmp /myapps/pocketbase/pocketbase.zip /myapps/filebrowser/filebrowser.tar.gz
    if ! $FIRST_RUN; then
        echo "Restoring previous binaries and restarting services." >&2
        mv /myapps/caddy/caddy.bak             /myapps/caddy/caddy
        mv /myapps/pocketbase/pocketbase.bak   /myapps/pocketbase/pocketbase
        mv /myapps/filebrowser/filebrowser.bak /myapps/filebrowser/filebrowser
        start_if_autostart caddy
        start_if_autostart pocketbase
        start_if_autostart filebrowser
        start_if_autostart nodeapp
    fi
    echo "" >&2
    echo "NOTE: Re-run after fixing: sudo bash /myapps/install-update-binaries.sh" >&2
    exit 1
fi

echo ""
echo "=== Installing binaries ==="

chmod +x /myapps/caddy/caddy.tmp
mv /myapps/caddy/caddy.tmp /myapps/caddy/caddy

cd /myapps/pocketbase
unzip -qo pocketbase.zip pocketbase
rm pocketbase.zip
chmod +x pocketbase

cd /myapps/filebrowser
tar -xzf filebrowser.tar.gz filebrowser
rm filebrowser.tar.gz
chmod +x filebrowser

echo ""
echo "=== Installing/updating Node.js ==="

if [ "$NODE_INSTALLED_MAJOR" != "$NODE_MAJOR" ]; then
    echo "Setting up Node.js ${NODE_MAJOR}.x repo (was: ${NODE_INSTALLED_MAJOR:-none})"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    # Verify apt will actually pull the right major version. Catches both the
    # "no sources file written" failure and any future repo-config breakage,
    # without depending on NodeSource's chosen filename (.list vs .sources).
    NODE_CANDIDATE=$(apt-cache policy nodejs | awk '/Candidate:/ {print $2}')
    if ! echo "$NODE_CANDIDATE" | grep -qE "^${NODE_MAJOR}\."; then
        echo "ERROR: nodejs candidate is '${NODE_CANDIDATE}', expected ${NODE_MAJOR}.x — NodeSource repo not active." >&2
        exit 1
    fi
    apt install -y nodejs
else
    apt update -qq
    apt install -y --only-upgrade nodejs
fi

echo ""
echo "=== Registering Supervisor configs ==="
# First-install: registers programs and auto-starts those with autostart=true.
# Update: no-op unless a .conf changed (then picks up the change).
supervisorctl reread
supervisorctl update

if ! $FIRST_RUN; then
    echo ""
    echo "=== Starting services ==="
    start_if_autostart caddy
    start_if_autostart pocketbase
    start_if_autostart filebrowser
    start_if_autostart nodeapp
fi

echo ""
echo "=== Done ==="
echo "Caddy:       $(/myapps/caddy/caddy version 2>/dev/null | head -1)"
echo "Pocketbase:  $(/myapps/pocketbase/pocketbase --version 2>/dev/null)"
echo "Filebrowser: $(/myapps/filebrowser/filebrowser version 2>/dev/null)"
echo "Node.js:     $(node -v 2>/dev/null)"
echo ""
if ls /myapps/caddy/caddy.bak /myapps/pocketbase/pocketbase.bak /myapps/filebrowser/filebrowser.bak >/dev/null 2>&1; then
    echo "Backups kept at *.bak — remove with:"
    echo "  sudo rm /myapps/caddy/caddy.bak /myapps/pocketbase/pocketbase.bak /myapps/filebrowser/filebrowser.bak"
fi
BINEOF
chmod +x /myapps/install-update-binaries.sh

# Caddy + Supervisor configs.
# Unquoted heredoc: ${CUSTOM_DOMAIN}, ${NODEAPP_PORT} expand. {path}, {remote_host} are safe.
cat > /myapps/caddy/Caddyfile <<EOF
{
    order rate_limit before basic_auth
}

${CUSTOM_DOMAIN} {
    request_body {
        max_size 100MB
    }

    handle /filebrowser {
        redir {path}/ permanent
    }
    handle /filebrowser/* {
        rate_limit {
            zone filebrowser_login {
                match {
                    method POST
                    path /filebrowser/api/login
                }
                key    {remote_host}
                events 5
                window 1m
            }
        }
        reverse_proxy localhost:8091
    }

    handle /nodeapp {
        redir {path}/ permanent
    }
    handle /nodeapp/* {
        reverse_proxy localhost:${NODEAPP_PORT}
    }

    handle {
        reverse_proxy localhost:8090 {
            transport http {
                read_timeout 360s
            }
        }
    }
}
EOF

cat > /etc/supervisor/conf.d/caddy.conf <<EOF
[program:caddy]
directory=/myapps/caddy
command=/myapps/caddy/caddy run --config /myapps/caddy/Caddyfile
environment=XDG_DATA_HOME="/myapps/caddy/data",XDG_CONFIG_HOME="/myapps/caddy/config"
autostart=${AUTOSTART_CADDY}
autorestart=true
stderr_logfile=/myapps/caddy/caddy.err.log
stdout_logfile=/myapps/caddy/caddy.out.log
user=root
EOF

cat > /etc/supervisor/conf.d/pocketbase.conf <<EOF
[program:pocketbase]
directory=/myapps/pocketbase
command=/myapps/pocketbase/pocketbase serve --http=127.0.0.1:8090
autostart=${AUTOSTART_POCKETBASE}
autorestart=true
stderr_logfile=/myapps/pocketbase/pocketbase.err.log
stdout_logfile=/myapps/pocketbase/pocketbase.out.log
user=root
EOF

cat > /etc/supervisor/conf.d/filebrowser.conf <<EOF
[program:filebrowser]
directory=/myapps/filebrowser
command=/myapps/filebrowser/filebrowser -r /myapps -a 127.0.0.1 -p 8091 --baseurl /filebrowser
autostart=${AUTOSTART_FILEBROWSER}
autorestart=true
stderr_logfile=/myapps/filebrowser/filebrowser.err.log
stdout_logfile=/myapps/filebrowser/filebrowser.out.log
user=root
EOF

# Nodeapp: starts disabled. Flip autostart to true after uploading your app.
cat > /etc/supervisor/conf.d/nodeapp.conf <<EOF
[program:nodeapp]
directory=/myapps/nodeapp
command=/usr/bin/node /myapps/nodeapp/${NODEAPP_RUN}
environment=NODE_ENV="production",PORT="${NODEAPP_PORT}"
autostart=${AUTOSTART_NODEAPP}
autorestart=true
startsecs=5
startretries=3
stopsignal=TERM
stopwaitsecs=15
stderr_logfile=/myapps/nodeapp/nodeapp.err.log
stdout_logfile=/myapps/nodeapp/nodeapp.out.log
user=root
EOF

# SSH: key-based auth only (drop-in survives package upgrades)
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
EOF
systemctl restart ssh

# Network kernel parameters (drop-in is idempotent and doesn't mutate /etc/sysctl.conf)
cat > /etc/sysctl.d/99-hardening.conf <<EOF
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.log_martians=1
EOF
sysctl --system

# Install all binaries via the helper (single source of truth)
bash /myapps/install-update-binaries.sh --first-run

# Pocketbase superuser (|| true so re-runs don't fail)
/myapps/pocketbase/pocketbase superuser create "${POCKETBASE_EMAIL}" "${POCKETBASE_PASS}" || true

mkdir -p /myapps/pocketbase/pb_public
cat > /myapps/pocketbase/pb_public/index.html <<'EOF'
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"></head><body><h1>Seite in Arbeit...</h1></body></html>
EOF

echo "Installation completed at $(date)"
