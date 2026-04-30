# Hosting Pocketbase, Filebrowser, and a Node.js app on AWS Lightsail

## Overview

This guide will help you host three applications on a single AWS Lightsail instance:
- **Pocketbase** at: `http://your-ip/` or `https://your-domain/`
- **Filebrowser** at: `http://your-ip/filebrowser/` or `https://your-domain/filebrowser/`
- **Node.js app** at: `http://your-ip/nodeapp/` or `https://your-domain/nodeapp/`

**Important Notes:**

- Pocketbase is served at the root path for simplest access
- Filebrowser is configured to manage the entire `/myapps` directory (Caddy, Pocketbase, Filebrowser, and Nodeapp subdirectories)
- Filebrowser requires the `--baseurl` flag for proper asset loading under `/filebrowser`
- Filebrowser login is rate-limited to 5 attempts per minute per IP via Caddy
- Caddy is installed as a prebuilt binary with the `mholt/caddy-ratelimit` module included
- Node.js (configurable major version, default 22.x) is installed from NodeSource so Ubuntu's outdated package isn't used
- Each service's autostart behavior is controlled by `AUTOSTART_CADDY`, `AUTOSTART_POCKETBASE`, `AUTOSTART_FILEBROWSER`, and `AUTOSTART_NODEAPP` at the top of `script.sh` — Caddy, Pocketbase, and Filebrowser default to `true`; `AUTOSTART_NODEAPP` defaults to `false` because no app code exists yet (see [Activating the Node.js App](#activating-the-nodejs-app))
- On first install, autostart values come from the `AUTOSTART_*` variables at the top of `script.sh` (which are baked into the Supervisor configs). On later update runs, `install-update-binaries.sh` reads the `autostart` value directly from each Supervisor config in `/etc/supervisor/conf.d/`, so anything you flip there is respected without touching `script.sh`
- All services (Caddy, Pocketbase, Filebrowser, Nodeapp) are managed via Supervisor under `/myapps`
- Binary installation and updates share a single script (`/myapps/install-update-binaries.sh`) — the launch script invokes it for the initial install, and you re-run it later for updates
- The launch script sets up HTTP; HTTPS is configured by simply adding your domain to the Caddyfile
- SSHGuard is installed and active for SSH brute-force protection (no configuration needed). Note: bans are applied locally via nftables; they don't appear in the Lightsail firewall console.
- Enhanced network security settings are applied for DDoS protection and security hardening
- File upload size is limited to 100MB (configurable in Caddyfile)
- Pocketbase has a 6-minute timeout for long-running operations
- `btop` is installed for system resource monitoring

---

## Quick Start (Automated)

When creating your Lightsail instance:

1. Go to AWS Lightsail Console
2. Click **Create instance**
3. Select **Linux/Unix** platform
4. Choose **OS Only** → **Ubuntu 24.04 LTS**
5. Scroll to **Add launch script**
6. Copy and paste the contents of [`script.sh`](./script.sh) (in this repo)
7. Choose your instance plan (minimum: $5/month)
8. Click **Create instance**
9. Wait 3–5 minutes after the instance starts.
10. Quick Check: `sudo tail /var/log/cloud-init-output.log`

