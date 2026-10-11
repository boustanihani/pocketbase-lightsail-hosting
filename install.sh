#!/bin/bash
# Sets up a fresh Ubuntu 24.04 server (e.g. on AWS Lightsail): downloads the
# setup scripts to /myapps/setup and runs them.
#
#   curl -fsSL https://raw.githubusercontent.com/boustanihani/pocketbase-lightsail-hosting/main/install.sh | sudo bash
#
# It asks how: step by step through every setting, or silently with the
# defaults. To read and adjust everything first, use download.sh instead.

# All in a function, so a cut-off download can't run half a script.
main() {
    set -euo pipefail
    raw=https://raw.githubusercontent.com/boustanihani/pocketbase-lightsail-hosting/main

    if [ "$EUID" -ne 0 ]; then
        echo "Please run it with sudo:" >&2
        echo "  curl -fsSL $raw/install.sh | sudo bash" >&2
        exit 1
    fi

    curl -fsSL "$raw/download.sh" | bash

    # This script comes in through a pipe, so its stdin isn't the keyboard:
    # hand 01 the terminal instead. Without one, 01 installs silently.
    if { : </dev/tty; } 2>/dev/null; then
        bash /myapps/setup/01_run_all_scripts.sh </dev/tty
    else
        bash /myapps/setup/01_run_all_scripts.sh </dev/null
    fi
}

main "$@"
