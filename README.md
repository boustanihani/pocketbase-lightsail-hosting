# Hosting Pocketbase, Filebrowser, and a Node.js app on AWS Lightsail

Three apps on one Lightsail instance, behind Caddy, managed by Supervisor:

| App | URL | Port |
|---|---|---|
| Pocketbase | `http://your-ip/` | 8090 |
| Filebrowser | `http://your-ip/filebrowser/` | 8091 |
| Node.js app | `http://your-ip/nodeapp/` | 8092 |

## Overview

- **Pocketbase** sits at the root path. Admin UI at `/_/`.
- **Filebrowser** manages the whole `/myapps` tree. It needs `--baseurl /filebrowser` for assets to load, and Caddy rate-limits its login to 5 attempts/minute/IP.
- **Caddy** is a prebuilt binary including the `mholt/caddy-ratelimit` module. HTTP by default; add your domain to the Caddyfile for automatic HTTPS.
- **Node.js** comes from NodeSource (default 22.x), not Ubuntu's outdated package.
- **Supervisor** runs all four services as `user=root` under `/myapps`.
- **Install and update share one script**, `/myapps/install-update-binaries.sh` — see [Installing & Updating Binaries](#installing--updating-binaries).
- **Hardening:** SSHGuard (bans via nftables, invisible to the Lightsail console), key-only SSH, sysctl network settings, `zram-config` + `earlyoom` for memory pressure, and a raised file-descriptor limit for Pocketbase's realtime connections.
- **Limits:** 100MB uploads, 6-minute Pocketbase timeout. Both set in the Caddyfile.

Autostart is controlled by `AUTOSTART_*` at the top of `script.sh` and baked into the Supervisor configs. `AUTOSTART_NODEAPP` defaults to `false` since no app code exists yet. On later update runs the script reads `autostart` straight from `/etc/supervisor/conf.d/`, so anything you flip there is respected.

---

## Quick Start

When creating your Lightsail instance:

1. **Create instance** → **Linux/Unix** → **OS Only** → **Ubuntu 24.04 LTS**
2. Instance plan: **$5/month** or higher
3. Under **Add launch script**, paste the contents of [`script.sh`](./script.sh)
4. Create, then wait 3–5 minutes
5. Check it worked: `sudo tail /var/log/cloud-init-output.log`

`script.sh` writes the configuration (Caddyfile, Supervisor configs, hardening) and then calls `/myapps/install-update-binaries.sh` to download Caddy, Pocketbase, Filebrowser, and Node.js.

> **Script size limit.** Lightsail caps user-data at 16,384 bytes *after* base64 encoding, so the raw ceiling is **12,288 bytes**. Check before pasting:
>
> ```bash
> wc -c script.sh              # < 12288
> base64 -w0 script.sh | wc -c # < 16384
> ```

**First access:**

| What | Where | Credentials |
|---|---|---|
| Pocketbase page | `http://YOUR_IP/` | — |
| Pocketbase admin | `http://YOUR_IP/_/` | `POCKETBASE_EMAIL` / `POCKETBASE_PASS` from the script |
| Filebrowser | `http://YOUR_IP/filebrowser` | user `admin`; password printed in `/myapps/filebrowser/filebrowser.err.log` |
| Nodeapp | `http://YOUR_IP/nodeapp/` | not running yet — see [Activating the Node.js App](#activating-the-nodejs-app) |

For HTTPS, set `CUSTOM_DOMAIN` before launch or see [Enabling HTTPS](#enabling-https).

---

## Manual Installation

What `script.sh` does, step by step, if you'd rather build it yourself.

### Step 1: Create the Instance

Create an Ubuntu 24.04 LTS instance in the [Lightsail console](https://lightsail.aws.amazon.com/), then **Connect using SSH**.

### Step 2: Install Dependencies

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl jq supervisor unzip sshguard tilde btop unattended-upgrades earlyoom zram-config
sudo mkdir -p /myapps/caddy /myapps/pocketbase /myapps/filebrowser /myapps/nodeapp
```

If scripting this, `export DEBIAN_FRONTEND=noninteractive` and `export NEEDRESTART_MODE=a` first — otherwise kernel-upgrade dialogs and needrestart prompts wedge debconf and silently break later steps, notably NodeSource's installer.

### Step 3: Configure Caddy

```bash
sudo nano /myapps/caddy/Caddyfile
```

```caddy
{
    order rate_limit before basic_auth
}

:80 {
    request_body {
        max_size 100MB
    }

    handle /filebrowser {
        redir {path}/ permanent
    }
    handle /filebrowser/* {
        rate_limit {
            zone filebrowser_login {
                match {
                    method POST
                    path /filebrowser/api/login
                }
                key    {remote_host}
                events 5
                window 1m
            }
        }
        reverse_proxy localhost:8091
    }

    handle_path /nodeapp {
        reverse_proxy localhost:8092
    }
    handle_path /nodeapp/* {
        reverse_proxy localhost:8092
    }

    handle {
        reverse_proxy localhost:8090 {
            transport http {
                read_timeout 360s
            }
        }
    }
}
```

### Step 4: Configure Supervisor

One file per service in `/etc/supervisor/conf.d/`. All run as `user=root` — Caddy needs it to bind ports 80/443.

`caddy.conf`:

```ini
[program:caddy]
directory=/myapps/caddy
command=/myapps/caddy/caddy run --config /myapps/caddy/Caddyfile
environment=XDG_DATA_HOME="/myapps/caddy/data",XDG_CONFIG_HOME="/myapps/caddy/config"
autostart=true
autorestart=true
stderr_logfile=/myapps/caddy/caddy.err.log
stdout_logfile=/myapps/caddy/caddy.out.log
user=root
```

`pocketbase.conf`:

```ini
[program:pocketbase]
directory=/myapps/pocketbase
command=/myapps/pocketbase/pocketbase serve --http=127.0.0.1:8090
autostart=true
autorestart=true
stderr_logfile=/myapps/pocketbase/pocketbase.err.log
stdout_logfile=/myapps/pocketbase/pocketbase.out.log
user=root
```

`filebrowser.conf`:

```ini
[program:filebrowser]
directory=/myapps/filebrowser
command=/myapps/filebrowser/filebrowser -r /myapps -a 127.0.0.1 -p 8091 --baseurl /filebrowser
autostart=true
autorestart=true
stderr_logfile=/myapps/filebrowser/filebrowser.err.log
stdout_logfile=/myapps/filebrowser/filebrowser.out.log
user=root
```

`nodeapp.conf` — `autostart=false` is intentional, there's no app code yet:

```ini
[program:nodeapp]
directory=/myapps/nodeapp
command=/usr/bin/node /myapps/nodeapp/index.js
environment=NODE_ENV="production",PORT="8092"
autostart=false
autorestart=true
startsecs=5
startretries=3
stopsignal=TERM
stopwaitsecs=15
stderr_logfile=/myapps/nodeapp/nodeapp.err.log
stdout_logfile=/myapps/nodeapp/nodeapp.out.log
user=root
```

### Step 5: Install the Binaries

Copy the heredoc between the `BINEOF` markers in [`script.sh`](./script.sh) to `/myapps/install-update-binaries.sh`, then:

```bash
sudo chmod +x /myapps/install-update-binaries.sh
sudo bash /myapps/install-update-binaries.sh --first-run
sudo supervisorctl status
```

You should see `caddy`, `pocketbase`, and `filebrowser` as `RUNNING`, and `nodeapp` as `STOPPED`.

### Step 6: Create the Pocketbase Superuser (Optional)

Do it now via CLI, or later in the Admin UI:

```bash
sudo /myapps/pocketbase/pocketbase superuser create your-email@example.com your-password
```

Optional sample page:

```bash
sudo mkdir -p /myapps/pocketbase/pb_public
echo '<h1>Seite in Arbeit...</h1>' | sudo tee /myapps/pocketbase/pb_public/index.html
```

### Step 7: Harden SSH

A drop-in, so `/etc/ssh/sshd_config` stays untouched and survives package upgrades:

```bash
sudo tee /etc/ssh/sshd_config.d/00-hardening.conf > /dev/null <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF
sudo systemctl restart ssh
sudo sshd -T | grep -iE 'passwordauthentication|kbdinteractive'   # verify
```

**After this, only key-based SSH works.** Have your keys ready.

> **Why `00-` and not `99-`?** `sshd` is first-value-wins and its `Include` sits at the top of the config, so the *lowest*-numbered drop-in wins. `00-` beats the image's own `60-cloudimg-settings.conf`. This is the opposite of `/etc/sysctl.d/`, where the last file read wins and `99-` is the strong slot.

### Step 8: Harden the Network

```bash
sudo tee /etc/sysctl.d/99-hardening.conf > /dev/null <<EOF
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.log_martians=1
EOF
sudo sysctl --system
```

- **`rp_filter`** — validates packets come from plausible sources (anti-spoofing).
- **`accept_redirects=0`** — blocks MITM via malicious ICMP route redirects, on IPv4 *and* IPv6 since the instance is dual-stack.
- **`send_redirects=0`** — this is an app server, not a router.
- **`log_martians`** — logs impossible source addresses.

> Use `sysctl --system`, not `sysctl -p`. Plain `-p` only reloads `/etc/sysctl.conf` and ignores `/etc/sysctl.d/`. `rp_filter`, `send_redirects` and `log_martians` are IPv4-only knobs with no IPv6 counterpart.

### Step 9: Raise the File Descriptor Limit

Unix counts network connections as file descriptors, and the default soft limit is **1024**. Fine for REST — a request holds a descriptor for milliseconds — but Pocketbase's realtime API uses Server-Sent Events, and **an SSE subscription holds one descriptor for as long as the browser tab stays open**. Three tabs is three descriptors. Run out and you get `too many open files`.

The trap is Supervisor: `ulimit -n`, `/etc/security/limits.conf`, and PAM all have **no effect**, because Supervisor's children inherit their limit from the `supervisord` parent. A systemd drop-in is the fix:

```bash
sudo mkdir -p /etc/systemd/system/supervisor.service.d
sudo tee /etc/systemd/system/supervisor.service.d/limits.conf > /dev/null <<EOF
[Service]
LimitNOFILE=65536
EOF
sudo systemctl daemon-reload
sudo systemctl restart supervisor
```

Verify against the running process — the config file can lie:

```bash
sudo cat /proc/$(pgrep -f 'pocketbase serve')/limits | grep -i 'open files'   # expect 65536
sudo ls /proc/$(pgrep -f 'pocketbase serve')/fd | wc -l                       # current usage
```

> **Why not `minfds` in `/etc/supervisor/supervisord.conf`?** It works, but that file is a registered dpkg *conffile* — editing it means future package updates either prompt you or leave a `.dpkg-dist` you never read. Use `minfds` only on systems without systemd. The two don't conflict: Supervisor only ever *raises* toward `minfds`, so its default of 1024 does nothing once the inherited limit is already 65536.
>
> 65536 covers 10,000+ concurrent connections with room to spare. Don't use `infinity` — it resolves to the kernel max (1,048,576) and some software allocates arrays that size at startup.

### Step 10: Configure OOM Protection

The Lightsail image ships **without disk swap**. `zram-config` adds compressed in-RAM swap as a first buffer; `earlyoom` is the backstop. Without it the kernel's own OOM killer reacts too late — the box freezes for minutes and may kill `sshd`, locking you out.

The package is already running with defaults after Step 2, but its defaults protect nothing in particular:

```bash
sudo tee /etc/default/earlyoom > /dev/null <<EOF
EARLYOOM_ARGS="-r 3600 -m 10 -s 10 --avoid '(^|/)(sshd|supervisord|systemd|sudo|bash)$' --prefer '^node$'"
EOF
sudo systemctl restart earlyoom
```

- **`-m 10 -s 10`** — fire when available RAM *and* zram swap both drop below 10%
- **`--avoid`** — never kill `sshd`, `supervisord`, `systemd`, `sudo`, `bash`, so you keep access and Supervisor keeps managing services
- **`--prefer`** — bias toward the Node app; it's the likeliest leak and `autorestart=true` brings it back
- **`-r 3600`** — hourly memory report to the journal

Check with `systemctl status earlyoom` (the running args are shown) and `journalctl -u earlyoom | grep -i kill`.

`/etc/default/earlyoom` is yours to edit — dpkg won't overwrite it.

### Step 11: Open Firewall Ports

Lightsail gives each instance **two independent firewalls** — one for IPv4, one for IPv6 — and rules must be added to each separately. IPv6 is on by default for instances created since January 2021, so your instance is dual-stack and Caddy is already listening on both; only the console firewall stands in the way.

In the Lightsail console → your instance → **Networking**:

| Firewall | Open |
|---|---|
| IPv4 | TCP **22**, **80**, **443** |
| IPv6 | TCP **80**, **443** (and **22** if you want SSH over IPv6) |

The IPv6 table only appears once IPv6 is enabled for the instance, in the **IPv6 Networking** section on the same page. Leaving port 22 closed on IPv6 is a reasonable choice — it halves the surface exposed to scanners — but **80 and 443 should be open on both**, or IPv6-only clients simply can't reach you.

---

## Activating the Node.js App

`nodeapp` ships stopped because there's no code yet.

**1. Upload.** Put your files in `/myapps/nodeapp/` via Filebrowser or `scp`. You need at least `index.js`; add `package.json` if you have dependencies. Supervisor sets `PORT=8092`, so listen on `process.env.PORT` — Caddy proxies `/nodeapp/*` there.

**2. Install dependencies**, if any:

```bash
cd /myapps/nodeapp && sudo npm install --omit=dev
```

**3. Enable and start:**

```bash
sudo sed -i 's/^autostart=false/autostart=true/' /etc/supervisor/conf.d/nodeapp.conf
sudo supervisorctl update
sudo supervisorctl start nodeapp
```

**4. Verify:**

```bash
sudo supervisorctl status nodeapp   # RUNNING
curl http://127.0.0.1:8092/         # direct
curl http://127.0.0.1/nodeapp/      # through Caddy
```

To deploy new code later: upload, then `sudo supervisorctl restart nodeapp`. Re-run `npm install --omit=dev` first if dependencies changed.

---

## Enabling HTTPS

Once your domain points at the instance, replace `:80` in the Caddyfile with your domain:

```bash
sudo sed -i 's/^:80/sub.domain.ext/' /myapps/caddy/Caddyfile && sudo supervisorctl restart caddy
```

**The `^` anchor is not optional.** Without it, sed also rewrites the `:80` inside `localhost:8090/8091/8092` and corrupts the file. Only the site address starts at column 0.

Caddy then obtains a Let's Encrypt certificate, redirects HTTP to HTTPS, and auto-renews.

---

## Installing & Updating Binaries

`/myapps/install-update-binaries.sh` has two modes.

**Update** (no flag) — the normal case. Stops the services, backs up the current binaries to `*.bak`, downloads the latest Caddy, Pocketbase, Filebrowser, and Node.js (within `NODE_MAJOR`), validates the downloads, and restarts each service whose Supervisor config says `autostart=true`:

```bash
sudo bash /myapps/install-update-binaries.sh
```

If a download fails it restores the `.bak` binaries and restarts, so a broken network leaves you where you started.

**Install / repair** (`--first-run`) — skips the stop, backup, and restart logic, recreates any missing `/myapps/*` directories, and downloads straight into them. `script.sh` uses this for the initial install, and it's also how you rebuild a service you deliberately deleted:

```bash
sudo rm -rf /myapps/pocketbase          # e.g. wipe the database and start over
sudo bash /myapps/install-update-binaries.sh --first-run
```

Note that plain update mode will *not* repair this — it aborts at the backup step when the binary is missing, which is deliberate: an update should fail loudly rather than silently turn into a fresh install. Also note the script itself lives in `/myapps`, so `rm -rf /myapps` removes your ability to run it.

Services with `autostart=false` have their binaries refreshed but stay stopped. That applies to all four, so setting Pocketbase to `autostart=false` updates it without starting it.

---

## Supervisor Quick Reference

```bash
sudo supervisorctl status                       # all services
sudo supervisorctl restart pocketbase           # or caddy | filebrowser | nodeapp
sudo supervisorctl stop all
sudo supervisorctl update                       # after editing a .conf
```

`update` re-reads the configs itself, so `reread` beforehand is redundant — both call the same reload internally. Run `reread` on its own only as a dry run: it reports what changed without applying anything.

Logs live next to each binary as `<name>.err.log` and `<name>.out.log`:

```bash
sudo tail -f /myapps/pocketbase/pocketbase.err.log
```

---

## Directory Structure

```
/myapps/
├── install-update-binaries.sh
├── caddy/
│   ├── caddy                  (prebuilt, with rate-limit module)
│   ├── Caddyfile
│   ├── data/caddy/            (certificates, OCSP staples)
│   └── config/caddy/          (autosaved config)
├── pocketbase/
│   ├── pocketbase
│   ├── pb_data/               (database)
│   └── pb_public/             (static files served at /)
├── filebrowser/
│   ├── filebrowser
│   └── filebrowser.db
└── nodeapp/
    ├── index.js               (your code)
    ├── package.json
    └── node_modules/
```

Each directory also holds that service's `.err.log` and `.out.log`. Filebrowser shows and manages this entire tree.

---

## Troubleshooting

**Something won't start** — `sudo supervisorctl status`, then read that service's `.err.log`.

**Can't reach it in a browser** — check the Lightsail firewall (80/443 open), then `sudo supervisorctl status caddy` and its error log.

**Pocketbase admin won't load** — the URL is `http://YOUR_IP/_/`, with the underscore and trailing slash.

**Nodeapp won't start**
- `autostart=true` in `/etc/supervisor/conf.d/nodeapp.conf`, followed by `sudo supervisorctl update`
- `/myapps/nodeapp/index.js` exists
- the app listens on `process.env.PORT` (8092), not `0.0.0.0` or another port
- `node_modules/` present — `cd /myapps/nodeapp && sudo npm install --omit=dev`

**Nodeapp returns 502** — Caddy is proxying to a process that isn't running. Check `supervisorctl status nodeapp` and its error log.

**`too many open files`** — the descriptor limit, see [Step 9](#step-9-raise-the-file-descriptor-limit).

```bash
sudo cat /proc/$(pgrep -f 'pocketbase serve')/limits | grep -i 'open files'
```

If it says `1024`, the drop-in is missing or `systemctl daemon-reload` was never run. `supervisorctl restart pocketbase` is **not** enough — the limit lives on the `supervisord` parent, so you need `sudo systemctl restart supervisor`. To fix a live process without restarting anything:

```bash
sudo prlimit --pid $(pgrep -f 'pocketbase serve') --nofile=65536:65536
```

**Caddy can't get a certificate**
- Ports 80 and 443 open in the Lightsail firewall — **on both the IPv4 and IPv6 tables**. If your domain has an AAAA record, Let's Encrypt prefers IPv6 for validation, so a closed IPv6 firewall fails issuance even though the site loads perfectly over IPv4. The Caddy log makes this look like a DNS problem.
- DNS resolves to the instance *before* Caddy tries: `nslookup sub.domain.ext`
- If you set the domain too early, wait for propagation then `sudo supervisorctl restart caddy`
- Validate the config: `/myapps/caddy/caddy validate --config /myapps/caddy/Caddyfile`

**Reading the launch log**

```bash
sudo tail -f /var/log/cloud-init-output.log
sudo cat /var/log/cloud-init-output.log | curl -s -F "content=<-" https://dpaste.com/api/v2/
```
