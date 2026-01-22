#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Uruchom jako root: sudo ./install.sh"
  exit 1
fi

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== [1/5] Kopiowanie backendu i strony ==="

# WWW
rm -rf /var/www/html/*
cp -r "$BASE_DIR/www/html/." /var/www/html/

# Backend CGI
install -d /usr/lib/cgi-bin
cp "$BASE_DIR/cgi-bin/router_api.py" /usr/lib/cgi-bin/router_api.py
sed -i 's/\r$//' /usr/lib/cgi-bin/router_api.py
chmod 755 /usr/lib/cgi-bin/router_api.py

echo "=== [2/5] Konfiguracja katalogu i config.inc ==="

# Config jako źródło prawdy
install -d /etc/orangepi-router
cp "$BASE_DIR/config.inc" /etc/orangepi-router/config.inc

# UPRAWNIENIA:
# - katalog 775 (www-data musi móc tworzyć pliki tmp podczas atomowego zapisu)
# - plik 660 (www-data czyta/pisze, root właściciel)
chown root:www-data /etc/orangepi-router
chmod 775 /etc/orangepi-router

chown root:www-data /etc/orangepi-router/config.inc
chmod 660 /etc/orangepi-router/config.inc

echo "=== [3/5] Skrypty systemowe ==="

install -d /usr/local/orangepi-router/scripts
cp -r "$BASE_DIR/scripts/." /usr/local/orangepi-router/scripts/
chmod +x /usr/local/orangepi-router/scripts/*.sh

# Upewniamy się, że skrypty biorą config z /etc/orangepi-router/config.inc
# (wąska podmiana tylko typowej linii z repo)
for f in /usr/local/orangepi-router/scripts/*.sh; do
  sed -i 's|source $(dirname "$0")/../config.inc|source /etc/orangepi-router/config.inc|g' "$f"
  sed -i 's|source \$(dirname "\$0")/../config.inc|source /etc/orangepi-router/config.inc|g' "$f"
done

echo "=== [4/5] Sudoers dla backendu ==="

cat > /etc/sudoers.d/orangepi-router <<'EOF'
www-data ALL=(root) NOPASSWD: /usr/local/orangepi-router/scripts/hostapd.sh
www-data ALL=(root) NOPASSWD: /usr/local/orangepi-router/scripts/dnsmasq.sh
www-data ALL=(root) NOPASSWD: /usr/local/orangepi-router/scripts/interfaces_setup.sh
www-data ALL=(root) NOPASSWD: /usr/local/orangepi-router/scripts/iptables.sh
EOF

chmod 440 /etc/sudoers.d/orangepi-router

echo "=== [5/5] Uruchomienie konfiguracji (raz) ==="

# KOLEJNOŚĆ MA ZNACZENIE
bash /usr/local/orangepi-router/scripts/interfaces_setup.sh || true
bash /usr/local/orangepi-router/scripts/iptables.sh || true
bash /usr/local/orangepi-router/scripts/dnsmasq.sh || true
bash /usr/local/orangepi-router/scripts/hostapd.sh || true

systemctl restart lighttpd

IP=$(hostname -I | awk '{print $1}')
echo "-------------------------------------------------"
echo "GOTOWE."
echo "Panel: http://${IP}/"
echo "-------------------------------------------------"
