#!/bin/bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Uruchom jako root: sudo ./install.sh"
  exit 1
fi

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== [0/7] Wymagane katalogi ==="
install -d /var/www/html
install -d /usr/lib/cgi-bin
install -d /etc/orangepi-router
install -d /usr/local/orangepi-router
install -d /usr/local/orangepi-router/scripts

echo "=== [1/7] Deploy WWW ==="
rm -rf /var/www/html/*
cp -r "${BASE_DIR}/www/html/." /var/www/html/
# jeśli ktoś wrzucił web_app.html zamiast index.html
if [ -f /var/www/html/web_app.html ] && [ ! -f /var/www/html/index.html ]; then
  mv /var/www/html/web_app.html /var/www/html/index.html
fi

echo "=== [2/7] Deploy backend CGI ==="
cp "${BASE_DIR}/cgi-bin/router_api.py" /usr/lib/cgi-bin/router_api.py
sed -i 's/\r$//' /usr/lib/cgi-bin/router_api.py
chmod 755 /usr/lib/cgi-bin/router_api.py

echo "=== [3/7] Konfiguracja (jeden plik prawdy) ==="
cp "${BASE_DIR}/config.inc" /etc/orangepi-router/config.inc
# żeby Twoje istniejące scripts/*.sh (source ../config.inc) widziały to samo:
ln -sf /etc/orangepi-router/config.inc /usr/local/orangepi-router/config.inc

# Twoje wymagane prawa do odczytu przez panel:
chgrp www-data /etc/orangepi-router/config.inc
chmod 660 /etc/orangepi-router/config.inc
chmod 755 /etc/orangepi-router

echo "=== [4/7] Włączenie IP forwarding (trwale + runtime) ==="
cat > /etc/sysctl.d/99-orangepi-router.conf <<EOF
net.ipv4.ip_forward=1
EOF
# runtime (to o co prosisz)
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# trwałe załadowanie (po restarcie też będzie 1)
sysctl --system >/dev/null || true

echo "=== [5/7] Instalacja/Deploy Twoich skryptów systemowych (bez zmian treści) ==="
cp -r "${BASE_DIR}/scripts/." /usr/local/orangepi-router/scripts/
chmod +x /usr/local/orangepi-router/scripts/*.sh

echo "=== [6/7] Lighttpd: CGI + Python + index.html ==="
# Włącz CGI moduł
lighty-enable-mod cgi >/dev/null 2>&1 || true

# Konfiguracja CGI dla Python w lighttpd
cat > /etc/lighttpd/conf-available/10-router-cgi.conf <<'EOF'
server.modules += ( "mod_alias", "mod_cgi" )
alias.url += ( "/cgi-bin/" => "/usr/lib/cgi-bin/" )

$HTTP["url"] =~ "^/cgi-bin/" {
    cgi.assign = ( ".py" => "/usr/bin/python3" )
}
EOF

lighty-enable-mod 10-router-cgi >/dev/null 2>&1 || true

# Upewnij się, że index.html jest indexem
# (nie nadpisujemy całego lighttpd.conf – tylko dopinamy, jeśli trzeba)
if ! grep -q 'server.indexfiles' /etc/lighttpd/lighttpd.conf 2>/dev/null; then
  echo 'server.indexfiles = ( "index.html", "index.htm" )' >> /etc/lighttpd/lighttpd.conf
else
  sed -i 's/server\.indexfiles.*/server.indexfiles = ( "index.html", "index.htm" )/g' /etc/lighttpd/lighttpd.conf || true
fi

echo "=== [7/7] Sudoers dla backendu (zapis config + restart hostapd/dnsmasq) ==="
cat > /etc/sudoers.d/orangepi-router-web <<'EOF'
# zapis configu bez pytania o hasło
www-data ALL=(root) NOPASSWD: /usr/bin/tee /etc/orangepi-router/config.inc
www-data ALL=(root) NOPASSWD: /bin/cp /etc/orangepi-router/config.inc /usr/local/orangepi-router/config.inc

# restart usług po zmianach
www-data ALL=(root) NOPASSWD: /usr/bin/systemctl restart hostapd
www-data ALL=(root) NOPASSWD: /usr/bin/systemctl restart dnsmasq
EOF
chmod 440 /etc/sudoers.d/orangepi-router-web

# restart WWW po Twoich wymaganych komendach
systemctl restart lighttpd

echo "=== Uruchamiam Twoje istniejące skrypty (jeśli chcesz, możesz to wyłączyć) ==="
# Nie zmieniamy ich – tylko odpalamy
bash /usr/local/orangepi-router/scripts/interfaces_setup.sh || true
bash /usr/local/orangepi-router/scripts/dnsmasq.sh || true
bash /usr/local/orangepi-router/scripts/hostapd.sh || true
bash /usr/local/orangepi-router/scripts/iptables.sh || true

IP=$(hostname -I | awk '{print $1}')
echo "-------------------------------------------------"
echo "GOTOWE."
echo "Panel: http://${IP}/"
echo "API:   http://${IP}/cgi-bin/router_api.py"
echo "-------------------------------------------------"
