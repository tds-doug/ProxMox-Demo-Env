#!/usr/bin/env bash
# guest/base.sh - runs INSIDE the container as root. Installs and configures the
# base stack. Idempotent: safe to re-run. Prints no secrets.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

: "${ADMIN_USER:?}" "${CT_HOSTNAME:?}"
: "${ENABLE_HTTPS:=0}" "${DEMO_DB:=1}"

log() { printf '[guest/base] %s\n' "$*"; }
apt_get() { apt-get -o Dpkg::Options::=--force-confold -o Dpkg::Use-Pty=0 -y -q "$@"; }


# ---- Packages --------------------------------------------------------------
log "apt update/upgrade"
apt_get update
apt_get upgrade

PKGS=(
  openssh-server sudo ca-certificates curl wget git
  apache2 libapache2-mod-php php-cli php-mysql
  mariadb-server
  python3 python3-pip python3-venv
  perl libdbi-perl libwww-perl
  iproute2 iputils-ping dnsutils htop lsof jq unzip nano openssl
)
log "installing ${#PKGS[@]} packages"
apt_get install --no-install-recommends "${PKGS[@]}"

install -d -m 0750 -g www-data /etc/demo-factory
install -d -m 0755 /etc/demo-factory/profiles
touch /etc/demo-factory/profiles/base

# ---- Admin account -----------------------------------------------------------
id -u "$ADMIN_USER" >/dev/null   # created by the host (password never touches this script)
if [[ -n ${ADMIN_SSH_PUBKEY:-} ]]; then
  home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
  install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  grep -qxF "$ADMIN_SSH_PUBKEY" "$home/.ssh/authorized_keys" || echo "$ADMIN_SSH_PUBKEY" >>"$home/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
fi

