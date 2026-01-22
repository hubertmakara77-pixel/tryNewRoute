#!/bin/bash
set -e

chmod +x scripts/*.sh

if [ "$EUID" -ne 0 ]; then
  echo "Please run script as root: sudo ./install.sh"
  exit 1
fi

echo "[1/4] Pakiety (najpierw, póki działa internet)"
apt-get update
apt-get install -y lighttpd python3 hostapd dnsmasq iptables iptables-persistent netfilter-persistent

echo "[2/4] WWW + CGI + backend"
lighty-enable-mod cgi >/dev/null 2>&1 || true

rm -rf /var/www/html/*
if [ -d "www/html" ]; then
  cp -r www/html/. /var/www/html/
elif [ -d "html" ]; then
  cp -r html/. /var/www/html/
else
  echo "Brak katalogu strony (www/html ani html)"
  exit 1
fi

# Jeśli masz web_app.html -> index.html
if [ -f "/var/www/html/web_app.html" ]; then
  mv /var/www/html/web_app.html /var/www/html/index.html
fi
rm -f /var/www/html/index.lighttpd.html

mkdir -p /usr/lib/cgi-bin
cp cgi-bin/router_api.py /usr/lib/cgi-bin/router_api.py
sed -i 's/\r$//' /usr/lib/cgi-bin/router_api.py
chmod 755 /usr/lib/cgi-bin/router_api.py

# CGI alias + python handler
cat > /etc/lighttpd/conf-available/10-router-cgi.conf <<'EOF'
server.modules += ( "mod_alias", "mod_cgi" )
alias.url += ( "/cgi-bin/" => "/usr/lib/cgi-bin/" )
$HTTP["url"] =~ "^/cgi-bin/" {
    cgi.assign = ( ".py" => "/usr/bin/python3" )
}
EOF
lighty-enable-mod 10-router-cgi >/dev/null 2>&1 || true

systemctl restart lighttpd

# config.inc jako źródło prawdy
mkdir -p /etc/orangepi-router
cp -f config.inc /etc/orangepi-router/config.inc
chmod 600 /etc/orangepi-router/config.inc

echo "[3/4] Sudoers (backend odpala TYLKO skrypty)"
cat > /etc/sudoers.d/orangepi-router <<'EOF'
www-data ALL=(root) NOPASSWD: /bin/bash /usr/local/orangepi-router/scripts/hostapd.sh
www-data ALL=(root) NOPASSWD: /bin/bash /usr/local/orangepi-router/scripts/dnsmasq.sh
www-data ALL=(root) NOPASSWD: /bin/bash /usr/local/orangepi-router/scripts/interfaces_setup.sh
www-data ALL=(root) NOPASSWD: /bin/bash /usr/local/orangepi-router/scripts/iptables.sh
EOF
chmod 0440 /etc/sudoers.d/orangepi-router

echo "[4/4] Skrypty (dopiero teraz)"
# kopiujemy scripts na stałą ścieżkę, żeby CGI nie zależało od katalogu repo
mkdir -p /usr/local/orangepi-router/scripts
cp -r scripts/. /usr/local/orangepi-router/scripts/
chmod +x /usr/local/orangepi-router/scripts/*.sh

# w skryptach podmieniamy source config.inc na stałą ścieżkę:
for f in /usr/local/orangepi-router/scripts/*.sh; do
  sed -i 's|source $(dirname "$0")/../config.inc|source /etc/orangepi-router/config.inc|g' "$f"
done

# I tu zostaje Twoja idea uruchamiania, ale:
# - jawnie pomijamy skrypty konfliktujące/popsute
# - uruchamiamy w sensownej kolejności
ORDER=(
  "interfaces_setup.sh"
  "iptables.sh"
  "dnsmasq.sh"
  "hostapd.sh"
)

for name in "${ORDER[@]}"; do
  script="/usr/local/orangepi-router/scripts/$name"
  if [ -f "$script" ]; then
    echo " -> Uruchamiam: $script"
    bash "$script" || echo " !!! $name zwrócił błąd (możliwe na VM/brak wlan0)"
  fi
done

IP="$(hostname -I | awk '{print $1}')"
echo "OK. Panel: http://${IP}/"
echo "API:   http://${IP}/cgi-bin/router_api.py"
