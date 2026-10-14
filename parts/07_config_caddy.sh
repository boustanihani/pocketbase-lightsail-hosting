#!/bin/bash
# Caddy: the web server in front of everything, on ports 80 and 443.
#
#   /               → Pocketbase   localhost:8090 (admin UI at /_/)
#   /filebrowser/   → Filebrowser  localhost:8091
#   /nodeapp/       → Node app     localhost:NODEAPP_PORT, without the prefix
#
# /filebrowser and /nodeapp redirect to the same path with a slash, so the
# relative links in their pages work. 308 is a permanent redirect that keeps
# a POST a POST.
#
# Limits: request bodies up to 100 MB (uploads), and a 6-minute read timeout
# towards Pocketbase, so long requests aren't cut short.
#
# The binary (from 06) includes the mholt/caddy-ratelimit module. Nothing uses
# it yet — Filebrowser limits its own logins — but the `order rate_limit` line
# lets you drop a rate_limit block into any route later.
#
# HTTPS: set CUSTOM_DOMAIN in 00_config.cfg and run this part again. Caddy
# then gets a Let's Encrypt certificate, redirects HTTP to HTTPS and renews
# the certificate on its own. Before that:
#   - The domain's DNS must point at this server:  nslookup sub.domain.ext
#   - TCP 80 and 443 must be open in Lightsail's firewall on both the IPv4 and
#     the IPv6 tab. With an AAAA record, Let's Encrypt prefers IPv6, so a
#     closed IPv6 firewall fails the certificate although the site loads fine
#     over IPv4 — and Caddy's log makes it look like a DNS problem.
#   - Set the domain before DNS was ready? Once it is:
#       sudo supervisorctl restart caddy
#
# Log:   /myapps/caddy/caddy.err.log (Caddy logs everything there)
# Check: sudo /myapps/caddy/caddy validate --config /myapps/caddy/Caddyfile
# Certificates are stored in /myapps/caddy/data/caddy/.

source "$(dirname "$0")/common.sh"

# Tab-indented, the way `caddy fmt` writes it; otherwise Caddy warns at start.
caddyfile() {
    cat <<EOF
# Written by $SETUP_DIR/07_config_caddy.sh from 00_config.cfg.
# Change the settings there and run it again; edits here get overwritten.
{
	order rate_limit before basic_auth
}

${CUSTOM_DOMAIN} {
	request_body {
		max_size 100MB
	}

	handle /filebrowser {
		redir {path}/ 308
	}
	handle /filebrowser/* {
		reverse_proxy localhost:8091
	}

	handle /nodeapp {
		redir {path}/ 308
	}
	handle_path /nodeapp/* {
		reverse_proxy localhost:${NODEAPP_PORT}
	}

	handle {
		reverse_proxy localhost:8090 {
			transport http {
				read_timeout 360s
			}
		}
	}
}
EOF
}

# Checked before it replaces the current one, so a mistyped CUSTOM_DOMAIN,
# say, can't break a working Caddy.
if ! out=$(caddyfile | XDG_DATA_HOME=/myapps/caddy/data XDG_CONFIG_HOME=/myapps/caddy/config \
        /myapps/caddy/caddy validate --adapter caddyfile --config /dev/stdin 2>&1); then
    echo "$out" >&2
    echo "ERROR: Caddy rejects this Caddyfile (see above), so it wasn't saved." >&2
    echo "Fix the setting in 00_config.cfg and run this part again." >&2
    exit 1
fi
write_file /myapps/caddy/Caddyfile < <(caddyfile)

# Root, so it can bind ports 80 and 443.
write_file /etc/supervisor/conf.d/caddy.conf <<EOF
; Written by $SETUP_DIR/07_config_caddy.sh from 00_config.cfg.
[program:caddy]
directory=/myapps/caddy
command=/myapps/caddy/caddy run --config /myapps/caddy/Caddyfile
environment=XDG_DATA_HOME="/myapps/caddy/data",XDG_CONFIG_HOME="/myapps/caddy/config"
autostart=${AUTOSTART_CADDY}
autorestart=true
stderr_logfile=/myapps/caddy/caddy.err.log
stdout_logfile=/myapps/caddy/caddy.out.log
user=root
EOF

apply_program caddy
