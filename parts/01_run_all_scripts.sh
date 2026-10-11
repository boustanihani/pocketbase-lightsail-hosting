#!/bin/bash
# Runs all parts after this one, in order (02, 03, … 10):
#
#   sudo bash /myapps/setup/01_run_all_scripts.sh
#
# First it asks how:
#   1 or ENTER  go through every setting in 00_config.cfg (ENTER keeps the
#               value in brackets); the answers are saved back to the file,
#               except the Pocketbase password
#   2           silent installation with 00_config.cfg as it is
#   c           cancel
# Without a terminal (run from another script, say) it installs silently.
#
# Every part is safe to run again. After a failure, fix the cause and run this
# again — or only the failed part and the ones after it.
#
# All output is appended to /myapps/setup/install.log, except the summary at
# the end, which holds the generated Pocketbase password and only appears on
# screen. If your SSH connection drops, the installation keeps running; log in
# again and follow it with:  sudo tail -f /myapps/setup/install.log

source "$(dirname "$0")/common.sh"

LOG="$SETUP_DIR/install.log"

# ---- Asking -----------------------------------------------------------------

# Goes through the VAR=value lines of 00_config.cfg in order. The comment lines
# above a setting are its question; a blank line drops comments that no
# setting follows, like the file's header.
configure() {
    local line comments=()
    local -a lines
    mapfile -t lines < "$CONFIG"
    SETTINGS=()
    echo
    echo "ENTER keeps the value in [brackets]."
    for line in "${lines[@]}"; do
        case $line in
            '#'*) comments+=("${line#'#'}") ;;
            '')   comments=() ;;
            *=*)  SETTINGS+=("${line%%=*}")
                  if [ ${#comments[@]} -gt 0 ]; then
                      echo
                      printf '%s\n' "${comments[@]# }"
                  fi
                  comments=()
                  ask "${line%%=*}" ;;
        esac
    done
}

# Asks for one setting until the answer is valid. ENTER keeps the current value.
ask() {
    local var=$1 current=${!1} answer error hint=random
    while true; do
        if [[ $var == *_PASS ]]; then
            [ -n "$current" ] && hint="as in 00_config.cfg"
            read -rsp "$var [$hint]: " answer
            echo
        else
            read -rp "$var [$current]: " answer
        fi
        answer=${answer:-$current}
        error=$(check "$var" "$answer" "$current") && break
        echo "  ✗ $error"
    done
    printf -v "$var" '%s' "$answer"
}

# Prints what's wrong with VALUE for setting VAR and fails, or passes quietly.
# What a setting takes follows from its name and its current value.
check() {
    local var=$1 value=$2 current=$3 unsafe='[[:space:]"$`\\]'
    if [[ $var == *_PASS ]]; then
        if [ -n "$value" ] && [ ${#value} -lt 8 ]; then
            echo "At least 8 characters, or empty for a random one."
            return 1
        fi
        return 0
    fi
    if [ -z "$value" ]; then
        echo "Can't be empty."
    elif [[ $value =~ $unsafe ]]; then
        echo "No spaces, quotes, \$, \` or \\ please."
    elif [[ $current =~ ^(true|false)$ && ! $value =~ ^(true|false)$ ]]; then
        echo "true or false."
    elif [[ $current =~ ^[0-9]+$ && ! $value =~ ^[0-9]+$ ]]; then
        echo "A number."
    elif [[ $var == *_EMAIL && ! $value =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        echo "An email address."
    else
        return 0
    fi
    return 1
}

# Lists the answers. Then ENTER installs, n asks again, c cancels.
confirm() {
    local var key
    echo
    echo "Your settings:"
    for var in "${SETTINGS[@]}"; do
        if [[ $var != *_PASS ]]; then
            printf '  %-22s %s\n' "$var" "${!var}"
        elif [ -n "${!var}" ]; then
            printf '  %-22s %s\n' "$var" "(set)"
        else
            printf '  %-22s %s\n' "$var" "(random)"
        fi
    done
    echo
    while true; do
        read -rsn1 -p "ENTER = install, n = change them, c = cancel " key
        echo
        case $key in
            '')  return 0 ;;
            n|N) return 1 ;;
            c|C) cancel ;;
        esac
    done
}

# Writes the answers into 00_config.cfg, keeping each line's quoting.
# The password is never written.
save_settings() {
    local var
    for var in "${SETTINGS[@]}"; do
        [[ $var == *_PASS ]] && continue
        VAR=$var VALUE=${!var} awk '
            index($0, ENVIRON["VAR"] "=") == 1 {
                q = substr($0, length(ENVIRON["VAR"]) + 2, 1) == "\"" ? "\"" : ""
                $0 = ENVIRON["VAR"] "=" q ENVIRON["VALUE"] q
            }
            { print }' "$CONFIG" > "$CONFIG.new"
        cat "$CONFIG.new" > "$CONFIG"    # keeps the file's permissions
        rm "$CONFIG.new"
    done
    echo "Saved to $CONFIG"
}

cancel() {
    echo "Cancelled. Nothing was changed."
    echo
    echo "To go step by step yourself: edit $CONFIG, then run"
    echo "  sudo bash $SETUP_DIR/02_install_dependencies.sh"
    echo "and the parts after it, one at a time — or all of them with"
    echo "  sudo bash $SETUP_DIR/01_run_all_scripts.sh"
    exit 0
}

if [ -t 0 ]; then
    echo
    echo "  1) Press 1 or ENTER to configure all settings (step by step)"
    echo "  2) Press 2 for a silent installation using the values in 00_config.cfg"
    echo "  c) Press c to cancel"
    while true; do
        read -rsn1 -p "> " choice
        echo
        case $choice in
            ''|1) until configure; confirm; do :; done
                  save_settings
                  break ;;
            2)    break ;;
            c|C)  cancel ;;
        esac
    done
