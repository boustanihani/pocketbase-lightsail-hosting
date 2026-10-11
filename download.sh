#!/bin/bash
# Downloads the setup scripts to /myapps/setup, without running anything:
#
#   curl -fsSL https://raw.githubusercontent.com/boustanihani/pocketbase-lightsail-hosting/main/download.sh | sudo bash
#
# Then adjust the settings and run all parts, or one at a time:
#   sudo nano /myapps/setup/00_config.cfg
#   sudo bash /myapps/setup/01_run_all_scripts.sh
#
# Running it again updates the scripts but keeps your 00_config.cfg.

# All in a function, so a cut-off download can't run half a script.
main() {
    set -euo pipefail
    repo=boustanihani/pocketbase-lightsail-hosting
    branch=main
    dest=/myapps/setup

    if [ "$EUID" -ne 0 ]; then
        echo "Please run it with sudo:" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/$repo/$branch/download.sh | sudo bash" >&2
        exit 1
    fi

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # GitHub's tarball of the branch; only its parts/ folder is unpacked.
    curl -fsSL "https://github.com/$repo/archive/refs/heads/$branch.tar.gz" \
        | tar -xz -C "$tmp" --strip-components=2 "${repo#*/}-$branch/parts"

    mkdir -p "$dest"
    if [ -f "$dest/00_config.cfg" ]; then
        rm "$tmp/00_config.cfg"       # keep the settings already there
    fi
    rm -f "$dest"/*.sh                # drops parts that were renamed or removed
    cp -a "$tmp"/* "$dest/"
    chmod 600 "$dest/00_config.cfg"   # it may hold a password

    echo "Setup scripts are in $dest:"
    echo "  settings:  sudo nano $dest/00_config.cfg"
    echo "  run all:   sudo bash $dest/01_run_all_scripts.sh"
    echo "  or one at a time, from:  sudo bash $dest/02_install_dependencies.sh"
}

main "$@"
