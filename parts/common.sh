# Shared by all parts (sourced, not run): strict mode, root check, the
# settings from 00_config.cfg, and small helpers.

set -euo pipefail

SETUP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$SETUP_DIR/00_config.cfg"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash $0" >&2
    exit 1
fi

# 01's step-by-step setup hands over the password in the environment, since it
# never writes it to the file. Handed over, it counts even when empty (= random).
# Everything else comes from the file.
[[ -v POCKETBASE_PASS ]] && pass_from_env=$POCKETBASE_PASS
source "$CONFIG"
[[ -v pass_from_env ]] && POCKETBASE_PASS=$pass_from_env
unset pass_from_env

# apt without questions: debconf and needrestart take their defaults, changed
# config files are kept, and it waits for the lock that unattended-upgrades
# often holds right after boot instead of failing.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt_get() {
    apt-get -y -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# write_file PATH <<EOF ... EOF
# Writes stdin to PATH, but only if that changes it; the previous version is
# kept as PATH.bak. Sets CHANGED=true when it wrote, so a part knows to restart.
CHANGED=false
write_file() {
    local path=$1 content
    content=$(cat)
    if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
        echo "Unchanged: $path"
        return
    fi
    mkdir -p "$(dirname "$path")"
    if [ -f "$path" ]; then
        cp "$path" "$path.bak"
        echo "Backed up: $path.bak"
    fi
    printf '%s\n' "$content" > "$path"
    echo "Wrote: $path"
    CHANGED=true
}

# Shows a generated password once. Under 01 it goes into the summary at the
# end, on screen only and never into install.log; a part run on its own
# prints it right away.
show_secret() {
    if [ -n "${SECRETS_FILE:-}" ]; then
        echo "$*" >> "$SECRETS_FILE"
    else
        echo "$*"
    fi
}

# ---- Supervisor -------------------------------------------------------------

# Waits until supervisord answers again after a restart.
wait_for_supervisor() {
    for _ in {1..30}; do
        supervisorctl pid >/dev/null 2>&1 && return
        sleep 1
    done
    echo "ERROR: Supervisor didn't come back up." >&2
    return 1
}

# True if PROG's Supervisor config says autostart=true.
autostart_enabled() {
    grep -qE '^autostart\s*=\s*true\s*$' "/etc/supervisor/conf.d/$1.conf" 2>/dev/null
}

# True if PROG is running, or on its way there.
is_up() {
    [[ $(supervisorctl status "$1" 2>&1) =~ RUNNING|STARTING|BACKOFF ]]
}

# Starts PROG if autostart=true and it isn't up, e.g. FATAL after an early start.
start_if_autostart() {
    if ! autostart_enabled "$1"; then
        echo "($1 not started: autostart is not true)"
    elif ! is_up "$1"; then
        supervisorctl start "$1"
    fi
}

# apply_program PROG, after a part wrote PROG's files.
# `update` adds the program (starting it if autostart=true) or restarts it if
# its .conf changed. It doesn't notice the other files (CHANGED), like the
# Caddyfile, so a running program is restarted for those. Then waits for it
# to come up and shows its status.
apply_program() {
    local prog=$1 was_up=false status
    is_up "$prog" && was_up=true
    supervisorctl update "$prog"
    if $CHANGED && $was_up && is_up "$prog"; then
        supervisorctl restart "$prog"
    fi
    start_if_autostart "$prog"
    autostart_enabled "$prog" || return 0

    for _ in {1..30}; do
        status=$(supervisorctl status "$prog" 2>&1 || true)
        [[ $status =~ STARTING|BACKOFF ]] || break
        sleep 1
    done
    echo "$status"
    if [[ ! $status =~ RUNNING ]]; then
        echo "ERROR: $prog didn't start. End of /myapps/$prog/$prog.err.log:" >&2
        tail -n 20 "/myapps/$prog/$prog.err.log" >&2 || true
        return 1
    fi
}