# ---- Apache --------------------------------------------------------------------
log "configuring Apache"
install -d -m 0755 /var/www/html/demo
rm -f /var/www/html/index.html
cat >/var/www/html/index.php <<'PHP'
<?php
$profiles = array_values(array_diff(@scandir('/etc/demo-factory/profiles') ?: [], ['.', '..']));
sort($profiles);
header('Content-Type: text/html; charset=utf-8');
?><!doctype html>
<html lang="en"><head><meta charset="utf-8"><title><?= htmlspecialchars(gethostname()) ?></title>
<style>body{font:16px system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem}code{background:#eee;padding:.1rem .3rem}</style></head>
<body>
<h1><?= htmlspecialchars(gethostname()) ?></h1>
<p>Tiny Dragon Solutions demonstration environment.</p>
<p>Installed profile(s): <strong><?= htmlspecialchars(implode(', ', $profiles)) ?></strong></p>
<p>Self-tests: <a href="demo/php-test.php">PHP</a> &middot; <a href="demo/db-test.php">PHP + MariaDB</a></p>
</body></html>
PHP
cat >/var/www/html/demo/php-test.php <<'PHP'
<?php header('Content-Type: text/plain'); echo "PHP-OK ", PHP_VERSION, "\n";
PHP
cat >/var/www/html/demo/db-test.php <<'PHP'
<?php
header('Content-Type: text/plain');
$cfg = @parse_ini_file('/etc/demo-factory/db.cnf');
if (!$cfg) { http_response_code(503); echo "DB-SKIP demo database not configured\n"; exit; }
mysqli_report(MYSQLI_REPORT_OFF);
$db = @new mysqli('localhost', $cfg['user'], $cfg['password'], $cfg['database']);
if ($db->connect_errno) { http_response_code(500); echo "DB-FAIL connection error\n"; exit; }
$r = $db->query('SELECT COUNT(*) AS n FROM greetings');
echo $r ? "DB-OK rows=" . $r->fetch_assoc()['n'] . "\n" : "DB-FAIL query error\n";
PHP
chmod -R go-w /var/www/html
a2enmod -q headers >/dev/null
a2dissite -q 000-default >/dev/null 2>&1 || true
cat >/etc/apache2/sites-available/demo.conf <<'CONF'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    DirectoryIndex index.php index.html
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
CONF
a2ensite -q demo >/dev/null
printf 'ServerName %s\n' "$CT_HOSTNAME" >/etc/apache2/conf-available/servername.conf
a2enconf -q servername >/dev/null

if [[ $ENABLE_HTTPS == 1 ]]; then
  log "enabling optional HTTPS (self-signed, no redirect)"
  a2enmod -q ssl >/dev/null
  install -d -m 0750 /etc/ssl/demo-factory
  if [[ ! -s /etc/ssl/demo-factory/server.key ]]; then
    openssl req -x509 -newkey rsa:3072 -nodes -days 825 -subj "/CN=$CT_HOSTNAME" \
      -addext "subjectAltName=DNS:$CT_HOSTNAME" -addext "basicConstraints=critical,CA:FALSE" \
      -keyout /etc/ssl/demo-factory/server.key -out /etc/ssl/demo-factory/server.crt 2>/dev/null
    chmod 600 /etc/ssl/demo-factory/server.key
  fi
  cat >/etc/apache2/sites-available/demo-ssl.conf <<'CONF'
<VirtualHost *:443>
    DocumentRoot /var/www/html
    DirectoryIndex index.php index.html
    SSLEngine on
    SSLCertificateFile /etc/ssl/demo-factory/server.crt
    SSLCertificateKeyFile /etc/ssl/demo-factory/server.key
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
CONF
  a2ensite -q demo-ssl >/dev/null
fi

# ---- MariaDB ------------------------------------------------------------------
log "configuring MariaDB"
cat >/etc/mysql/mariadb.conf.d/99-demo-factory.cnf <<'CONF'
# Managed by proxmox-demo-factory
[mysqld]
bind-address            = 127.0.0.1
skip-name-resolve
local-infile            = 0
innodb_buffer_pool_size = 256M
max_connections         = 50
CONF
systemctl enable mariadb >/dev/null 2>&1
systemctl restart mariadb

if [[ $DEMO_DB == 1 ]]; then
  if [[ ! -s /etc/demo-factory/db.cnf ]]; then
    log "creating demo database and restricted account"
    pw=$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24)
    # SQL arrives on stdin: the password is never in an argument list.
    mariadb --batch <<SQL
CREATE DATABASE IF NOT EXISTS demo CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS 'demo_app'@'localhost' IDENTIFIED BY '$pw';
ALTER USER 'demo_app'@'localhost' IDENTIFIED BY '$pw';
GRANT SELECT, INSERT, UPDATE, DELETE ON demo.* TO 'demo_app'@'localhost';
CREATE TABLE IF NOT EXISTS demo.greetings (id INT AUTO_INCREMENT PRIMARY KEY, message VARCHAR(100) NOT NULL);
INSERT INTO demo.greetings (message) SELECT 'Hello from MariaDB' WHERE NOT EXISTS (SELECT 1 FROM demo.greetings);
FLUSH PRIVILEGES;
SQL
    umask 027
    printf 'user=demo_app\npassword=%s\ndatabase=demo\n' "$pw" >/etc/demo-factory/db.cnf
    chown root:www-data /etc/demo-factory/db.cnf
    chmod 640 /etc/demo-factory/db.cnf
    unset pw
  else
    log "demo database already provisioned; leaving data and credentials untouched"
  fi
fi

# ---- Services ------------------------------------------------------------------
apachectl configtest
systemctl enable apache2 ssh >/dev/null 2>&1
systemctl restart apache2

for svc in apache2 mariadb ssh; do
  if ! systemctl is-active --quiet "$svc"; then
    echo "ERROR: $svc failed to start" >&2
    journalctl -u "$svc" -n 15 --no-pager >&2 || true
    echo "HINT: 'status=226/NAMESPACE' errors mean systemd sandboxing needs CT_NESTING=1 (docs/troubleshooting.md)." >&2
    exit 1
  fi
done
log "base stack complete"
