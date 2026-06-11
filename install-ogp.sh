#!/usr/bin/env bash
#
# Open Game Panel (OGP) — Full Automated Installer
# Tested on: Ubuntu 22.04 / 24.04 / 26.04 (x86_64), Debian 11 / 12
#
# Installs:
#   - OGP Web Panel (latest from GitHub)
#   - OGP Linux Agent (official .deb + latest agent files)
#   - MariaDB, Apache, PHP
#   - Automated web installer (no browser wizard)
#   - Local agent registered in the panel
#   - Local MariaDB registered in OGP MySQL Admin
#   - phpMyAdmin (optional) at /phpmyadmin
#
# Usage:
#   sudo bash install-ogp.sh
#
#   PASSWORD=MySecurePass123 \
#   FQDN=panel.example.com \
#   ADMIN_USER=admin \
#   ADMIN_EMAIL=you@example.com \
#   sudo -E bash install-ogp.sh

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

FQDN="${FQDN:-$(curl -4 -s ifconfig.me 2>/dev/null || curl -4 -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_USER="${ADMIN_USER:-admin}"
PASSWORD="${PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)}"
# OGP XXTEA encryption key must be 1–16 characters (panel + agent limit).
if [[ -z "${ENCRYPTION_KEY:-}" ]]; then
    if [[ ${#PASSWORD} -le 16 ]]; then
        ENCRYPTION_KEY="$PASSWORD"
    else
        ENCRYPTION_KEY="${PASSWORD:0:16}"
    fi
fi
AGENT_USER="${AGENT_USER:-ogp_agent}"
SETUP_MYSQL_HOST="${SETUP_MYSQL_HOST:-yes}"
MYSQL_HOST_NAME="${MYSQL_HOST_NAME:-Local MariaDB}"
MYSQL_HOST_IP="${MYSQL_HOST_IP:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
INSTALL_PHPMYADMIN="${INSTALL_PHPMYADMIN:-yes}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-yes}"
INSTALL_AGENT="${INSTALL_AGENT:-yes}"
INSTALL_SWAP="${INSTALL_SWAP:-yes}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SERVER_NAME="${SERVER_NAME:-Main Server}"
USE_NAT="${USE_NAT:-1}"
DB_NAME="${DB_NAME:-ogp_panel}"
DB_USER="${DB_USER:-ogpuser}"
TABLE_PREFIX="${TABLE_PREFIX:-ogp_}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/root/ogp-credentials.txt}"
LOG_FILE="${LOG_FILE:-/var/log/ogp-auto-install.log}"
PANEL_DIR="${PANEL_DIR:-/var/www/html}"
PANEL_REPO="${PANEL_REPO:-https://github.com/OpenGamePanel/OGP-Website.git}"
AGENT_DEB_URL="${AGENT_DEB_URL:-https://raw.githubusercontent.com/OpenGamePanel/Easy-Installers/master/Linux/Debian-Ubuntu/ogp-agent-latest.deb}"
AGENT_DEB_MIN_BYTES="${AGENT_DEB_MIN_BYTES:-150000}"
AGENT_PORT="${AGENT_PORT:-12679}"
FTP_PORT="${FTP_PORT:-21}"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

log()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
}

validate_encryption_key() {
    if [[ ${#ENCRYPTION_KEY} -gt 16 ]]; then
        die "OGP encryption key must be 16 characters or fewer (got ${#ENCRYPTION_KEY}). Set ENCRYPTION_KEY to a shorter value."
    fi
}

is_ip() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

mariadb_root() {
    if mariadb -u root -e "SELECT 1" &>/dev/null; then
        mariadb -u root "$@"
    else
        mariadb -u root -p"${PASSWORD}" "$@"
    fi
}

detect_php_version() {
    php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;'
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────

require_root
validate_encryption_key

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

if [[ -f "${PANEL_DIR}/includes/config.inc.php" ]] && grep -q 'db_name' "${PANEL_DIR}/includes/config.inc.php" 2>/dev/null; then
    die "Open Game Panel already installed at ${PANEL_DIR}. Aborting."
fi

if [[ -d /var/lib/mariadb ]] && [[ -n "$(ls -A /var/lib/mariadb 2>/dev/null)" ]]; then
    reset_mariadb=0
    if ! mariadb -u root -e "SELECT 1" &>/dev/null; then
        reset_mariadb=1
    elif mariadb -u root -Nse "SHOW DATABASES LIKE '${DB_NAME}'" 2>/dev/null | grep -qx "${DB_NAME}"; then
        reset_mariadb=1
    fi
    if [[ "$reset_mariadb" -eq 1 ]]; then
        warn "Removing stale MariaDB data from a previous install."
        systemctl stop mariadb 2>/dev/null || true
        rm -rf /var/lib/mariadb
        if dpkg -l mariadb-server &>/dev/null; then
            mkdir -p /var/lib/mariadb
            chown mysql:mysql /var/lib/mariadb
            sudo -u mysql mariadb-install-db --datadir=/var/lib/mariadb --auth-root-authentication-method=socket
            systemctl start mariadb
        fi
    fi
fi

. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Unsupported OS: ${PRETTY_NAME:-unknown}. Use Ubuntu 22.04+ or Debian 11+." ;;
esac

if is_ip "$FQDN"; then
    DISPLAY_IP="$FQDN"
else
    DISPLAY_IP="$FQDN"
fi

log "FQDN / IP:        $FQDN"
log "Unified password: $PASSWORD"
[[ "$ENCRYPTION_KEY" != "$PASSWORD" ]] && log "Encryption key:   $ENCRYPTION_KEY (OGP max 16 chars)"
log "Admin user:       $ADMIN_USER"
log "Install agent:    $INSTALL_AGENT"
log "MySQL host:       $SETUP_MYSQL_HOST"
log "phpMyAdmin:       $INSTALL_PHPMYADMIN"
log "Credentials:      $CREDENTIALS_FILE"
echo

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: System packages
# ─────────────────────────────────────────────────────────────────────────────

install_dependencies() {
    log "Installing Apache, MariaDB, PHP, and dependencies..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        apache2 mariadb-server curl git wget unzip subversion \
        php php-cli php-common php-curl php-gd php-mbstring php-mysql \
        php-xml php-zip php-bcmath php-pear libapache2-mod-php \
        libxml-parser-perl libpath-class-perl perl-modules screen rsync \
        sudo e2fsprogs libarchive-extract-perl pure-ftpd libarchive-zip-perl \
        libc6 libgcc1 libhttp-daemon-perl

    # 32-bit libs for some game servers (best effort)
    dpkg --add-architecture i386 2>/dev/null || true
    apt-get update -qq
    apt-get install -y -qq libc6-i386 libgcc-s1:i386 libstdc++6:i386 2>/dev/null || \
        apt-get install -y -qq libc6-i386 lib32gcc1 lib32stdc++6 2>/dev/null || true

    a2enmod rewrite
    systemctl enable apache2 mariadb

    if ! systemctl start mariadb 2>/dev/null || ! mariadb -u root -e "SELECT 1" &>/dev/null; then
        warn "MariaDB did not start; reinitializing data directory..."
        systemctl stop mariadb 2>/dev/null || true
        rm -rf /var/lib/mariadb
        mkdir -p /var/lib/mariadb
        chown mysql:mysql /var/lib/mariadb
        sudo -u mysql mariadb-install-db --datadir=/var/lib/mariadb --auth-root-authentication-method=socket
        systemctl start mariadb
    fi

    systemctl restart apache2

  # Pear XXTEA required by OGP installer checks
    if ! pear list 2>/dev/null | grep -qi xxtea; then
        pear install -f channel://pear.php.net/Crypt_XXTEA-1.0.0 2>/dev/null || \
            pear install Crypt_XXTEA 2>/dev/null || \
            warn "Could not install Pear Crypt_XXTEA; panel wizard may fail."
    fi

    ok "Dependencies installed."
}

setup_mariadb() {
    log "Configuring MariaDB..."

    mariadb_root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${PASSWORD}';
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

    ok "MariaDB ready (database: ${DB_NAME})."
}

install_panel_files() {
    log "Downloading OGP panel from GitHub..."

    if [[ -d "$PANEL_DIR" ]] && [[ "$(ls -A "$PANEL_DIR" 2>/dev/null)" ]]; then
        find "$PANEL_DIR" -mindepth 1 -maxdepth 1 ! -name '.well-known' -exec rm -rf {} + 2>/dev/null || true
    fi

    local tmp
    tmp=$(mktemp -d)
    git clone --depth 1 "$PANEL_REPO" "$tmp/ogp"
    cp -a "$tmp/ogp/." "$PANEL_DIR/"
    rm -rf "$tmp"

    chown -R www-data:www-data "$PANEL_DIR"
    chmod -R 775 "$PANEL_DIR"
    chmod 775 "$PANEL_DIR/includes"
    touch "$PANEL_DIR/includes/config.inc.php"
    chmod 666 "$PANEL_DIR/includes/config.inc.php"
    mkdir -p "$PANEL_DIR/modules/TS3Admin/templates_c"
    chmod 777 "$PANEL_DIR/modules/TS3Admin/templates_c"

    [[ -f "$PANEL_DIR/index.html" ]] && mv "$PANEL_DIR/index.html" "$PANEL_DIR/index_orig.html" 2>/dev/null || true

    ok "Panel files installed to ${PANEL_DIR}."
}

run_panel_installer() {
    log "Running automated OGP web installer..."

    local cookie jar base
    cookie=$(mktemp)
    base="http://127.0.0.1/install.php"

    # Step 2: database setup + schema
    local step2
    step2=$(curl -fsS -c "$cookie" -b "$cookie" -X POST "$base?step=2" \
        -d "db_host=localhost" \
        -d "db_user=${DB_USER}" \
        -d "db_pass=${PASSWORD}" \
        -d "db_name=${DB_NAME}" \
        -d "table_prefix=${TABLE_PREFIX}" 2>&1) || die "Panel database setup failed. See $LOG_FILE"

    if ! echo "$step2" | grep -q 'Database tables created succesfully'; then
        echo "$step2" >> "$LOG_FILE"
        die "OGP database setup failed. Check $LOG_FILE"
    fi

    # Step 3: admin account
    local step3
    step3=$(curl -fsS -c "$cookie" -b "$cookie" -X POST "$base" \
        -d "step=3" \
        -d "username=${ADMIN_USER}" \
        -d "password1=${PASSWORD}" \
        -d "password2=${PASSWORD}" \
        -d "email=${ADMIN_EMAIL}" 2>&1) || die "Panel admin setup failed."

    if ! echo "$step3" | grep -q 'setup_complete\|Setup has been completed'; then
        if ! mariadb -u "${DB_USER}" -p"${PASSWORD}" "${DB_NAME}" -Nse \
            "SELECT 1 FROM ${TABLE_PREFIX}users WHERE users_login='${ADMIN_USER}' LIMIT 1" 2>/dev/null | grep -q 1; then
            echo "$step3" >> "$LOG_FILE"
            die "OGP admin account setup failed. Check $LOG_FILE"
        fi
        warn "Admin step HTML unclear; verified admin user exists in database."
    fi

    rm -f "$cookie"
    rm -f "$PANEL_DIR/install.php"
    chmod 644 "$PANEL_DIR/includes/config.inc.php"

    systemctl reload apache2
    ok "Panel installed. Login: http://${FQDN}/index.php"
}

install_agent() {
    [[ "$INSTALL_AGENT" == "yes" ]] || { log "Skipping OGP agent."; return; }

    log "Installing OGP agent..."

    local deb size
    deb=$(mktemp --suffix=.deb)
    curl -fsSL "$AGENT_DEB_URL" -o "$deb"
    size=$(stat -c%s "$deb" 2>/dev/null || wc -c < "$deb")
    if [[ "$size" -lt "$AGENT_DEB_MIN_BYTES" ]]; then
        rm -f "$deb"
        die "OGP agent .deb download looks truncated (${size} bytes). Try again or set AGENT_DEB_URL."
    fi

    # Pre-seed credentials (postinst reads this if present after preinst creates user)
    dpkg --unpack "$deb" 2>&1 | tee -a "$LOG_FILE"
    cat > /root/ogp_user_password <<EOF
ogpUser=${AGENT_USER}
ogpPass=${PASSWORD}
ogpEnc=${ENCRYPTION_KEY}
EOF
    echo "${AGENT_USER}:${PASSWORD}" | chpasswd
    dpkg --configure ogp-agent 2>&1 | tee -a "$LOG_FILE" || apt-get install -y -f -qq

    rm -f "$deb"

    # Ensure agent config matches unified credentials
    if [[ -f /usr/share/ogp_agent/Cfg/Config.pm ]]; then
        sed -i "s/key =>.*/key => '${ENCRYPTION_KEY}',/" /usr/share/ogp_agent/Cfg/Config.pm
        sed -i "s/sudo_password =>.*/sudo_password => '${PASSWORD}',/" /usr/share/ogp_agent/Cfg/Config.pm
    fi
  if [[ -f /etc/init.d/ogp_agent ]]; then
        sed -i "s/agent_user=.*/agent_user=${AGENT_USER}/" /etc/init.d/ogp_agent
    fi

    systemctl daemon-reload
    systemctl enable ogp_agent 2>/dev/null || true
    systemctl restart ogp_agent 2>/dev/null || service ogp_agent restart

    sleep 3
    systemctl is-active --quiet ogp_agent 2>/dev/null || \
        pgrep -f ogp_agent.pl &>/dev/null || \
        warn "OGP agent may not be running yet; check: systemctl status ogp_agent"

    ok "OGP agent installed (port ${AGENT_PORT})."
}

register_agent() {
    [[ "$INSTALL_AGENT" == "yes" ]] || return

    log "Registering local agent in the panel..."

    cat > /tmp/ogp-register-agent.php <<PHP
<?php
chdir('${PANEL_DIR}');
require_once 'includes/config.inc.php';
require_once 'includes/helpers.php';
require_once 'includes/lib_remote.php';

\$ip = getenv('OGP_AGENT_IP') ?: '127.0.0.1';
\$name = getenv('OGP_SERVER_NAME') ?: 'Main Server';
\$key = getenv('OGP_ENC_KEY') ?: '';
\$port = (int)(getenv('OGP_AGENT_PORT') ?: 12679);
\$ftp_port = (int)(getenv('OGP_FTP_PORT') ?: 21);
\$display_ip = getenv('OGP_DISPLAY_IP') ?: \$ip;
\$use_nat = (int)(getenv('OGP_USE_NAT') ?: 1);
\$timeout = 5;

\$db = createDatabaseConnection(\$db_type, \$db_host, \$db_user, \$db_pass, \$db_name, \$table_prefix);
if (!is_object(\$db)) {
    fwrite(STDERR, "Database connection failed\n");
    exit(1);
}

\$remote = new OGPRemoteLibrary(\$ip, \$port, \$key, \$timeout);
\$status = \$remote->status_chk();

if (\$status === 0) {
    fwrite(STDERR, "Agent offline at {\$ip}:{\$port}\n");
    exit(1);
}
if (\$status === -1) {
    fwrite(STDERR, "Encryption key mismatch\n");
    exit(1);
}

\$user = trim(\$remote->exec('whoami'));
\$id = \$db->addRemoteServer(\$ip, \$name, \$user, \$port, \$display_ip, \$ftp_port, \$key, \$timeout, \$use_nat, \$display_ip);
if (!\$id) {
    fwrite(STDERR, "Failed to add remote server to database\n");
    exit(1);
}

foreach ((array)\$remote->discover_ips() as \$remote_ip) {
    \$remote_ip = trim(\$remote_ip);
    if (\$remote_ip !== '') {
        \$db->addRemoteServerIP(\$id, \$remote_ip);
    }
}
echo "registered id={\$id} user={\$user}\n";
PHP

    OGP_AGENT_IP="127.0.0.1" \
    OGP_SERVER_NAME="$SERVER_NAME" \
    OGP_ENC_KEY="$ENCRYPTION_KEY" \
    OGP_AGENT_PORT="$AGENT_PORT" \
    OGP_FTP_PORT="$FTP_PORT" \
    OGP_DISPLAY_IP="$DISPLAY_IP" \
    OGP_USE_NAT="$USE_NAT" \
        php /tmp/ogp-register-agent.php 2>&1 | tee -a "$LOG_FILE" || \
        warn "Could not auto-register agent. Add it manually in Administration → Servers."

    rm -f /tmp/ogp-register-agent.php
    ok "Agent registration attempted."
}

setup_ogp_mysql_host() {
    [[ "$SETUP_MYSQL_HOST" == "yes" ]] || { log "Skipping OGP MySQL host."; return; }

    log "Registering local MariaDB in OGP MySQL Admin..."

    cat > /tmp/ogp-mysql-host.php <<PHP
<?php
chdir('${PANEL_DIR}');
require_once 'includes/config.inc.php';
require_once 'includes/database.php';
require_once 'includes/database_mysqli.php';
require_once 'modules/mysql/mysqli_database.php';

\$name = getenv('OGP_MYSQL_HOST_NAME') ?: 'Local MariaDB';
\$ip = getenv('OGP_MYSQL_HOST_IP') ?: 'localhost';
\$port = (int)(getenv('OGP_MYSQL_PORT') ?: 3306);
\$root_pass = getenv('OGP_MYSQL_ROOT_PASS') ?: '';

\$modDb = new MySQLModuleDatabase();
if (\$modDb->connect(\$db_host, \$db_user, \$db_pass, \$db_name, \$table_prefix) !== true) {
    fwrite(STDERR, "Could not connect to OGP panel database\n");
    exit(1);
}

\$servers = \$modDb->getMysqlServers();
if (is_array(\$servers)) {
    foreach (\$servers as \$row) {
        if (\$row['mysql_ip'] === \$ip && (int)\$row['mysql_port'] === \$port) {
            echo "exists id={\$row['mysql_server_id']}\n";
            exit(0);
        }
    }
}

\$id = \$modDb->addMysqlServer(0, \$name, \$ip, \$port, \$root_pass, 'ALL');
if (!\$id) {
    fwrite(STDERR, "Failed to add MySQL host\n");
    exit(1);
}
echo "added id={\$id}\n";
PHP

    OGP_MYSQL_HOST_NAME="$MYSQL_HOST_NAME" \
    OGP_MYSQL_HOST_IP="$MYSQL_HOST_IP" \
    OGP_MYSQL_PORT="$MYSQL_PORT" \
    OGP_MYSQL_ROOT_PASS="$PASSWORD" \
        php /tmp/ogp-mysql-host.php 2>&1 | tee -a "$LOG_FILE" || \
        warn "Could not register MySQL host. Add it manually under MySQL Admin."

    rm -f /tmp/ogp-mysql-host.php
    ok "MySQL Admin: http://${FQDN}/home.php?m=mysql&p=mysql_admin"
}

setup_phpmyadmin() {
    [[ "$INSTALL_PHPMYADMIN" == "yes" ]] || { log "Skipping phpMyAdmin."; return; }

    log "Installing phpMyAdmin..."

    export DEBIAN_FRONTEND=noninteractive
    debconf-set-selections <<'EOF'
phpmyadmin phpmyadmin/dbconfig-install boolean false
phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2
EOF

    apt-get install -y -qq --no-install-recommends phpmyadmin php-mbstring php-zip php-gd

    if [[ -f /etc/phpmyadmin/config.inc.php ]]; then
        local blowfish
        blowfish=$(openssl rand -base64 32 | tr -d '\n/')
        PMA_BLOWFISH="$blowfish" php <<'PHP'
<?php
$f = '/etc/phpmyadmin/config.inc.php';
$c = file_get_contents($f);
$b = getenv('PMA_BLOWFISH');
$c = preg_replace(
    "/\\$cfg\\['blowfish_secret'\\]\\s*=\\s*'[^']*';/",
    "\$cfg['blowfish_secret'] = '" . addslashes($b) . "';",
    $c,
    1
);
file_put_contents($f, $c);
PHP
    fi

    cat > /etc/phpmyadmin/conf.d/ogp-local.php <<'PHP'
<?php
$i = 1;
$cfg['Servers'][$i]['auth_type'] = 'cookie';
$cfg['Servers'][$i]['host'] = 'localhost';
$cfg['Servers'][$i]['connect_type'] = 'socket';
$cfg['Servers'][$i]['socket'] = '/run/mysqld/mysqld.sock';
$cfg['Servers'][$i]['compress'] = false;
$cfg['Servers'][$i]['AllowNoPassword'] = false;
$cfg['Servers'][$i]['AllowRoot'] = true;
PHP

    a2disconf ogp-phpmyadmin-auth 2>/dev/null || true
    rm -f /etc/apache2/conf-available/ogp-phpmyadmin-auth.conf /etc/apache2/.phpmyadmin
    a2enconf phpmyadmin 2>/dev/null || true
    apache2ctl configtest
    systemctl reload apache2

    ok "phpMyAdmin: http://${FQDN}/phpmyadmin/"
}

setup_firewall() {
    [[ "$CONFIGURE_FIREWALL" == "yes" ]] || return
    command -v ufw &>/dev/null || return

    log "Configuring UFW..."
    ufw --force enable 2>/dev/null || true
    ufw allow 22/tcp  2>/dev/null || true
    ufw allow 80/tcp  2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw allow "${AGENT_PORT}/tcp" 2>/dev/null || true
    ufw allow "${FTP_PORT}/tcp" 2>/dev/null || true
    ufw allow 27015:27030/tcp 2>/dev/null || true
    ufw allow 27015:27030/udp 2>/dev/null || true
    ufw allow 25565:25575/tcp 2>/dev/null || true
    ok "UFW configured."
}

setup_swap() {
    [[ "$INSTALL_SWAP" == "yes" ]] || return
    [[ -f /swapfile ]] && return

    log "Creating ${SWAP_SIZE} swap file..."
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap enabled (${SWAP_SIZE})."
}

save_credentials() {
    log "Saving credentials to ${CREDENTIALS_FILE}..."

    cat > "$CREDENTIALS_FILE" <<EOF
Open Game Panel Installation Credentials
========================================
Generated: $(date -Iseconds)

Unified Password: ${PASSWORD}
Encryption Key:   ${ENCRYPTION_KEY}  (max 16 chars; used by OGP agent only)

Panel URL:     http://${FQDN}/index.php
Admin User:    ${ADMIN_USER}
Admin Pass:    ${PASSWORD}

Database
--------
Host:      localhost
Database:  ${DB_NAME}
User:      ${DB_USER}
Pass:      ${PASSWORD}
Prefix:    ${TABLE_PREFIX}

Agent
-----
User:          ${AGENT_USER}
Pass:          ${PASSWORD}
Agent Port:    ${AGENT_PORT}
FTP Port:      ${FTP_PORT}
Display IP:    ${DISPLAY_IP}
Use NAT:       ${USE_NAT}
Server Name:   ${SERVER_NAME}

MySQL Admin (game server databases)
-----------------------------------
URL:       http://${FQDN}/home.php?m=mysql&p=mysql_admin
Host name: ${MYSQL_HOST_NAME}
MariaDB:   ${MYSQL_HOST_IP}:${MYSQL_PORT}
Root pass: ${PASSWORD}  (used by OGP to create game DBs)

phpMyAdmin
----------
URL:       http://${FQDN}/phpmyadmin/
MariaDB:   root / ${PASSWORD}

Services:
  apache2: $(systemctl is-active apache2 2>/dev/null || echo unknown)
  mariadb: $(systemctl is-active mariadb 2>/dev/null || echo unknown)
  ogp_agent: $(systemctl is-active ogp_agent 2>/dev/null || echo unknown)

Log: ${LOG_FILE}
EOF

    chmod 600 "$CREDENTIALS_FILE"
    ok "Credentials saved."
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo "============================================================"
    echo " Open Game Panel Automated Installer"
    echo "============================================================"
    echo

    install_dependencies
    setup_mariadb
    install_panel_files
    run_panel_installer
    install_agent
    register_agent
    setup_ogp_mysql_host
    setup_phpmyadmin
    setup_firewall
    setup_swap
    save_credentials

    echo
    echo "============================================================"
    echo " Installation complete!"
    echo "============================================================"
    echo
    echo "  Password (panel/DB/agent user): ${PASSWORD}"
    [[ "$ENCRYPTION_KEY" != "$PASSWORD" ]] && \
        echo "  Agent encryption key:         ${ENCRYPTION_KEY}"
    echo
    echo "  Panel:  http://${FQDN}/index.php"
    echo "  User:   ${ADMIN_USER}"
    echo
    [[ "$INSTALL_AGENT" == "yes" ]] && \
        echo "  Agent:  ${DISPLAY_IP}:${AGENT_PORT} (${SERVER_NAME})"
    [[ "$SETUP_MYSQL_HOST" == "yes" ]] && \
        echo "  MySQL:  http://${FQDN}/home.php?m=mysql&p=mysql_admin"
    [[ "$INSTALL_PHPMYADMIN" == "yes" ]] && \
        echo "  phpMyAdmin: http://${FQDN}/phpmyadmin/"
    echo
    echo "  Details: ${CREDENTIALS_FILE}"
    echo
    echo "  Next: Open cloud firewall for 80, ${AGENT_PORT}, ${FTP_PORT}, game ports"
    echo
}

main "$@"
