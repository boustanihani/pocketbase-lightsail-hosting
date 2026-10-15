#!/bin/bash
# Installs or updates Caddy, Pocketbase, Filebrowser and Node.js.
#
#   sudo bash /myapps/setup/06_install_or_update_binaries.sh
#
# Install mode (a fresh server, or --reinstall): there's nothing to stop or
# back up yet. The services are set up and started by 07–10.
#
# Update mode (the normal case afterwards): shows the versions and asks
# before going on (only in a terminal). Everything that needs the network
# happens while the services keep running: first Node.js (the latest within
# NODE_MAJOR, from NodeSource), then the latest Pocketbase and the newest
# stable Filebrowser within FILEBROWSER_MAJOR, downloaded next to the old
# binaries as *.new, and Caddy too if needed (below). If any of that fails,
# the services keep running on their current versions. Only then comes the
# swap, a few seconds of downtime: the old binaries are kept as *.bak, the
# services stop, the new binaries move into place, and each service whose
# Supervisor config says autostart=true starts again. Services with
# autostart=false get the new binary but stay stopped.
#
# Caddy: the newest version within CADDY_MAJOR, only when it's new or
# CADDY_RATELIMIT changed. With CADDY_RATELIMIT=false, the official build
# from GitHub (seconds). With true, built here with the rate-limit module,
# using xcaddy as Caddy's maintainers recommend: about 5 minutes and 1 GB of
# RAM. Every download gives up after 5 minutes without a result.
#
# A service that won't start with its new version doesn't keep the others
# down: they start anyway, and the end of the output names it. Its .err.log
# says why. To go back to the previous version, e.g. of Caddy:
#   sudo mv /myapps/caddy/caddy.bak /myapps/caddy/caddy
#   sudo supervisorctl start caddy
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
#   sudo bash /myapps/setup/06_install_or_update_binaries.sh --reinstall
#   sudo bash /myapps/setup/08_config_pocketbase.sh    # superuser + sample page

source "$(dirname "$0")/common.sh"

PROGRAMS=(caddy pocketbase filebrowser nodeapp)
BINARIES=(/myapps/caddy/caddy /myapps/pocketbase/pocketbase /myapps/filebrowser/filebrowser)
RUN_AGAIN="sudo bash $SETUP_DIR/06_install_or_update_binaries.sh${1:+ $1}"

# The X.Y.Z in a program's version output, or "none" if it isn't installed.
version_of() {
    local version
    version=$("$@" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1) || true
    echo "${version:-none}"
}

# Install mode if asked for, or if none of the binaries exists yet.
install_mode=true
for bin in "${BINARIES[@]}"; do
    [ -e "$bin" ] && install_mode=false
done
[ "${1:-}" = "--reinstall" ] && install_mode=true

if ! $install_mode; then
    for bin in "${BINARIES[@]}"; do
        if [ ! -e "$bin" ]; then
            echo "ERROR: $bin is missing. To reinstall it, run:" >&2
            echo "  sudo bash $SETUP_DIR/06_install_or_update_binaries.sh --reinstall" >&2
            exit 1
        fi
    done
fi

echo "=== Fetching latest versions ==="

# newest_release REPO REGEX: the newest version among REPO's last 100
# releases whose tag matches REGEX, without the v.
newest_release() {
    curl -s --max-time 30 "https://api.github.com/repos/$1/releases?per_page=100" |
        jq -r '.[].tag_name' | grep -E "$2" | sort -V | tail -n1 | sed 's/^v//'
}

