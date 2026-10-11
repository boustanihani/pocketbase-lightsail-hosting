#!/bin/bash
# The Node app: your own code at /nodeapp/, run with Node.js (from 06) under
# Supervisor. It starts switched off (AUTOSTART_NODEAPP=false) because there's
# no code yet. Caddy strips the /nodeapp prefix, so your app sees plain paths.
#
# To go live:
#   1. Upload your code to /myapps/nodeapp/, via Filebrowser or scp: at least
#      NODEAPP_RUN (index.js), plus package.json if it has dependencies. Listen
#      on process.env.PORT (NODEAPP_PORT, 8092) — that's where Caddy sends
#      /nodeapp/.
#   2. Install dependencies, if any:
#        cd /myapps/nodeapp && sudo npm install --omit=dev
#   3. Set AUTOSTART_NODEAPP=true in 00_config.cfg and run this part again:
#        sudo bash /myapps/setup/10_config_nodeapp.sh
#   4. Check:
#        sudo supervisorctl status nodeapp   # RUNNING
#        curl http://127.0.0.1:8092/         # directly
#        curl http://127.0.0.1/nodeapp/      # through Caddy
#
# New code later: upload it, then  sudo supervisorctl restart nodeapp
# (after  npm install --omit=dev  if the dependencies changed).
#
# Won't start? Check that AUTOSTART_NODEAPP=true and this part ran again,
# that NODEAPP_RUN exists, that the app listens on process.env.PORT, and that
# node_modules/ is there. Errors go to /myapps/nodeapp/nodeapp.err.log.
# A 502 at /nodeapp/ means the app isn't running: sudo supervisorctl status nodeapp
#
# When memory runs out, earlyoom (04) kills `node` first; autorestart=true
# brings it back.

source "$(dirname "$0")/common.sh"

write_file /etc/supervisor/conf.d/nodeapp.conf <<EOF
; Written by $SETUP_DIR/10_config_nodeapp.sh from 00_config.cfg.
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

apply_program nodeapp