Under the hood, `script.sh` writes the system configuration (Caddyfile, Supervisor configs, SSH/sysctl hardening) and then invokes `/myapps/install-update-binaries.sh` to download and install Caddy, Pocketbase, Filebrowser, and Node.js. That same helper script is also what you run later to update everything — see [Updating All Binaries](#updating-all-binaries).

> **Note on script size:** Keep `script.sh` under ~12KB raw. Lightsail limits user-data to 16KB *after* base64 encoding, which adds ~33% overhead. If you extend the script, watch the size.

**Initial Access (HTTP):**
- Pocketbase Public Page: `http://YOUR_IP/` (sample page: "Seite in Arbeit...")
- Pocketbase Admin: `http://YOUR_IP/_/` (login with credentials from `POCKETBASE_EMAIL` and `POCKETBASE_PASS`)
- Filebrowser: `http://YOUR_IP/filebrowser` (check `/myapps/filebrowser/filebrowser.err.log` for the initial credentials)
- Nodeapp: not running yet — see [Activating the Node.js App](#activating-the-nodejs-app)

**After DNS Configuration:**
Edit the script variable `CUSTOM_DOMAIN=":80"` to your domain before launch, or follow the "Enabling HTTPS" section below to secure your site with SSL certificates.

---

## Manual Installation (Step-by-Step)

### Step 1: Create Your Lightsail Instance

1. Go to [AWS Lightsail Console](https://lightsail.aws.amazon.com/)
2. Click **Create instance**
3. Select:
   - Platform: **Linux/Unix**
   - Blueprint: **OS Only** → **Ubuntu 24.04 LTS**
   - Instance plan: **$5/month or higher**
4. Name your instance (e.g., `my-apps-server`)
5. Click **Create instance**
6. Wait for the instance to start

### Step 2: Connect via SSH

1. Click on your instance name
2. Click **Connect using SSH** (browser-based terminal)

### Step 3: Update System and Install Dependencies

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl jq supervisor unzip sshguard tilde btop unattended-upgrades
```

If you're scripting this rather than running it interactively, also `export DEBIAN_FRONTEND=noninteractive` and `export NEEDRESTART_MODE=a` first — without these, kernel-upgrade dialogs and needrestart prompts can wedge debconf and silently break later steps (notably NodeSource's setup script).

### Step 4: Create Directory Structure

```bash
sudo mkdir -p /myapps/caddy /myapps/pocketbase /myapps/filebrowser /myapps/nodeapp
```

### Step 5: Configure Caddy

```bash
sudo nano /myapps/caddy/Caddyfile
```

Paste the following content:

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

    handle /nodeapp {
        redir {path}/ permanent
    }
    handle /nodeapp/* {
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

Save and exit (Ctrl+X, then Y, then Enter)

### Step 6: Configure Supervisor for Caddy

```bash
sudo nano /etc/supervisor/conf.d/caddy.conf
```

Paste this configuration:

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

**Note:** Caddy needs to bind to port 80/443, which requires root. Since Supervisor runs this process as `user=root`, this works as-is.

### Step 7: Configure Supervisor for Pocketbase

```bash
sudo nano /etc/supervisor/conf.d/pocketbase.conf
```

Paste this configuration:

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

### Step 8: Configure Supervisor for Filebrowser

```bash
sudo nano /etc/supervisor/conf.d/filebrowser.conf
```

Paste this configuration:

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

### Step 9: Configure Supervisor for Nodeapp

```bash
sudo nano /etc/supervisor/conf.d/nodeapp.conf
```

Paste this configuration:

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

**Note:** `autostart=false` is intentional — there's no app code yet. You'll flip this to `true` after uploading your app (see [Activating the Node.js App](#activating-the-nodejs-app)).

### Step 10: Install All Binaries

The install/update script content is embedded in [`script.sh`](./script.sh) — copy the heredoc between the `BINEOF` markers, save it to `/myapps/install-update-binaries.sh`, make it executable, then run it with the `--first-run` flag:

```bash
sudo chmod +x /myapps/install-update-binaries.sh
sudo bash /myapps/install-update-binaries.sh --first-run
```

This downloads and installs Caddy (with the rate-limiting module), Pocketbase, Filebrowser, and Node.js, then registers the Supervisor configs (which auto-starts Caddy, Pocketbase, and Filebrowser since their `autostart=true`; Nodeapp stays stopped because its `autostart=false`).

The same script is reused later for updates — without the `--first-run` flag — see [Updating All Binaries](#updating-all-binaries).

Verify everything is running:

```bash
sudo supervisorctl status
```

You should see:
- `caddy RUNNING`
- `pocketbase RUNNING`
- `filebrowser RUNNING`
- `nodeapp STOPPED`

### Step 11: Create the Pocketbase Superuser (Optional)

You can do this now via the CLI, or later through the Admin UI:

```bash
sudo /myapps/pocketbase/pocketbase superuser create your-email@example.com your-password
```

**Optional:** Create a sample public page:
```bash
sudo mkdir -p /myapps/pocketbase/pb_public
sudo bash -c 'cat > /myapps/pocketbase/pb_public/index.html <<EOF
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"></head><body><h1>Seite in Arbeit...</h1></body></html>
EOF'
```

### Step 12: Configure SSH Security

Configure SSH for key-based authentication only by adding a drop-in file (this approach doesn't mutate the upstream `/etc/ssh/sshd_config` and survives package upgrades):

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
EOF
```

Restart SSH to apply changes:
```bash
sudo systemctl restart ssh
```

**Important:** After this step, only key-based SSH authentication will work! Make sure you have your SSH keys configured.

### Step 13: Configure Network Security Settings

Configure kernel network parameters for enhanced security by adding a drop-in file (idempotent and doesn't mutate `/etc/sysctl.conf`):

```bash
sudo tee /etc/sysctl.d/99-hardening.conf > /dev/null <<EOF
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.log_martians=1
EOF
```

**Apply the changes:**

```bash
sudo sysctl --system

# Verify
sudo sysctl net.ipv4.conf.all.rp_filter
sudo sysctl net.ipv4.conf.all.accept_redirects
sudo sysctl net.ipv4.conf.all.send_redirects
sudo sysctl net.ipv4.conf.all.log_martians
```

> **Note:** Use `sysctl --system` (not `sysctl -p`) so the drop-in file in `/etc/sysctl.d/` is actually read — plain `-p` only reloads `/etc/sysctl.conf`.

**What these settings do:**

- **Spoof protection (rp_filter)**: Validates that packets are coming from legitimate sources
- **Disable ICMP redirects**: Prevents Man-in-the-Middle attacks via malicious route redirects
- **Disable send redirects**: This is an application server, not a router
- **Log Martians**: Records packets with impossible source addresses to help detect attacks

### Step 14: Open Firewall Ports

1. Go to your Lightsail instance in AWS Console
2. Click on the **Networking** tab
3. Under **IPv4 Firewall**, ensure these ports are open:
   - **SSH** (TCP 22)
   - **HTTP** (TCP 80)
   - **HTTPS** (TCP 443)
4. Click **Save** if you made any changes

---

## Activating the Node.js App

The launch script installs Node.js and prepares a Supervisor entry for `nodeapp`, but the service starts disabled (`autostart=false`) because there's no app code yet. Here's how to deploy your app:

### Step 1: Upload Your App Code

Open Filebrowser at `http://YOUR_IP/filebrowser` and upload your app files into `/myapps/nodeapp/`. At minimum you need an `index.js` (the entry point referenced in the Supervisor config). If your app has dependencies, also upload `package.json` (and optionally `package-lock.json`).

The included Supervisor config expects:
- Entry point: `/myapps/nodeapp/index.js`
- App listens on `127.0.0.1:8092` (Caddy proxies `/nodeapp/*` to this port)

The `PORT` environment variable is set to `8092` by Supervisor, so use `process.env.PORT` in your code.

### Step 2: Install Dependencies (If Any)

If your app uses npm packages, SSH in and install them:

```bash
cd /myapps/nodeapp
sudo npm install --omit=dev
```

`--omit=dev` skips dev dependencies, which you don't want on a production server.

### Step 3: Enable Autostart

Edit the Supervisor config and flip `autostart` to `true`:

```bash
sudo sed -i 's/^autostart=false/autostart=true/' /etc/supervisor/conf.d/nodeapp.conf
```

Then tell Supervisor to pick up the change and start the service:

```bash
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl start nodeapp
```

### Step 4: Verify

```bash
sudo supervisorctl status nodeapp        # should say RUNNING
curl http://127.0.0.1:8092/              # direct hit on the app
curl http://127.0.0.1/nodeapp/           # through Caddy
sudo tail -f /myapps/nodeapp/nodeapp.err.log
```

If something's wrong, check the error log first — Node uncaught exceptions land there.

### Updating Your App Code

Upload new files via Filebrowser (or `scp`), then restart:

```bash
sudo supervisorctl restart nodeapp
```

If you changed dependencies (`package.json`), run `sudo npm install --omit=dev` in `/myapps/nodeapp/` before restarting.

---

## Enabling HTTPS (After DNS is Configured)

Once your domain is pointing to your instance:

### Option A: Quick Edit in SSH

```bash
sudo nano /myapps/caddy/Caddyfile
```

Replace `:80` with your domain (e.g., `sub.domain.ext`), save and reload:
```bash
sudo supervisorctl restart caddy
```

### Option B: One-liner Command

```bash
sudo sed -i 's/:80/sub.domain.ext/' /myapps/caddy/Caddyfile && sudo supervisorctl restart caddy
```

**Important:** Replace `sub.domain.ext` with your actual domain!

Caddy will automatically obtain SSL certificates from Let's Encrypt, configure HTTPS, redirect HTTP to HTTPS, and auto-renew certificates.

---

## Supervisor Quick Reference

### Managing Applications

```bash
sudo supervisorctl status

sudo supervisorctl start caddy
sudo supervisorctl start pocketbase
sudo supervisorctl start filebrowser
sudo supervisorctl start nodeapp

sudo supervisorctl stop caddy
sudo supervisorctl stop pocketbase
sudo supervisorctl stop filebrowser
sudo supervisorctl stop nodeapp

sudo supervisorctl restart caddy
sudo supervisorctl restart pocketbase
sudo supervisorctl restart filebrowser
sudo supervisorctl restart nodeapp

sudo tail -f /myapps/caddy/caddy.err.log
sudo tail -f /myapps/pocketbase/pocketbase.err.log
sudo tail -f /myapps/filebrowser/filebrowser.err.log
sudo tail -f /myapps/nodeapp/nodeapp.err.log
```

### Updating All Binaries

The same script that performs the initial install (`/myapps/install-update-binaries.sh`, content embedded in [`script.sh`](./script.sh) between the `BINEOF` markers) is also used for updates. The first install is invoked with `--first-run` (which skips the stop/backup/restart logic since nothing is running yet); for updates, run it without the flag. Update mode stops the services, backs up current binaries, downloads the latest versions of Caddy, Pocketbase, Filebrowser, and Node.js (within the configured `NODE_MAJOR` line), validates the downloads, and restarts each service whose Supervisor config has `autostart=true`.

```bash
sudo bash /myapps/install-update-binaries.sh
```

Services with `autostart=false` are left stopped after the update — only their binaries are refreshed. This applies uniformly to all four services, so e.g. flipping Pocketbase to `autostart=false` and re-running the script will update Pocketbase's binary without starting it.

---

## Default Credentials

**Pocketbase Admin:**
- URL: `http://YOUR_IP/_/` or `https://YOUR_DOMAIN/_/`
- Email: Set via `POCKETBASE_EMAIL` in launch script (or created manually)
- Password: Set via `POCKETBASE_PASS` in launch script (or created manually)

**Filebrowser:**
- URL: `http://YOUR_IP/filebrowser` or `https://YOUR_DOMAIN/filebrowser`
- Default username: `admin`
- First-time credentials are shown in: `/myapps/filebrowser/filebrowser.err.log`

**Nodeapp:**
- No default credentials — your app handles its own auth (or doesn't, depending on what you build).

---

## Directory Structure

After installation, your directory structure will look like:

```
/myapps/
├── install-update-binaries.sh (install/update script for all binaries)
├── caddy/
│   ├── caddy (executable, prebuilt with rate limiting module)
│   ├── Caddyfile
│   ├── data/caddy/ (certificates, OCSP staples)
│   ├── config/caddy/ (autosaved config)
│   ├── caddy.err.log
│   └── caddy.out.log
├── pocketbase/
│   ├── pocketbase (executable)
│   ├── pb_data/
│   ├── pb_public/
│   │   └── index.html (sample page)
│   ├── pocketbase.err.log
│   └── pocketbase.out.log
├── filebrowser/
│   ├── filebrowser (executable)
│   ├── filebrowser.db
│   ├── filebrowser.out.log
│   └── filebrowser.err.log
└── nodeapp/
    ├── index.js (your code, uploaded via Filebrowser)
    ├── package.json (if your app has dependencies)
    ├── node_modules/ (created by `npm install`)
    ├── nodeapp.err.log
    └── nodeapp.out.log
```

**Note:** Filebrowser is configured to show and manage the entire `/myapps` directory.

---

## Troubleshooting

### Applications not starting?
```bash
sudo supervisorctl status
sudo tail -f /myapps/caddy/caddy.err.log
sudo tail -f /myapps/pocketbase/pocketbase.err.log
sudo tail -f /myapps/filebrowser/filebrowser.err.log
sudo tail -f /myapps/nodeapp/nodeapp.err.log
```

### Can't access via browser?
1. Check firewall rules in Lightsail (port 80 and 443 must be open)
2. Check Caddy status: `sudo supervisorctl status caddy`
3. Check Caddy logs: `sudo tail -50 /myapps/caddy/caddy.err.log`

### Pocketbase Admin UI not loading?
- Make sure to access: `http://YOUR_IP/_/` (note the trailing slash and underscore)
- Check that Pocketbase is running: `sudo supervisorctl status pocketbase`

### Nodeapp won't start?
- Confirm `autostart=true` in `/etc/supervisor/conf.d/nodeapp.conf`, then `sudo supervisorctl reread && sudo supervisorctl update`
- Confirm `index.js` exists at `/myapps/nodeapp/index.js`
- Check that the app listens on `127.0.0.1:8092` (or `process.env.PORT`), not on `0.0.0.0` or some other port — Caddy expects 8092
- Check the error log: `sudo tail -50 /myapps/nodeapp/nodeapp.err.log`
- If your app has dependencies and `node_modules/` is missing, run `cd /myapps/nodeapp && sudo npm install --omit=dev`

### Nodeapp returns 502 Bad Gateway?
- The app is registered with Caddy but isn't actually running. Check `sudo supervisorctl status nodeapp` and the error log.

### HTTPS Issues

#### Caddy can't obtain certificate
- Make sure port 443 is open in your Lightsail firewall
- Ensure your domain is pointing to your instance: `nslookup <sub.domain.ext>`
- Check Caddy logs: `sudo tail -100 /myapps/caddy/caddy.err.log`
- DNS must be configured and propagated BEFORE Caddy can obtain a certificate
- If you configured the domain before DNS was ready, wait for propagation then run `sudo supervisorctl restart caddy`

#### Certificate verification failed
- Your domain DNS is not configured correctly
- Wait a few minutes for DNS propagation
- Verify: `nslookup <sub.domain.ext>` returns your instance IP

#### Caddy fails to start
- Check for typos in domain names in the Caddyfile
- Validate config: `/myapps/caddy/caddy validate --config /myapps/caddy/Caddyfile`
- Check Caddy logs: `sudo tail -50 /myapps/caddy/caddy.err.log`

---
