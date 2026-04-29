#!/bin/bash
#
# AWS Lightsail launch script - Pocketbase + Filebrowser + Caddy.
#
# IMPORTANT: This script is written to be POSIX-compatible (no bashisms in the
# top-level setup) so it works whether cloud-init runs it under bash or dash.
# Run manually with:  sudo bash script.sh   (NOT `sudo sh script.sh`)

# INIT SCRIPT LOGS:
# sudo cat /var/log/cloud-init-output.log
# sudo tail -f /var/log/cloud-init-output.log (FOLLOW LIVE)
# sudo cat /var/log/cloud-init-output.log | curl -s -F "content=<-" https://dpaste.com/api/v2/

# FILEBROWSER CREDENTIALS:
# sudo cat /myapps/filebrowser/filebrowser.err.log | grep -i password
# sudo head -20 /myapps/filebrowser/filebrowser.err.log

POCKETBASE_EMAIL="user@provider.com"
POCKETBASE_PASS="12345678"

# To enable HTTPS: replace ":80" with your domain (e.g., "sub.domain.ext")
CUSTOM_DOMAIN=":80"

apt update && apt upgrade -y

apt install -y curl jq supervisor unzip sshguard tilde btop unattended-upgrades

mkdir -p /myapps/pocketbase /myapps/filebrowser /myapps/caddy

