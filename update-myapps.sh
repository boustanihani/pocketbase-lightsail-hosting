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
