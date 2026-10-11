#!/bin/bash
# Installs or updates Caddy, Pocketbase, Filebrowser and Node.js.
#
#   sudo bash /myapps/setup/06_install_or_update_binaries.sh
#
# Install mode (a fresh server, or --first-run): downloads straight into
# /myapps/*; there's nothing to stop or back up yet. The services are set up
# and started by 07–10.
#
# Update mode (the normal case afterwards): shows the versions and asks
# before going on (only in a terminal), stops the services, backs up the
# binaries as *.bak, downloads the latest Caddy and Pocketbase, the newest
# stable Filebrowser within FILEBROWSER_MAJOR and the latest Node.js within
# NODE_MAJOR, then starts each service whose Supervisor config says
# autostart=true. If a download fails it restores the *.bak binaries, so a
# broken network leaves you where you started. Services with autostart=false
# get the new binary but stay stopped.
#
# Why pin Filebrowser's major version? Its betas are regular GitHub releases,
# not pre-releases, so `releases/latest` can't be trusted to mean stable —
# this picks the newest vN.x.y-stable tag instead. And a new major needs a
# manual migration (v1 → v2 replaced the database), so moving to v3 should be
# a deliberate change of FILEBROWSER_MAJOR in 00_config.cfg, not a side effect.
#
# If just one binary is missing — say you deleted /myapps/pocketbase to start
# over — an update stops before touching anything: it shouldn't quietly turn
# into a fresh install. Ask for install mode explicitly:
#   sudo supervisorctl stop pocketbase      # or it keeps running on the deleted files
#   sudo rm -rf /myapps/pocketbase          # e.g. wipe the database and start over
#   sudo bash /myapps/setup/06_install_or_update_binaries.sh --first-run
#   sudo bash /myapps/setup/08_config_pocketbase.sh    # superuser + sample page

source "$(dirname "$0")/common.sh"

PROGRAMS=(caddy pocketbase filebrowser nodeapp)
BINARIES=(/myapps/caddy/caddy /myapps/pocketbase/pocketbase /myapps/filebrowser/filebrowser)

# Install mode if asked for, or if none of the binaries exists yet.
FIRST_RUN=true
for bin in "${BINARIES[@]}"; do
    [ -e "$bin" ] && FIRST_RUN=false
done
[ "${1:-}" = "--first-run" ] && FIRST_RUN=true

if ! $FIRST_RUN; then
    for bin in "${BINARIES[@]}"; do
        if [ ! -e "$bin" ]; then
            echo "ERROR: $bin is missing. To reinstall it, run:" >&2
            echo "  sudo bash $SETUP_DIR/06_install_or_update_binaries.sh --first-run" >&2
            exit 1
        fi
    done
fi

echo "=== Fetching latest versions ==="

