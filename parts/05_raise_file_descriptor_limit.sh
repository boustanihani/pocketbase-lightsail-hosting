#!/bin/bash
# Raises the open-file limit for everything Supervisor runs.
#
# Linux counts network connections as open files, and the default limit is
# 1024. Plenty for REST, where a request holds one for milliseconds — but
# Pocketbase's realtime API uses Server-Sent Events, and each subscription
# holds one for as long as the browser tab stays open. Run out and you get
# "too many open files".
#
# The catch: ulimit -n, /etc/security/limits.conf and PAM have no effect here,
# because Supervisor's programs inherit the limit of supervisord itself. So
# this sets it on supervisord's systemd service. It runs before 07–10 start
# the services, so they all start with it; a re-run with no change restarts
# nothing.
#
# Verify on the running process — the config file can lie:
#   sudo cat /proc/$(pgrep -f 'pocketbase serve')/limits | grep -i 'open files'   # 65536
#   sudo ls /proc/$(pgrep -f 'pocketbase serve')/fd | wc -l                       # in use
# Still 1024? `supervisorctl restart pocketbase` isn't enough, the limit sits
# on supervisord: sudo systemctl restart supervisor. Or raise it on the live
# process without restarting anything:
#   sudo prlimit --pid $(pgrep -f 'pocketbase serve') --nofile=65536:65536
#
# Why not minfds in /etc/supervisor/supervisord.conf? That file belongs to
# the package: editing it means updates either prompt you or leave a
# .dpkg-dist file you never read. The two don't conflict anyway — Supervisor
# only ever raises the limit toward minfds, so its default of 1024 does
# nothing once the limit is 65536.
# 65536 covers 10,000+ connections. Not "infinity": that means the kernel
# maximum (1,048,576), and some programs allocate arrays that size at start.

source "$(dirname "$0")/common.sh"

write_file /etc/systemd/system/supervisor.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=65536
EOF

if $CHANGED; then
    systemctl daemon-reload
    systemctl restart supervisor   # running programs restart with it
    wait_for_supervisor
fi
