# OGP Auto Installer

Automated bash installer for [Open Game Panel (OGP)](https://www.opengamepanel.org/) on Ubuntu and Debian. One script installs the full stack with no browser wizard.

**Tested on:** Ubuntu 22.04 / 24.04 / 26.04 (x86_64), Debian 11 / 12

## What it installs

- OGP web panel (latest from [OGP-Website](https://github.com/OpenGamePanel/OGP-Website))
- OGP Linux agent (official `.deb` + latest agent files)
- MariaDB, Apache, PHP
- Automated panel setup (database + admin user)
- Local agent registered in the panel
- Local MariaDB registered in **OGP MySQL Admin**
- **phpMyAdmin** at `/phpmyadmin/` (HTTP basic auth + MariaDB root login)
- Optional UFW rules and 2 GB swap

All services share one unified password unless you set `PASSWORD` yourself. The OGP agent encryption key is limited to **16 characters** (auto-truncated from `PASSWORD` if needed).

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/squiddd666/OGP-Auto-Installer/master/install-ogp.sh -o install-ogp.sh
sudo bash install-ogp.sh
```

### Custom settings

```bash
PASSWORD='MySecurePass123' \
FQDN='panel.example.com' \
ADMIN_EMAIL='you@example.com' \
sudo -E bash install-ogp.sh
```

Use `sudo -E` so exported variables are passed through.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PASSWORD` | Auto-generated | Panel admin, MariaDB, and agent Linux user password |
| `ENCRYPTION_KEY` | First 16 chars of `PASSWORD` | OGP agent encryption key (**max 16 characters**) |
| `FQDN` | Public IP | Panel URL and display IP for NAT |
| `ADMIN_USER` | `admin` | Panel admin username |
| `ADMIN_EMAIL` | `admin@example.com` | Admin email |
| `INSTALL_AGENT` | `yes` | Install and register local OGP agent |
| `SETUP_MYSQL_HOST` | `yes` | Register local MariaDB in OGP MySQL Admin |
| `MYSQL_HOST_NAME` | `Local MariaDB` | Display name for the MySQL host in the panel |
| `INSTALL_PHPMYADMIN` | `yes` | Install phpMyAdmin at `/phpmyadmin/` |
| `PMA_USER` | `admin` | HTTP basic auth username for phpMyAdmin |
| `CONFIGURE_FIREWALL` | `yes` | UFW rules (22, 80, 443, agent, FTP, game ports) |
| `INSTALL_SWAP` | `yes` | 2 GB swap file |
| `USE_NAT` | `1` | NAT-friendly display IP (GCP/AWS) |
| `CREDENTIALS_FILE` | `/root/ogp-credentials.txt` | Saved credentials |

Show built-in help:

```bash
bash install-ogp.sh --help
```

## After installation

Credentials are saved to `/root/ogp-credentials.txt`. Install log: `/var/log/ogp-auto-install.log`.

| Service | URL |
|---------|-----|
| **Panel** | `http://YOUR_IP/index.php` |
| **MySQL Admin** (OGP) | `http://YOUR_IP/home.php?m=mysql&p=mysql_admin` |
| **phpMyAdmin** | `http://YOUR_IP/phpmyadmin/` |

**Ports to open** in your cloud firewall: 22, 80, 443, **12679** (agent), **21** (FTP), and game ports as needed.

### phpMyAdmin login

1. HTTP popup: user `admin` (or `PMA_USER`), password = your unified `PASSWORD`
2. MariaDB screen: user `root`, password = your unified `PASSWORD`

### OGP MySQL Admin

Log into the OGP panel first as admin, then open MySQL Admin to create databases for game servers.

## System requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **OS** | Ubuntu 22.04+ or Debian 11+ | Fresh VPS |
| **CPU** | 1 vCPU | 2+ vCPUs |
| **RAM** | 2 GB | 4 GB+ |
| **Disk** | 10 GB free | 20 GB+ |

Use a **fresh VPS** for the smoothest install. Reinstalling on a server with leftover MariaDB data may require the script to reinitialize the database directory.

## Credits

| Project | Link |
|---------|------|
| **Open Game Panel** | [opengamepanel.org](https://www.opengamepanel.org/) |
| **OGP-Website** | [github.com/OpenGamePanel/OGP-Website](https://github.com/OpenGamePanel/OGP-Website) |
| **OGP Easy-Installers** | [github.com/OpenGamePanel/Easy-Installers](https://github.com/OpenGamePanel/Easy-Installers) |

**OGP Auto Installer** — maintained by [squiddd666](https://github.com/squiddd666).

## Disclaimer

This script modifies system packages, services, databases, and firewall rules. Use only on a server you own and review the script before running in production. Not affiliated with the OGP Development Team.
