# Hosting Pocketbase, Filebrowser, and a Node.js app on AWS Lightsail

Three apps on one Ubuntu 24.04 instance, behind Caddy, kept running by Supervisor:

| App | URL | Port |
|---|---|---|
| Pocketbase | `http://your-ip/` (admin UI: `/_/`) | 8090 |
| Filebrowser | `http://your-ip/filebrowser/` | 8091 |
| Node.js app | `http://your-ip/nodeapp/` | 8092 |

Plus automatic HTTPS for your domain, key-only SSH, SSHGuard, network hardening, zram and earlyoom against memory pressure, and a raised file-descriptor limit for Pocketbase's realtime connections.

---

## Install

1. In the [Lightsail console](https://lightsail.aws.amazon.com/): **Create instance** → **Linux/Unix** → **OS Only** → **Ubuntu 24.04 LTS**, plan **$5/month** or higher.
2. On the instance's **Networking** tab, open TCP **80** and **443** in **both** firewalls, IPv4 and IPv6. Lightsail keeps them separate, and the IPv6 table only appears once IPv6 is enabled on the same page. With IPv6 closed, IPv6-only visitors can't reach you, and Let's Encrypt can fail to issue your HTTPS certificate. SSH (22) is open on IPv4 by default; leaving it closed on IPv6 is fine.
3. **Connect using SSH** and run:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/boustanihani/pocketbase-lightsail-hosting/main/install.sh | sudo bash
   ```

   Press ENTER to go through the settings step by step (ENTER again keeps each default), or 2 to install with the defaults right away. It takes a few minutes and ends with a summary: the URLs, and the Pocketbase password, which is shown only this once.

Rather read and adjust everything first? Download only, then run all parts or one at a time:

```bash
curl -fsSL https://raw.githubusercontent.com/boustanihani/pocketbase-lightsail-hosting/main/download.sh | sudo bash
sudo nano /myapps/setup/00_config.cfg
sudo bash /myapps/setup/01_run_all_scripts.sh          # then 2: use the file as it is
sudo bash /myapps/setup/02_install_dependencies.sh     # …or one part at a time: 02, 03, …
```

---

## The setup scripts

They're in [`parts/`](parts/), and on the server in `/myapps/setup/`. Each one explains itself at the top: what it does and why, how to check it, and what to do when something goes wrong. All of them are safe to run again, so to change a setting, edit `00_config.cfg` and re-run the part that uses it.

| Part | What it does |
|---|---|
| [`00_config.cfg`](parts/00_config.cfg) | All settings: domain, Pocketbase superuser, autostart, Node app, major versions |
| [`01_run_all_scripts.sh`](parts/01_run_all_scripts.sh) | Asks for the settings, runs 02–10, logs to `install.log` |
| [`02_install_dependencies.sh`](parts/02_install_dependencies.sh) | System update and packages |
| [`03_harden_system.sh`](parts/03_harden_system.sh) | Key-only SSH, network kernel settings |
| [`04_config_oom.sh`](parts/04_config_oom.sh) | zram and earlyoom against running out of memory |
| [`05_raise_file_descriptor_limit.sh`](parts/05_raise_file_descriptor_limit.sh) | 65536 open files for the services, for Pocketbase's realtime connections |
| [`06_install_or_update_binaries.sh`](parts/06_install_or_update_binaries.sh) | Caddy, Pocketbase, Filebrowser, Node.js — also the update script |
| [`07_config_caddy.sh`](parts/07_config_caddy.sh) | Routes, upload limit, HTTPS |
| [`08_config_pocketbase.sh`](parts/08_config_pocketbase.sh) | Pocketbase service, superuser, sample page |
| [`09_config_filebrowser.sh`](parts/09_config_filebrowser.sh) | Filebrowser service and its config |
| [`10_config_nodeapp.sh`](parts/10_config_nodeapp.sh) | Node app service, and how to go live with your code |
| [`common.sh`](parts/common.sh) | Helpers shared by the parts (not a step) |

---

## After the installation

| What | Where | Login |
|---|---|---|
| Pocketbase admin | `http://YOUR_IP/_/` | `POCKETBASE_EMAIL` and the password from the summary |
| Filebrowser | `http://YOUR_IP/filebrowser/` | `admin` and a one-time password: `sudo grep 'admin password' /myapps/filebrowser/filebrowser.out.log` |
| Node app | `http://YOUR_IP/nodeapp/` | off until you upload your code, see [`10_config_nodeapp.sh`](parts/10_config_nodeapp.sh) |

**HTTPS:** point your domain at the instance, set `CUSTOM_DOMAIN` in `/myapps/setup/00_config.cfg`, then run `sudo bash /myapps/setup/07_config_caddy.sh`.

**Updating** Caddy, Pocketbase, Filebrowser and Node.js. It backs up the binaries and rolls back if a download fails:

```bash
sudo bash /myapps/setup/06_install_or_update_binaries.sh
```

**Newer setup scripts:** run the `download.sh` command again. It keeps your `00_config.cfg`.

---

## Everyday commands

```bash
sudo supervisorctl status                              # all services
sudo supervisorctl restart pocketbase                  # or caddy | filebrowser | nodeapp
sudo tail -f /myapps/pocketbase/pocketbase.err.log     # each service logs next to its binary
sudo tail -f /myapps/setup/install.log                 # what the installation did
```

Something not working? The part responsible for it lists the checks and fixes at its top.

---

## Directory structure

```
/myapps/
├── setup/          setup scripts, 00_config.cfg, install.log
├── caddy/          caddy, Caddyfile, data/ (certificates), config/
├── pocketbase/     pocketbase, pb_data/ (database), pb_public/ (served at /)
├── filebrowser/    filebrowser, config.yaml, filebrowser.sqlite, tmp/ (cache)
└── nodeapp/        your code: index.js, package.json, node_modules/
```

Each service folder also holds its `.err.log` and `.out.log`. Filebrowser shows this whole tree, plus `/etc/supervisor/conf.d/` as a second source named `supervisor`.
