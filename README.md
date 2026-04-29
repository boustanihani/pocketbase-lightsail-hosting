# Hosting Pocketbase and Filebrowser on AWS Lightsail

## Overview

This guide will help you host two applications on a single AWS Lightsail instance:
- **Pocketbase** at: `http://your-ip/` or `https://your-domain/`
- **Filebrowser** at: `http://your-ip/filebrowser` or `https://your-domain/filebrowser`

**Important Notes:**

- Pocketbase is served at the root path for simplest access
- Filebrowser is configured to manage the entire `/myapps` directory (Caddy, Pocketbase, and Filebrowser subdirectories)
- Filebrowser requires the `--baseurl` flag for proper asset loading under `/filebrowser`
- Filebrowser login is rate-limited to 5 attempts per minute per IP via Caddy
- Caddy is installed as a prebuilt binary with the `mholt/caddy-ratelimit` module included
- All services (Caddy, Pocketbase, Filebrowser) start automatically and are managed via Supervisor under `/myapps`
- The script always installs the latest versions of Pocketbase and Filebrowser via the GitHub API
- The launch script sets up HTTP; HTTPS is configured by simply adding your domain to the Caddyfile
- SSHGuard is installed and active for SSH brute-force protection (no configuration needed)
- Enhanced network security settings are applied for DDoS protection and security hardening
- File upload size is limited to 10MB (configurable in Caddyfile)
- Pocketbase has a 6-minute timeout for long-running operations
- `btop` is installed for system resource monitoring

---

## Quick Start (Automated)

### Option 1: Use the Launch Script

When creating your Lightsail instance:

1. Go to AWS Lightsail Console
2. Click **Create instance**
3. Select **Linux/Unix** platform
4. Choose **OS Only** → **Ubuntu 24.04 LTS**
5. Scroll to **Add launch script**
6. Copy and paste the contents of [`script.sh`](./script.sh) (in this repo)
7. Choose your instance plan (minimum: $5/month)
8. Click **Create instance**
9. Wait 3-5 minutes after the instance starts.
10. Quick Check: `cat /var/log/setup-complete.log`

**Initial Access (HTTP):**
- Pocketbase Public Page: `http://YOUR_IP/` (sample page: "Seite in Arbeit...")
- Pocketbase Admin: `http://YOUR_IP/_/` (login with credentials from `POCKETBASE_EMAIL` and `POCKETBASE_PASS`)
- Filebrowser: `http://YOUR_IP/filebrowser` (check `/myapps/filebrowser/filebrowser.err.log` for the initial credentials)

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

### Step 4: Install Caddy (Prebuilt with Rate Limiting)

Caddy is installed as a prebuilt binary from the official Caddy download API. This build includes the `mholt/caddy-ratelimit` module for protecting the Filebrowser login endpoint.

```bash
sudo mkdir -p /myapps/caddy
sudo curl -o /myapps/caddy/caddy "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/mholt/caddy-ratelimit"
sudo chmod +x /myapps/caddy/caddy
```

### Step 5: Create Directory Structure

```bash
sudo mkdir -p /myapps/pocketbase /myapps/filebrowser
```

### Step 6: Download and Install Pocketbase (Latest)

```bash
PB_VERSION=$(curl -s https://api.github.com/repos/pocketbase/pocketbase/releases/latest | jq -r '.tag_name | ltrimstr("v")')
cd /myapps/pocketbase
sudo wget "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_amd64.zip"
sudo unzip "pocketbase_${PB_VERSION}_linux_amd64.zip"
sudo rm "pocketbase_${PB_VERSION}_linux_amd64.zip"
sudo chmod +x pocketbase
```

**Optional:** Create a superuser now (or do it later via the Admin UI):
```bash
cd /myapps/pocketbase
sudo ./pocketbase superuser create your-email@example.com your-password
```

**Optional:** Create a sample public page:
```bash
sudo mkdir -p /myapps/pocketbase/pb_public
sudo bash -c 'cat > /myapps/pocketbase/pb_public/index.html <<EOF
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"></head><body><h1>Seite in Arbeit...</h1></body></html>
EOF'
```

### Step 7: Download and Install Filebrowser (Latest)

```bash
FB_VERSION=$(curl -s https://api.github.com/repos/filebrowser/filebrowser/releases/latest | jq -r '.tag_name | ltrimstr("v")')
cd /myapps/filebrowser
sudo wget "https://github.com/filebrowser/filebrowser/releases/download/v${FB_VERSION}/linux-amd64-filebrowser.tar.gz"
sudo tar -xzf linux-amd64-filebrowser.tar.gz
sudo rm linux-amd64-filebrowser.tar.gz
sudo chmod +x filebrowser
```

### Step 8: Configure Supervisor for Caddy

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
logfile_maxbytes=10MB
logfile_backups=5
user=root
```

Save and exit (Ctrl+X, then Y, then Enter)

**Note:** Caddy needs to bind to port 80/443, which requires root. Since Supervisor runs this process as `user=root`, this works as-is.

### Step 9: Configure Supervisor for Pocketbase

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
logfile_maxbytes=10MB
logfile_backups=5
user=root
```

Save and exit (Ctrl+X, then Y, then Enter)