# Newest vN.x.y; betas are vN.x.y-beta.n.
caddy_latest=$(newest_release caddyserver/caddy "^v${CADDY_MAJOR}\.[0-9]+\.[0-9]+$" || true)
pocketbase_latest=$(curl -s --max-time 30 https://api.github.com/repos/pocketbase/pocketbase/releases/latest | jq -r '.tag_name | ltrimstr("v")' || true)
# Newest vN.x.y-stable (betas aren't marked prerelease).
filebrowser_latest=$(newest_release gtsteffaniak/filebrowser "^v${FILEBROWSER_MAJOR}\.[0-9]+\.[0-9]+-stable$" || true)

if [ -z "$caddy_latest" ]; then
    echo "ERROR: No Caddy $CADDY_MAJOR.x found on GitHub. Is CADDY_MAJOR in $CONFIG right?" >&2
    exit 1
fi
if [ -z "$pocketbase_latest" ] || [ "$pocketbase_latest" = "null" ]; then
    echo "ERROR: Couldn't get Pocketbase's latest version from GitHub." >&2
    exit 1
fi
if [ -z "$filebrowser_latest" ]; then
    echo "ERROR: No stable Filebrowser $FILEBROWSER_MAJOR.x found on GitHub. Is FILEBROWSER_MAJOR in $CONFIG right?" >&2
    exit 1
fi

caddy_current=$(version_of /myapps/caddy/caddy version)
# Whether the installed Caddy has the rate-limit module: true or false.
caddy_has_ratelimit=false
modules=$(/myapps/caddy/caddy list-modules 2>/dev/null || true)
[[ $modules == *http.handlers.rate_limit* ]] && caddy_has_ratelimit=true
pocketbase_current=$(version_of /myapps/pocketbase/pocketbase --version)
filebrowser_current=$(version_of /myapps/filebrowser/filebrowser version)
node_current=$(version_of node -v)

echo "Pocketbase:  $pocketbase_current → $pocketbase_latest"
echo "Filebrowser: $filebrowser_current → ${filebrowser_latest%-stable}"
echo "Caddy:       $caddy_current → $caddy_latest"
echo "Node.js:     $node_current → latest $NODE_MAJOR.x"

if ! $install_mode && [ -t 0 ]; then    # only asks in a terminal
    echo
    read -rp "Proceed? (y/N) " answer
    if [[ $answer != [Yy]* ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo
echo "=== Node.js ==="
# needrestart would restart Supervisor, and with it every service, when
# Node.js changes under the running Node app. The services are restarted
# further down anyway.
export NEEDRESTART_SUSPEND=1
if [ "${node_current%%.*}" != "$NODE_MAJOR" ]; then    # 26.11.1 → 26
    echo "Setting up NodeSource's repository for Node.js $NODE_MAJOR.x (was: $node_current)"
    if ! curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; then
        echo "ERROR: Couldn't set up Node.js $NODE_MAJOR.x (see above). Is NODE_MAJOR in $CONFIG right?" >&2
        exit 1
    fi
    # Verify apt will actually pull the right major version. Catches both the
    # "no sources file written" failure and any future repo-config breakage,
    # without depending on NodeSource's chosen filename (.list vs .sources).
    candidate=$(apt-cache policy nodejs | awk '/Candidate:/ {print $2}')
    if [[ $candidate != "$NODE_MAJOR".* ]]; then
        echo "ERROR: apt would install nodejs '$candidate', not $NODE_MAJOR.x — NodeSource's repository isn't active." >&2
        exit 1
    fi
    apt_get install nodejs
else
    apt_get update -qq
    apt_get install --only-upgrade nodejs
fi

echo
echo "=== Downloading ==="
# Next to the old binaries as *.new, while the services keep running.
NEW_FILES=(/myapps/caddy/caddy.tar.gz /myapps/caddy/caddy.new /myapps/pocketbase/pocketbase.zip
    /myapps/pocketbase/pocketbase.new /myapps/filebrowser/filebrowser.new)

# download WHAT URL FILE: says what it loads. Fails on an error, an empty
# file, or after 5 minutes without a result.
download() {
    echo "$1 …"
    curl -fsSL --connect-timeout 30 --max-time 300 -o "$3" "$2" && [ -s "$3" ]
}

# Removes what was downloaded so far, and stops.
download_failed() {
    rm -f "${NEW_FILES[@]}"
    echo "ERROR: Getting the new binaries failed (see above). The services keep running on their current versions." >&2
    echo "Run this again once that's fixed: $RUN_AGAIN" >&2
    exit 1
}

# Builds Caddy with the rate-limit module the way Caddy's maintainers
# recommend: with xcaddy, and the latest Go from go.dev (Ubuntu's is too
# old). Go and everything the build fetches stay in a temporary folder
# that's deleted afterwards.
build_caddy() {
    local dir file sha ok
    dir=$(mktemp -d)
    read -r file sha < <(curl -fsS --max-time 30 "https://go.dev/dl/?mode=json" |
        jq -r '.[0].files[] | select(.os == "linux" and .arch == "amd64" and .kind == "archive") | "\(.filename) \(.sha256)"')
    download "Go, to build Caddy" "https://go.dev/dl/$file" "$dir/go.tar.gz" &&
        echo "$sha  $dir/go.tar.gz" | sha256sum -c --quiet &&
        tar -xzf "$dir/go.tar.gz" -C "$dir" &&
        echo "Building Caddy $caddy_latest with the rate-limit module (takes several minutes) …" &&
        PATH="$dir/go/bin:$PATH" GOPATH="$dir/gopath" GOCACHE="$dir/cache" \
            "$dir/go/bin/go" run github.com/caddyserver/xcaddy/cmd/xcaddy@latest build "v$caddy_latest" \
            --with github.com/mholt/caddy-ratelimit --output /myapps/caddy/caddy.new
    ok=$?
    rm -rf "$dir"
    return $ok
}

# Recreate dirs so we can repair a partially deleted /myapps.
mkdir -p /myapps/caddy /myapps/pocketbase /myapps/filebrowser /myapps/nodeapp
rm -f "${NEW_FILES[@]}"    # leftovers of an interrupted run

# Caddy only when there's a new version, or when the installed one doesn't
# match CADDY_RATELIMIT.
if [ "$caddy_current" = "$caddy_latest" ] && [ "$caddy_has_ratelimit" = "$CADDY_RATELIMIT" ]; then
    echo "Caddy $caddy_current is the latest version and stays."
elif [ "$CADDY_RATELIMIT" = true ]; then
    build_caddy || download_failed
else
    download "Caddy $caddy_latest" \
        "https://github.com/caddyserver/caddy/releases/download/v$caddy_latest/caddy_${caddy_latest}_linux_amd64.tar.gz" \
        /myapps/caddy/caddy.tar.gz || download_failed
    tar -xzOf /myapps/caddy/caddy.tar.gz caddy > /myapps/caddy/caddy.new || download_failed
    rm /myapps/caddy/caddy.tar.gz
fi
download "Pocketbase $pocketbase_latest" \
    "https://github.com/pocketbase/pocketbase/releases/download/v$pocketbase_latest/pocketbase_${pocketbase_latest}_linux_amd64.zip" \
    /myapps/pocketbase/pocketbase.zip || download_failed
unzip -p /myapps/pocketbase/pocketbase.zip pocketbase > /myapps/pocketbase/pocketbase.new || download_failed
rm /myapps/pocketbase/pocketbase.zip
download "Filebrowser ${filebrowser_latest%-stable}" \
    "https://github.com/gtsteffaniak/filebrowser/releases/download/v$filebrowser_latest/linux-amd64-filebrowser" \
    /myapps/filebrowser/filebrowser.new || download_failed

echo
echo "=== Installing ==="
# Only the programs 07–10 have set up; Supervisor doesn't know the others.
registered=()
for prog in "${PROGRAMS[@]}"; do
    [ -f "/etc/supervisor/conf.d/$prog.conf" ] && registered+=("$prog")
done

# Only the binaries that were downloaded; Caddy may have stayed.
new_binaries=()
for bin in "${BINARIES[@]}"; do
    [ -e "$bin.new" ] && new_binaries+=("$bin")
done

if ! $install_mode; then
    for bin in "${new_binaries[@]}"; do
        cp "$bin" "$bin.bak"
    done
    for prog in "${registered[@]}"; do
        if is_up "$prog"; then
            supervisorctl stop "$prog"
        fi
    done
fi
for bin in "${new_binaries[@]}"; do
    chmod +x "$bin.new"
    mv "$bin.new" "$bin"
done

echo
echo "=== Starting services ==="
not_started=()
# Not in install mode: a service's settings may be gone too (say, after
# deleting /myapps), and 07–10 write them before starting it.
if $install_mode || [ ${#registered[@]} -eq 0 ]; then
    echo "(07–10 set up and start them.)"
else
    for prog in "${registered[@]}"; do
        start_if_autostart "$prog" || not_started+=("$prog")
    done
fi

echo
echo "=== Done ==="
echo "Caddy:       $(version_of /myapps/caddy/caddy version)"
echo "Pocketbase:  $(version_of /myapps/pocketbase/pocketbase --version)"
echo "Filebrowser: $(version_of /myapps/filebrowser/filebrowser version)"
echo "Node.js:     $(version_of node -v)"
backups=()
for bin in "${BINARIES[@]}"; do
    [ -e "$bin.bak" ] && backups+=("$bin.bak")
done
if [ ${#backups[@]} -gt 0 ]; then
    echo
    echo "The previous binaries are kept as *.bak. Remove them with:"
    echo "  sudo rm ${backups[*]}"
fi

if [ ${#not_started[@]} -gt 0 ]; then
    echo
    echo "ERROR: ${not_started[*]} didn't start. Its log says why:" >&2
    for prog in "${not_started[@]}"; do
        echo "  sudo tail /myapps/$prog/$prog.err.log" >&2
    done
    echo "Going back to the previous version: see the top of $SETUP_DIR/06_install_or_update_binaries.sh" >&2
    exit 1
fi