else
    echo "No terminal, so installing silently with $CONFIG"
fi

# ---- Installing -------------------------------------------------------------

export POCKETBASE_PASS               # a typed one isn't in the file

trap '' HUP                          # keep going if the SSH connection drops
exec 3>&1                            # the screen, for the summary
exec > >(tee -a "$LOG") 2>&1
log_pid=$!

SECRETS_FILE=$(mktemp -p /run)       # in RAM; deleted on exit
trap 'rm -f "$SECRETS_FILE"' EXIT
export SECRETS_FILE

echo
echo "===== $(date) — installation started ====="

failed=
for part in "$SETUP_DIR"/[0-9][0-9]_*.sh; do
    name=$(basename "$part")
    [[ $name == 01_* ]] && continue    # that's this script
    echo
    echo "##### $name #####"
    # No input (nothing may wait for an answer now), and no screen either:
    # a service started from here mustn't keep it open.
    if ! bash "$part" </dev/null 3>&-; then
        failed=$name
        break
    fi
done

echo
if [ -z "$failed" ]; then
    echo "===== $(date) — installation completed ====="
else
    echo "===== $(date) — installation FAILED in $failed (see above) ====="
    echo "Fix the cause, then run this again: sudo bash $SETUP_DIR/01_run_all_scripts.sh"
fi

exec >&3 2>&3 3>&-                   # stop logging
wait "$log_pid" || true

# ---- Summary (screen only) --------------------------------------------------

if [ -z "$failed" ]; then
    case $CUSTOM_DOMAIN in
        :*)    url="http://$(curl -fs --max-time 5 https://checkip.amazonaws.com || echo YOUR_IP)" ;;
        *://*) url=$CUSTOM_DOMAIN ;;
        *)     url="https://$CUSTOM_DOMAIN" ;;
    esac
    echo
    echo "Pocketbase    $url/   (admin UI: $url/_/)"
    echo "Filebrowser   $url/filebrowser/"
    echo "Node app      $url/nodeapp/   (see 10_config_nodeapp.sh)"
fi
if [ -s "$SECRETS_FILE" ]; then
    echo
    cat "$SECRETS_FILE"
    echo "(Shown only now. It isn't saved anywhere.)"
fi
if [ -z "$failed" ]; then
    echo
    echo "Filebrowser login: admin, with the one-time password from"
    echo "  sudo grep 'admin password' /myapps/filebrowser/filebrowser.out.log"
fi
if [ -f /var/run/reboot-required ]; then
    echo
    echo "Some updates need a reboot to finish: sudo reboot"
fi

[ -z "$failed" ]