# Fetch latest versions
POCKETBASE_VERSION=$(curl -s https://api.github.com/repos/pocketbase/pocketbase/releases/latest | jq -r '.tag_name | ltrimstr("v")')
FILEBROWSER_VERSION=$(curl -s https://api.github.com/repos/filebrowser/filebrowser/releases/latest | jq -r '.tag_name | ltrimstr("v")')

if [ -z "$POCKETBASE_VERSION" ] || [ "$POCKETBASE_VERSION" = "null" ]; then
    echo "ERROR: Failed to fetch latest Pocketbase version. Aborting." >&2
    exit 1
fi
if [ -z "$FILEBROWSER_VERSION" ] || [ "$FILEBROWSER_VERSION" = "null" ]; then
    echo "ERROR: Failed to fetch latest Filebrowser version. Aborting." >&2
    exit 1
fi

# Install Caddy with rate limiting module (prebuilt from Caddy's download API)
curl -fsSL -o /myapps/caddy/caddy "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/mholt/caddy-ratelimit"
if [ ! -s /myapps/caddy/caddy ]; then
    echo "ERROR: Caddy download failed or empty. Aborting." >&2
    exit 1
fi
chmod +x /myapps/caddy/caddy

cd /myapps/pocketbase
wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${POCKETBASE_VERSION}/pocketbase_${POCKETBASE_VERSION}_linux_amd64.zip"
unzip -q "pocketbase_${POCKETBASE_VERSION}_linux_amd64.zip"
rm "pocketbase_${POCKETBASE_VERSION}_linux_amd64.zip"
chmod +x pocketbase

# `|| true` so re-runs don't fail if the superuser already exists
./pocketbase superuser create "${POCKETBASE_EMAIL}" "${POCKETBASE_PASS}" || true

mkdir -p pb_public
cat > pb_public/index.html <<'EOF'
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"></head><body><h1>Seite in Arbeit...</h1></body></html>
EOF

cd /myapps/filebrowser
wget -q "https://github.com/filebrowser/filebrowser/releases/download/v${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz"
tar -xzf linux-amd64-filebrowser.tar.gz
rm linux-amd64-filebrowser.tar.gz
chmod +x filebrowser

cat > /myapps/update-myapps.sh <<'UPDATEEOF'
#!/bin/bash

# Update script for Caddy, Pocketbase, and Filebrowser
# Usage: sudo bash /myapps/update-myapps.sh

set -e

echo "=== Fetching latest versions ==="

POCKETBASE_LATEST=$(curl -s https://api.github.com/repos/pocketbase/pocketbase/releases/latest | jq -r '.tag_name | ltrimstr("v")')
FILEBROWSER_LATEST=$(curl -s https://api.github.com/repos/filebrowser/filebrowser/releases/latest | jq -r '.tag_name | ltrimstr("v")')

if [ -z "$POCKETBASE_LATEST" ] || [ "$POCKETBASE_LATEST" = "null" ]; then
    echo "ERROR: Failed to fetch latest Pocketbase version. Aborting." >&2
    exit 1
fi
if [ -z "$FILEBROWSER_LATEST" ] || [ "$FILEBROWSER_LATEST" = "null" ]; then
    echo "ERROR: Failed to fetch latest Filebrowser version. Aborting." >&2
    exit 1
fi

# Match a proper X.Y.Z semver (skipping leading `v` if present) and take only the first hit.
# Filebrowser appends a commit hash like `v2.63.2/7970c26c`,
# which the broader pattern `[\d.]+` would split into multiple matches.
POCKETBASE_CURRENT=$(/myapps/pocketbase/pocketbase --version 2>/dev/null | grep -oP 'v?\K\d+\.\d+\.\d+' | head -n1 || echo "unknown")
FILEBROWSER_CURRENT=$(/myapps/filebrowser/filebrowser version 2>/dev/null | grep -oP 'v?\K\d+\.\d+\.\d+' | head -n1 || echo "unknown")
CADDY_CURRENT=$(/myapps/caddy/caddy version 2>/dev/null | grep -oP 'v?\K\d+\.\d+\.\d+' | head -n1 || echo "unknown")

echo "Pocketbase:  ${POCKETBASE_CURRENT} → ${POCKETBASE_LATEST}"
echo "Filebrowser: ${FILEBROWSER_CURRENT} → ${FILEBROWSER_LATEST}"
echo "Caddy:       ${CADDY_CURRENT} → latest build"
echo ""
read -p "Proceed with update? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "=== Stopping services ==="
supervisorctl stop filebrowser 2>/dev/null || true
supervisorctl stop pocketbase 2>/dev/null || true
supervisorctl stop caddy 2>/dev/null || true

echo ""
echo "=== Backing up current binaries ==="
cp /myapps/caddy/caddy /myapps/caddy/caddy.bak
cp /myapps/pocketbase/pocketbase /myapps/pocketbase/pocketbase.bak
cp /myapps/filebrowser/filebrowser /myapps/filebrowser/filebrowser.bak

echo ""
echo "=== Downloading updates ==="

# `set -e` would normally abort on a failed curl/wget, but we want to clean
# up partial files and restart services first, so we capture exit codes.
DOWNLOAD_FAILED=0

curl -fsSL -o /myapps/caddy/caddy.tmp "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/mholt/caddy-ratelimit" || DOWNLOAD_FAILED=1
wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${POCKETBASE_LATEST}/pocketbase_${POCKETBASE_LATEST}_linux_amd64.zip" -O /myapps/pocketbase/pocketbase.zip || DOWNLOAD_FAILED=1
wget -q "https://github.com/filebrowser/filebrowser/releases/download/v${FILEBROWSER_LATEST}/linux-amd64-filebrowser.tar.gz" -O /myapps/filebrowser/filebrowser.tar.gz || DOWNLOAD_FAILED=1

for f in /myapps/caddy/caddy.tmp /myapps/pocketbase/pocketbase.zip /myapps/filebrowser/filebrowser.tar.gz; do
    if [ ! -s "$f" ]; then
        DOWNLOAD_FAILED=1
    fi
done

if [ "$DOWNLOAD_FAILED" -eq 1 ]; then
    echo "ERROR: One or more downloads failed. Aborting and restoring services." >&2
    rm -f /myapps/caddy/caddy.tmp /myapps/pocketbase/pocketbase.zip /myapps/filebrowser/filebrowser.tar.gz
    rm -f /myapps/caddy/caddy.bak /myapps/pocketbase/pocketbase.bak /myapps/filebrowser/filebrowser.bak
    supervisorctl start caddy
    supervisorctl start pocketbase
    supervisorctl start filebrowser
    exit 1
fi

echo ""
echo "=== Installing updates ==="

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
echo "=== Starting services ==="
supervisorctl start caddy
supervisorctl start pocketbase
supervisorctl start filebrowser

echo ""
echo "=== Done ==="
echo "Caddy:       $(/myapps/caddy/caddy version 2>/dev/null | head -1)"
echo "Pocketbase:  $(/myapps/pocketbase/pocketbase --version 2>/dev/null)"
echo "Filebrowser: $(/myapps/filebrowser/filebrowser version 2>/dev/null)"
echo ""
echo "Backups kept at *.bak - remove with:"
echo "  sudo rm /myapps/caddy/caddy.bak /myapps/pocketbase/pocketbase.bak /myapps/filebrowser/filebrowser.bak"
UPDATEEOF
chmod +x /myapps/update-myapps.sh

# Note: This heredoc uses <<EOF (not <<'EOF') so ${CUSTOM_DOMAIN} expands.
# Caddy placeholders like {path} and {remote_host} are safe because the shell
# only expands ${...} and $(...), not bare {braces}.
cat > /myapps/caddy/Caddyfile <<EOF
{
    order rate_limit before basic_auth
}

${CUSTOM_DOMAIN} {
    request_body {
        max_size 10MB
    }
    
    # Filebrowser (must come before root)
    handle /filebrowser {
        redir {path}/ permanent
    }
    handle /filebrowser/* {
        # Rate limit login attempts (5 per minute per IP)
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
    
    # Pocketbase
    handle {
        reverse_proxy localhost:8090 {
            transport http {
                read_timeout 360s
            }
        }
    }
}
EOF

cat > /etc/supervisor/conf.d/caddy.conf <<'EOF'
[program:caddy]
directory=/myapps/caddy
command=/myapps/caddy/caddy run --config /myapps/caddy/Caddyfile
environment=XDG_DATA_HOME="/myapps/caddy/data",XDG_CONFIG_HOME="/myapps/caddy/config"
autostart=true
autorestart=true
stderr_logfile=/myapps/caddy/caddy.err.log
stdout_logfile=/myapps/caddy/caddy.out.log
logfile_maxbytes=10MB
logfile_backups=5
user=root
EOF

cat > /etc/supervisor/conf.d/pocketbase.conf <<'EOF'
[program:pocketbase]
directory=/myapps/pocketbase
command=/myapps/pocketbase/pocketbase serve --http=127.0.0.1:8090
autostart=true
autorestart=true
stderr_logfile=/myapps/pocketbase/pocketbase.err.log
stdout_logfile=/myapps/pocketbase/pocketbase.out.log
logfile_maxbytes=10MB
logfile_backups=5
user=root
EOF

cat > /etc/supervisor/conf.d/filebrowser.conf <<'EOF'
[program:filebrowser]
directory=/myapps/filebrowser
command=/myapps/filebrowser/filebrowser -r /myapps -a 127.0.0.1 -p 8091 --baseurl /filebrowser
autostart=true
autorestart=true
stderr_logfile=/myapps/filebrowser/filebrowser.err.log
stdout_logfile=/myapps/filebrowser/filebrowser.out.log
logfile_maxbytes=10MB
logfile_backups=5
user=root
EOF

# Configure SSH security BEFORE starting services (key-based authentication only)
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
systemctl restart ssh

# Configure network security settings (kernel parameters)
sed -i '/net\.ipv4\.conf\.default\.rp_filter/c\net.ipv4.conf.default.rp_filter=1' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.all\.rp_filter/c\net.ipv4.conf.all.rp_filter=1' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.all\.accept_redirects/c\net.ipv4.conf.all.accept_redirects=0' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.default\.accept_redirects/c\net.ipv4.conf.default.accept_redirects=0' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.all\.send_redirects/c\net.ipv4.conf.all.send_redirects=0' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.all\.log_martians/c\net.ipv4.conf.all.log_martians=1' /etc/sysctl.conf
sysctl -p

# Start services with Supervisor (Caddyfile already in place)
supervisorctl reread
supervisorctl update
sleep 2

echo "Installation completed at $(date)" > /var/log/setup-complete.log