### Step 10: Configure Supervisor for Filebrowser

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
logfile_maxbytes=10MB
logfile_backups=5
user=root
```

Save and exit (Ctrl+X, then Y, then Enter)

### Step 11: Configure Caddy

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
        max_size 10MB
    }

    # Filebrowser (must come before root)
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

    # Pocketbase
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

### Step 12: Load Supervisor Configurations

```bash
sudo supervisorctl reread
sudo supervisorctl update
```

All three services will start automatically. Check status:
```bash
sudo supervisorctl status
```

You should see:
- `caddy RUNNING`
- `pocketbase RUNNING`
- `filebrowser RUNNING`

### Step 13: Configure SSH Security

Configure SSH for key-based authentication only:

```bash
sudo nano /etc/ssh/sshd_config
```

Find and modify these lines (remove `#` if commented):

```
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
```

**Or use this automated approach:**

```bash
sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
```

Restart SSH to apply changes:
```bash
sudo systemctl restart ssh
```

**Important:** After this step, only key-based SSH authentication will work! Make sure you have your SSH keys configured.

### Step 14: Configure Network Security Settings

Configure kernel network parameters for enhanced security.

```bash
sudo nano /etc/sysctl.conf
```

Ensure these lines exist with these exact values:

```conf
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.log_martians=1
```

**Or use this automated approach with sed commands:**

```bash
sudo sed -i '/net\.ipv4\.conf\.default\.rp_filter/c\net.ipv4.conf.default.rp_filter=1' /etc/sysctl.conf
sudo sed -i '/net\.ipv4\.conf\.all\.rp_filter/c\net.ipv4.conf.all.rp_filter=1' /etc/sysctl.conf
sudo sed -i '/net\.ipv4\.conf\.all\.accept_redirects/c\net.ipv4.conf.all.accept_redirects=0' /etc/sysctl.conf
sudo sed -i '/net\.ipv4\.conf\.default\.accept_redirects/c\net.ipv4.conf.default.accept_redirects=0' /etc/sysctl.conf
sudo sed -i '/net\.ipv4\.conf\.all\.send_redirects/c\net.ipv4.conf.all.send_redirects=0' /etc/sysctl.conf
sudo sed -i '/net\.ipv4\.conf\.all\.log_martians/c\net.ipv4.conf.all.log_martians=1' /etc/sysctl.conf
```

**Apply the changes:**

```bash
sudo sysctl -p

# Verify
sudo sysctl net.ipv4.conf.all.rp_filter
sudo sysctl net.ipv4.conf.all.accept_redirects
sudo sysctl net.ipv4.conf.all.send_redirects
sudo sysctl net.ipv4.conf.all.log_martians
```

**What these settings do:**

- **Spoof protection (rp_filter)**: Validates that packets are coming from legitimate sources
- **Disable ICMP redirects**: Prevents Man-in-the-Middle attacks via malicious route redirects
- **Disable send redirects**: This is an application server, not a router
- **Log Martians**: Records packets with impossible source addresses to help detect attacks

### Step 15: Open Firewall Ports

1. Go to your Lightsail instance in AWS Console
2. Click on the **Networking** tab
3. Under **IPv4 Firewall**, ensure these ports are open:
   - **SSH** (TCP 22)
   - **HTTP** (TCP 80)
   - **HTTPS** (TCP 443)
4. Click **Save** if you made any changes

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

sudo supervisorctl stop caddy
sudo supervisorctl stop pocketbase
sudo supervisorctl stop filebrowser

sudo supervisorctl restart caddy
sudo supervisorctl restart pocketbase
sudo supervisorctl restart filebrowser

sudo tail -f /myapps/caddy/caddy.err.log
sudo tail -f /myapps/pocketbase/pocketbase.err.log
sudo tail -f /myapps/filebrowser/filebrowser.err.log
```

### Updating All Binaries

An update script is included at `/myapps/update-myapps.sh` (source: [`update-myapps.sh`](./update-myapps.sh) in this repo). It stops all services, downloads the latest versions of Caddy, Pocketbase, and Filebrowser, validates the downloads, and restarts everything.

```bash
sudo bash /myapps/update-myapps.sh
```

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

---

## Directory Structure

After installation, your directory structure will look like:

```
/myapps/
├── update-myapps.sh (update script for all binaries)
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
└── filebrowser/
    ├── filebrowser (executable)
    ├── filebrowser.db
    ├── filebrowser.out.log
    └── filebrowser.err.log
```

**Note:** Filebrowser is configured to show and manage the entire `/myapps` directory (Caddy, Pocketbase, and Filebrowser subdirectories).

---

## Troubleshooting

### Applications not starting?
```bash
sudo supervisorctl status
sudo tail -f /myapps/caddy/caddy.err.log
sudo tail -f /myapps/pocketbase/pocketbase.err.log
sudo tail -f /myapps/filebrowser/filebrowser.err.log
```

### Can't access via browser?
1. Check firewall rules in Lightsail (port 80 and 443 must be open)
2. Check Caddy status: `sudo supervisorctl status caddy`
3. Check Caddy logs: `sudo tail -50 /myapps/caddy/caddy.err.log`

### Pocketbase Admin UI not loading?
- Make sure to access: `http://YOUR_IP/_/` (note the trailing slash and underscore)
- Check that Pocketbase is running: `sudo supervisorctl status pocketbase`

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