POCKETBASE_LATEST=$(curl -s https://api.github.com/repos/pocketbase/pocketbase/releases/latest | jq -r '.tag_name | ltrimstr("v")')
# Newest vN.x.y-stable (betas aren't marked prerelease).
FILEBROWSER_LATEST=$(curl -s "https://api.github.com/repos/gtsteffaniak/filebrowser/releases?per_page=100" | jq -r '.[].tag_name' | grep -E "^v${FILEBROWSER_MAJOR}\.[0-9]+\.[0-9]+-stable$" | sort -V | tail -n1 | sed 's/^v//' || true)

if [ -z "$POCKETBASE_LATEST" ] || [ "$POCKETBASE_LATEST" = "null" ]; then
    echo "ERROR: Failed to fetch Pocketbase version. Aborting." >&2; exit 1
fi
if [ -z "$FILEBROWSER_LATEST" ] || [ "$FILEBROWSER_LATEST" = "null" ]; then
    echo "ERROR: Failed to fetch Filebrowser version. Aborting." >&2; exit 1
fi

# X.Y.Z semver match, first hit only (filebrowser prints it twice).
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

if ! $FIRST_RUN && [ -t 0 ]; then # Only ask in interactive terminals (0 = stdin)
    read -p "Proceed? (y/N) " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
fi

# Recreate dirs so we can repair a partially deleted /myapps.
mkdir -p /myapps/caddy /myapps/pocketbase /myapps/filebrowser /myapps/nodeapp

# Only the programs 07–10 have set up; Supervisor doesn't know the others.
REGISTERED=()
for prog in "${PROGRAMS[@]}"; do
    [ -f "/etc/supervisor/conf.d/$prog.conf" ] && REGISTERED+=("$prog")
done

if ! $FIRST_RUN; then
    echo ""
    echo "=== Stopping services ==="
    for prog in "${REGISTERED[@]}"; do
        if is_up "$prog"; then
            supervisorctl stop "$prog"
        fi
    done

    echo ""
    echo "=== Backing up current binaries ==="
    for bin in "${BINARIES[@]}"; do
        cp "$bin" "$bin.bak"
    done
fi

echo ""
echo "=== Downloading binaries ==="

# Capture exit codes manually so we can clean up partial files before exit.
DOWNLOAD_FAILED=0
curl -fsSL -o /myapps/caddy/caddy.tmp "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/mholt/caddy-ratelimit" || DOWNLOAD_FAILED=1
curl -fsSL -o /myapps/pocketbase/pocketbase.zip "https://github.com/pocketbase/pocketbase/releases/download/v${POCKETBASE_LATEST}/pocketbase_${POCKETBASE_LATEST}_linux_amd64.zip" || DOWNLOAD_FAILED=1
curl -fsSL -o /myapps/filebrowser/filebrowser.tmp "https://github.com/gtsteffaniak/filebrowser/releases/download/v${FILEBROWSER_LATEST}/linux-amd64-filebrowser" || DOWNLOAD_FAILED=1

for f in /myapps/caddy/caddy.tmp /myapps/pocketbase/pocketbase.zip /myapps/filebrowser/filebrowser.tmp; do
    [ ! -s "$f" ] && DOWNLOAD_FAILED=1
done

if [ "$DOWNLOAD_FAILED" -eq 1 ]; then
    echo "ERROR: One or more downloads failed." >&2
    rm -f /myapps/caddy/caddy.tmp /myapps/pocketbase/pocketbase.zip /myapps/filebrowser/filebrowser.tmp
    if ! $FIRST_RUN; then
        echo "Restoring previous binaries and restarting services." >&2
        for bin in "${BINARIES[@]}"; do
            mv "$bin.bak" "$bin"
        done
        for prog in "${REGISTERED[@]}"; do
            start_if_autostart "$prog"
        done
    fi
    echo "" >&2
    echo "NOTE: Re-run after fixing: sudo bash $SETUP_DIR/06_install_or_update_binaries.sh${1:+ $1}" >&2
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

chmod +x /myapps/filebrowser/filebrowser.tmp
mv /myapps/filebrowser/filebrowser.tmp /myapps/filebrowser/filebrowser

echo ""
echo "=== Installing/updating Node.js ==="

if [ "$NODE_INSTALLED_MAJOR" != "$NODE_MAJOR" ]; then
    echo "Setting up Node.js ${NODE_MAJOR}.x repo (was: ${NODE_INSTALLED_MAJOR:-none})"
    # pipefail catches it if NodeSource's script bails out (e.g. on debconf).
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    # Verify apt will actually pull the right major version. Catches both the
    # "no sources file written" failure and any future repo-config breakage,
    # without depending on NodeSource's chosen filename (.list vs .sources).
    NODE_CANDIDATE=$(apt-cache policy nodejs | awk '/Candidate:/ {print $2}')
    if ! echo "$NODE_CANDIDATE" | grep -qE "^${NODE_MAJOR}\."; then
        echo "ERROR: nodejs candidate is '${NODE_CANDIDATE}', expected ${NODE_MAJOR}.x — NodeSource repo not active." >&2
        exit 1
    fi
    apt_get install nodejs
else
    apt_get update -qq
    apt_get install --only-upgrade nodejs
fi

echo ""
echo "=== Starting services ==="
if [ ${#REGISTERED[@]} -eq 0 ]; then
    echo "(None set up yet; 07–10 do that.)"
fi
for prog in "${REGISTERED[@]}"; do
    start_if_autostart "$prog"
done

echo ""
echo "=== Done ==="
echo "Caddy:       $(/myapps/caddy/caddy version 2>/dev/null | head -1)"
echo "Pocketbase:  $(/myapps/pocketbase/pocketbase --version 2>/dev/null)"
echo "Filebrowser: $(/myapps/filebrowser/filebrowser version 2>/dev/null | awk '/Version/{print $3}')"
echo "Node.js:     $(node -v 2>/dev/null)"
echo ""
if ls /myapps/caddy/caddy.bak /myapps/pocketbase/pocketbase.bak /myapps/filebrowser/filebrowser.bak >/dev/null 2>&1; then
    echo "Backups kept at *.bak — remove with:"
    echo "  sudo rm /myapps/caddy/caddy.bak /myapps/pocketbase/pocketbase.bak /myapps/filebrowser/filebrowser.bak"
fi
