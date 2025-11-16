# Hosting Pocketbase and Filebrowser on AWS Lightsail

## Overview

This guide will help you host two applications on a single AWS Lightsail instance:
- **Pocketbase** at: `http://your-ip/` or `https://your-domain/`
- **Filebrowser** at: `http://your-ip/filebrowser` or `https://your-domain/filebrowser`

**Important Notes:**

- Pocketbase is served at the root path for simplest access and starts automatically
- Filebrowser is configured to manage the Pocketbase directory (`/myapps/pocketbase`) for easy file management
- Filebrowser does NOT start automatically - start it manually with `sudo supervisorctl start filebrowser` when needed
- Filebrowser requires the `--baseurl` flag for proper asset loading under `/filebrowser`
- [The launch script](#complete-launch-script) sets up HTTP; HTTPS is configured by simply adding your domain to the Caddyfile
- SSHGuard is installed and active for SSH brute-force protection (no configuration needed)
- Enhanced network security settings are applied
- File upload size is limited to 10MB (configurable in Caddyfile)
- Pocketbase has a 6-minute (360 seconds) timeout for long-running operations
- Use `btop` command for system resource monitoring

---

# Table of Contents

- [Overview](#overview)
- [Quick Start (Automated)](#quick-start-automated)
  - [Option 1: Use the Launch Script](#option-1-use-the-launch-script)
- [Manual Installation (Step-by-Step)](#manual-installation-step-by-step)
  - [Step 1: Create Your Lightsail Instance](#step-1-create-your-lightsail-instance)
  - [Step 2: Connect via SSH](#step-2-connect-via-ssh)
  - [Step 3: Update System and Install Dependencies](#step-3-update-system-and-install-dependencies)
  - [Step 4: Install Caddy](#step-4-install-caddy)
  - [Step 5: Create Directory Structure](#step-5-create-directory-structure)
  - [Step 6: Download and Install Pocketbase](#step-6-download-and-install-pocketbase)
  - [Step 7: Download and Install Filebrowser](#step-7-download-and-install-filebrowser)
  - [Step 8: Configure Supervisor for Pocketbase](#step-8-configure-supervisor-for-pocketbase)
  - [Step 9: Configure Supervisor for Filebrowser](#step-9-configure-supervisor-for-filebrowser)
  - [Step 10: Load Supervisor Configurations](#step-10-load-supervisor-configurations)
  - [Step 11: Configure Caddy](#step-11-configure-caddy)
  - [Step 12: Reload Caddy](#step-12-reload-caddy)
  - [Step 13: Configure SSH Security](#step-13-configure-ssh-security)
  - [Step 14: Configure Network Security Settings](#step-14-configure-network-security-settings)
  - [Step 15: Open Firewall Ports](#step-15-open-firewall-ports)
- [Enabling HTTPS (After DNS is Configured)](#enabling-https-after-dns-is-configured)
- [Supervisor Quick Reference](#supervisor-quick-reference)
- [Default Credentials](#default-credentials)
- [Directory Structure](#directory-structure)
- [Troubleshooting](#troubleshooting)
- [Next Steps](#next-steps)
- [Complete Launch Script](#complete-launch-script)

---

## Quick Start (Automated)

### Option 1: Use the Launch Script

When creating your Lightsail instance:

1. Go to AWS Lightsail Console
2. Click **Create instance**
3. Select **Linux/Unix** platform
4. Choose **OS Only** → **Ubuntu 24.04 LTS**
5. Scroll to **Add launch script**
6. Copy and paste the [complete launch script](#complete-launch-script) from the end of this guide
7. Choose your instance plan (minimum: $5/month)
8. Click **Create instance**

The script will automatically install and configure everything for HTTP. Wait 3-5 minutes after the instance starts.

**Quick Check:**

- Installation log: `cat /var/log/setup-complete.log`
- System monitor: `btop` (press `q` to exit)

**Initial Access (HTTP):**
- Pocketbase Public Page: `http://YOUR_IP/` (sample page: "Under construction...")
- Pocketbase Admin: `http://YOUR_IP/_/` (login with credentials from `POCKETBASE_EMAIL` and `POCKETBASE_PASS`)
- Filebrowser: Start manually with `sudo supervisorctl start filebrowser`, then access `http://YOUR_IP/filebrowser` (Check `/myapps/filebrowser/filebrowser.err.log` for credentials)

**After DNS Configuration:**
Edit the script variable `CUSTOM_DOMAIN=":80"` to your domain before launch, or follow the "Enabling HTTPS" section below to secure your site with SSL certificates (just one config change!).

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
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl supervisor unzip sshguard btop
```

### Step 4: Install Caddy

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

### Step 5: Create Directory Structure

```bash
sudo mkdir -p /myapps/pocketbase
sudo mkdir -p /myapps/filebrowser
```

### Step 6: Download and Install Pocketbase

```bash
cd /myapps/pocketbase
sudo wget https://github.com/pocketbase/pocketbase/releases/download/v0.31.0/pocketbase_0.31.0_linux_amd64.zip
sudo unzip pocketbase_0.31.0_linux_amd64.zip
sudo rm pocketbase_0.31.0_linux_amd64.zip
sudo chmod +x pocketbase
```

**Optional:** Create a superuser now:

```bash
cd /myapps/pocketbase
sudo ./pocketbase superuser create your-email@example.com your-password
```

**Optional:** Create a sample public page:
```bash
sudo mkdir -p /myapps/pocketbase/pb_public
sudo bash -c 'cat > /myapps/pocketbase/pb_public/index.html <<EOF
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"></head><body><h1>Under construction...</h1></body></html>
EOF'
```

This creates a simple page served at the root URL by Pocketbase.

### Step 7: Download and Install Filebrowser

```bash
cd /myapps/filebrowser
sudo wget https://github.com/filebrowser/filebrowser/releases/download/v2.44.2/linux-amd64-filebrowser.tar.gz
sudo tar -xzf linux-amd64-filebrowser.tar.gz
sudo rm linux-amd64-filebrowser.tar.gz
sudo chmod +x filebrowser
```

### Step 8: Configure Supervisor for Pocketbase

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

### Step 9: Configure Supervisor for Filebrowser

```bash
sudo nano /etc/supervisor/conf.d/filebrowser.conf
```

Paste this configuration:

```ini
[program:filebrowser]
directory=/myapps/filebrowser
command=/myapps/filebrowser/filebrowser -r /myapps/pocketbase -a 127.0.0.1 -p 8091 --baseurl /filebrowser
autostart=false
autorestart=true
stderr_logfile=/myapps/filebrowser/filebrowser.err.log
stdout_logfile=/myapps/filebrowser/filebrowser.out.log
logfile_maxbytes=10MB
logfile_backups=5
user=root
```

**Note:** Filebrowser is set to `autostart=false` and must be started manually when needed.

Save and exit (Ctrl+X, then Y, then Enter)

### Step 10: Load Supervisor Configurations

```bash
sudo supervisorctl reread
sudo supervisorctl update
```

The `update` command will load the new configurations. Only Pocketbase will start automatically (Filebrowser is set to manual start).

Check status:
```bash
sudo supervisorctl status
```

You should see:
- `pocketbase RUNNING`
- `filebrowser STOPPED` (not started by default)

**To start Filebrowser manually when needed:**
```bash
sudo supervisorctl start filebrowser
```

**To stop Filebrowser:**
```bash
sudo supervisorctl stop filebrowser
```

### Step 11: Configure Caddy

```bash
sudo nano /etc/caddy/Caddyfile
```

Replace the entire content with:

```caddy
# HTTP-only configuration (for initial setup)
:80 {
    # Limit file upload size
    request_body {
        max_size 10MB
    }
    
    # Filebrowser (must come before root)
    # Redirect /filebrowser to /filebrowser/ with trailing slash
    handle /filebrowser {
        redir {path}/ permanent
    }
    handle /filebrowser/* {
        reverse_proxy localhost:8091
    }
    
    # Pocketbase at root (catches everything else)
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

### Step 12: Reload Caddy

```bash
sudo systemctl reload caddy
```

Check Caddy status:
```bash
sudo systemctl status caddy
```

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

Configure kernel network parameters for enhanced security. These settings protect against various network attacks and improve system security.

**Note:** The automated sed commands below will replace any existing lines containing these parameters with the correct values, ensuring consistency regardless of whether they're commented, uncommented, or have different values.

```bash
# Edit sysctl.conf
sudo nano /etc/sysctl.conf
```

Ensure these lines exist with these exact values (add them if missing, update them if they have different values):

```conf
# IP Spoofing protection
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1

# Ignore ICMP redirects (prevent MITM attacks)
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0

# Ignore send redirects (we are not a router)
net.ipv4.conf.all.send_redirects=0

# Log Martians (packets with impossible source addresses)
net.ipv4.conf.all.log_martians=1
```

**Or use this automated approach with sed commands:**

```bash
# Replace any line containing these parameters with the correct values
# This ensures consistency regardless of existing comments or values

# Enable IP Spoofing protection (reverse path filtering)
sudo sed -i '/net\.ipv4\.conf\.default\.rp_filter/c\net.ipv4.conf.default.rp_filter=1' /etc/sysctl.conf
sudo sed -i '/net\.ipv4\.conf\.all\.rp_filter/c\net.ipv4.conf.all.rp_filter=1' /etc/sysctl.conf

# Disable ICMP redirects (prevent MITM attacks)
sudo sed -i '/net\.ipv4\.conf\.all\.accept_redirects/c\net.ipv4.conf.all.accept_redirects=0' /etc/sysctl.conf
sudo sed -i '/net\.ipv4\.conf\.default\.accept_redirects/c\net.ipv4.conf.default.accept_redirects=0' /etc/sysctl.conf

# Disable sending ICMP redirects (we're not a router)
sudo sed -i '/net\.ipv4\.conf\.all\.send_redirects/c\net.ipv4.conf.all.send_redirects=0' /etc/sysctl.conf

# Enable logging of Martian packets (impossible source addresses)
sudo sed -i '/net\.ipv4\.conf\.all\.log_martians/c\net.ipv4.conf.all.log_martians=1' /etc/sysctl.conf
```

**Apply the changes:**

```bash
# Apply new settings (will display all applied settings)
sudo sysctl -p
```

### Step 15: Open Firewall Ports

1. Go to your Lightsail instance in AWS Console
2. Click on the **Networking** tab
3. Under **IPv4 Firewall**, ensure these ports are open:
   - **SSH** (TCP 22) - (I choose => Restricted to: Lightsail browser SSH/RDP Only)
   - **HTTP** (TCP 80) - Any IPv4 address
   - **HTTPS** (TCP 443) - Any IPv4 address
4. Click **Save** if you made any changes

---

## Enabling HTTPS (After DNS is Configured)

Once your domain is pointing to your instance:

### Option A: Quick Edit in SSH

```bash
sudo nano /etc/caddy/Caddyfile
```

Replace `:80` with your domain (e.g., `sub.domain.ext`):

```caddy
sub.domain.ext {
    # Limit file upload size
    request_body {
        max_size 10MB
    }
    
    # Filebrowser configuration...
    # Pocketbase configuration...
}
```

Save and reload:
```bash
sudo systemctl reload caddy
```

Caddy will automatically:
- Obtain SSL certificates from Let's Encrypt
- Configure HTTPS on port 443
- Redirect HTTP to HTTPS
- Auto-renew certificates

---

## Supervisor Quick Reference

### Managing Applications

```bash
# Check status
sudo supervisorctl status

# Start applications
sudo supervisorctl start pocketbase
sudo supervisorctl start filebrowser

# Stop applications
sudo supervisorctl stop pocketbase
sudo supervisorctl stop filebrowser

# Restart applications
sudo supervisorctl restart pocketbase
sudo supervisorctl restart filebrowser

# View logs
sudo tail -f /myapps/pocketbase/pocketbase.err.log
sudo tail -f /myapps/filebrowser/filebrowser.err.log
```

---

## Default Credentials

**Pocketbase Admin:**
- URL: `http://YOUR_IP/_/` or `https://YOUR_DOMAIN/_/`
- Email: Set via `POCKETBASE_EMAIL` in launch script (or created manually)
- Password: Set via `POCKETBASE_PASS` in launch script (or created manually)

**Filebrowser:**
- URL: `http://YOUR_IP/filebrowser` or `https://YOUR_DOMAIN/filebrowser`
- Credentials are shown in: `/myapps/filebrowser/filebrowser.err.log`

---

## Directory Structure

After installation, your directory structure will look like:

```
/myapps/
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

**Note:** Filebrowser is configured to show and manage only the `/myapps/pocketbase` directory, giving you easy access to all Pocketbase files through the web interface.

---

## Troubleshooting

### Applications not starting?
```bash
sudo supervisorctl status
sudo tail -f /myapps/pocketbase/pocketbase.err.log
sudo tail -f /myapps/filebrowser/filebrowser.err.log
```

### Can't access via browser?
1. Check firewall rules in Lightsail (port 80 and 443 must be open)
2. Check Caddy status: `sudo systemctl status caddy`
3. Check Caddy logs: `sudo journalctl -u caddy -n 50`

### Can't access Filebrowser?
Filebrowser doesn't start automatically. You must start it manually:
```bash
sudo supervisorctl start filebrowser
```

Then check if it's running:
```bash
sudo supervisorctl status filebrowser
```

### Filebrowser shows JavaScript errors in browser console?
This means the `--baseurl /filebrowser` flag is missing. Fix it:
```bash
sudo nano /etc/supervisor/conf.d/filebrowser.conf
```
Ensure the command line includes `-r /myapps/pocketbase` and `--baseurl /filebrowser`, then:
```bash
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl restart filebrowser
```

### Pocketbase Admin UI not loading?
- Make sure to access: `http://YOUR_IP/_/` (note the trailing slash and underscore)
- Check that Pocketbase is running: `sudo supervisorctl status pocketbase`

### HTTPS Issues

#### Caddy can't obtain certificate
- Make sure port 443 is open in your Lightsail firewall
- Ensure your domain is pointing to your instance: `nslookup <sub.domain.ext>`
- Check Caddy logs: `sudo journalctl -u caddy -n 100`
- **Remember:** DNS must be configured and propagated BEFORE Caddy can obtain a certificate
- If you configured the domain in the Caddyfile before DNS was ready, just wait for DNS propagation then run `sudo systemctl reload caddy`

#### "Certificate verification failed"
- Your domain DNS is not configured correctly
- Wait a few minutes for DNS propagation
- Verify: `nslookup <sub.domain.ext>` returns your instance IP

#### Caddy fails to start
- Check for typos in domain names in the Caddyfile
- Validate config: `caddy validate --config /etc/caddy/Caddyfile`
- Check Caddy logs: `sudo journalctl -u caddy -n 50`

---

## Next Steps

**Recommended production workflow:**

1. **Customize launch script**: Set `POCKETBASE_EMAIL` and `POCKETBASE_PASS` to secure credentials
2. **Launch with HTTP**: Use `CUSTOM_DOMAIN=":80"` in the launch script
3. **Verify setup**: Test both applications via HTTP and check with `btop`
4. **Attach Static IP**: Go to Lightsail → Networking → Create and attach static IP
5. **Configure DNS**: Point your domain to the static IP in Route 53
6. **Wait for DNS**: Verify with `nslookup your-domain.com` (1-5 minutes)
7. **Enable HTTPS**: Edit `/etc/caddy/Caddyfile`, replace `:80` with your domain, run `sudo systemctl reload caddy`
9. **Setup backups**: Create regular snapshots in Lightsail Console
10. **Monitor security**: Check `/var/log/syslog` for Martian packets and security events

---

## Complete Launch Script

Copy this entire script when creating your Lightsail instance:

```bash
#!/bin/bash

# App config
POCKETBASE_VERSION="0.31.0"
POCKETBASE_EMAIL="user@provider.com"
POCKETBASE_PASS="12345678"
FILEBROWSER_VERSION="2.44.2"

# To enable HTTPS: replace ":80" with your domain (e.g., "sub.domain.ext")
CUSTOM_DOMAIN=":80"

# Update system
apt update && apt upgrade -y

# Install dependencies
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl supervisor unzip sshguard btop

# Install Caddy
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install -y caddy

# Create directory structure
mkdir -p /myapps/pocketbase
mkdir -p /myapps/filebrowser

# Download and install Pocketbase
cd /myapps/pocketbase
wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${POCKETBASE_VERSION}/pocketbase_${POCKETBASE_VERSION}_linux_amd64.zip"
unzip -q "pocketbase_${POCKETBASE_VERSION}_linux_amd64.zip"
rm "pocketbase_${POCKETBASE_VERSION}_linux_amd64.zip"
chmod +x pocketbase

# Create Pocketbase superuser
./pocketbase superuser create "${POCKETBASE_EMAIL}" "${POCKETBASE_PASS}"

# Create pb_public directory and sample index page
mkdir -p pb_public
cat > pb_public/index.html <<'EOF'
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"></head><body><h1>Under construction...</h1></body></html>
EOF

# Download and install Filebrowser
cd /myapps/filebrowser
wget -q "https://github.com/filebrowser/filebrowser/releases/download/v${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz"
tar -xzf linux-amd64-filebrowser.tar.gz
rm linux-amd64-filebrowser.tar.gz
chmod +x filebrowser

# Configure Supervisor for Pocketbase
cat > /etc/supervisor/conf.d/pocketbase.conf <<'EOF'
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
EOF

# Configure Supervisor for Filebrowser
cat > /etc/supervisor/conf.d/filebrowser.conf <<'EOF'
[program:filebrowser]
directory=/myapps/filebrowser
command=/myapps/filebrowser/filebrowser -r /myapps/pocketbase -a 127.0.0.1 -p 8091 --baseurl /filebrowser
autostart=false
autorestart=true
stderr_logfile=/myapps/filebrowser/filebrowser.err.log
stdout_logfile=/myapps/filebrowser/filebrowser.out.log
logfile_maxbytes=10MB
logfile_backups=5
user=root
EOF

# Start services with Supervisor
supervisorctl reread
supervisorctl update
sleep 2

# Configure Caddy
cat > /etc/caddy/Caddyfile <<EOF
${CUSTOM_DOMAIN} {
    # Limit file upload size
    request_body {
        max_size 10MB
    }
    
    # Filebrowser (must come before root)
    # Redirect /filebrowser to /filebrowser/ with trailing slash
    handle /filebrowser {
        redir {path}/ permanent
    }
    handle /filebrowser/* {
        reverse_proxy localhost:8091
    }
    
    # Pocketbase at root (catches everything else)
    handle {
        reverse_proxy localhost:8090 {
            transport http {
                read_timeout 360s
            }
        }
    }
}
EOF

# Reload Caddy
systemctl reload caddy

# Configure SSH security (key-based authentication only)
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
systemctl restart ssh

# Configure network security settings (kernel parameters)
# Replace any line containing these parameters with the correct values
sed -i '/net\.ipv4\.conf\.default\.rp_filter/c\net.ipv4.conf.default.rp_filter=1' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.all\.rp_filter/c\net.ipv4.conf.all.rp_filter=1' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.all\.accept_redirects/c\net.ipv4.conf.all.accept_redirects=0' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.default\.accept_redirects/c\net.ipv4.conf.default.accept_redirects=0' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.all\.send_redirects/c\net.ipv4.conf.all.send_redirects=0' /etc/sysctl.conf
sed -i '/net\.ipv4\.conf\.all\.log_martians/c\net.ipv4.conf.all.log_martians=1' /etc/sysctl.conf

# Apply network security settings
sysctl -p

# Create completion marker
echo "Installation completed at $(date)" > /var/log/setup-complete.log
```

**How to customize the script:**

Before pasting the script, edit the configuration variables at the top:

```bash
# App configuration
POCKETBASE_VERSION="0.31.0"          # Change to any version you want
POCKETBASE_EMAIL="user@provider.com" # Set your admin email
POCKETBASE_PASS="12345678"           # Set your admin password
FILEBROWSER_VERSION="2.44.2"         # Change to any version you want

# To enable HTTPS: replace ":80" with your domain (e.g., "sub.domain.ext")
CUSTOM_DOMAIN=":80"                  # Keep ":80" for HTTP, or set to "sub.domain.ext" for HTTPS
```

**Important:** Change `POCKETBASE_EMAIL` and `POCKETBASE_PASS` to your desired admin credentials before launching!

**Examples:**

*HTTP only (default):*
```bash
CUSTOM_DOMAIN=":80"
```

*HTTPS with your domain:*

```bash
CUSTOM_DOMAIN="sub.domain.ext"
```

**Important:** After using the launch script:

1. **Wait 3-5 minutes** for installation to complete
2. **Add HTTPS firewall rule** in Lightsail Console (Networking tab → Add rule for HTTPS TCP 443)
3. **Check installation**: `cat /var/log/setup-complete.log`
4. **Test applications**: 
   - Pocketbase: `http://YOUR_IP/_/` (login with your configured email/password)
   - Filebrowser: `sudo supervisorctl start filebrowser`, then `http://YOUR_IP/filebrowser`

**If you set a custom domain in the script:**
5. Point your domain to the instance IP in Route 53 (Create an A Record)
6. Wait for DNS propagation (1-5 minutes, verify with `nslookup your-domain.com`)
7. SSH in and run: `sudo systemctl reload caddy`
8. Access via HTTPS at your domain

**Note:** If you keep `CUSTOM_DOMAIN=":80"`, enable HTTPS later by editing `/etc/caddy/Caddyfile` and reloading Caddy.

---

That's it! You now have both applications running with automatic HTTPS support and enhanced security hardening thanks to Caddy, SSHGuard, and kernel network security settings. 🚀
