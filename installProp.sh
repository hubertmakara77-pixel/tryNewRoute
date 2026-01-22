#!/bin/bash

# --- SPRAWDZENIE UPRAWNIEŃ ---
if [ "$EUID" -ne 0 ]; then
  echo "Uruchom jako root (sudo bash install_custom.sh)"
  exit
fi

echo "=== START INSTALACJI (Z zachowaniem Twoich plików) ==="

# 1. INSTALACJA PAKIETÓW (Wymagane, żeby system działał)
echo "[1/7] Instalowanie programów..."
apt-get update
apt-get install -y hostapd dnsmasq lighttpd python3 iptables netfilter-persistent iptables-persistent

# 2. KOPIOWANIE TWOICH PLIKÓW KONFIGURACYJNYCH
echo "[2/7] Kopiowanie Twoich ustawień..."

# Szukamy hostapd.conf u Ciebie w folderze i kopiujemy
if [ -f "hostapd.conf" ]; then
    cp hostapd.conf /etc/hostapd/hostapd.conf
    echo " -> Skopiowano Twój hostapd.conf (luzem)"
elif [ -f "conf/hostapd.conf" ]; then
    cp conf/hostapd.conf /etc/hostapd/hostapd.conf
    echo " -> Skopiowano Twój hostapd.conf (z folderu conf)"
elif [ -f "scripts/hostapd.conf" ]; then
    cp scripts/hostapd.conf /etc/hostapd/hostapd.conf
    echo " -> Skopiowano Twój hostapd.conf (z folderu scripts)"
else
    echo "UWAGA: Nie znaleziono Twojego pliku hostapd.conf! Zostawiam ten, który jest w systemie."
fi

# Szukamy dnsmasq.conf
if [ -f "dnsmasq.conf" ]; then
    cp dnsmasq.conf /etc/dnsmasq.conf
    echo " -> Skopiowano Twój dnsmasq.conf"
elif [ -f "conf/dnsmasq.conf" ]; then
    cp conf/dnsmasq.conf /etc/dnsmasq.conf
    echo " -> Skopiowano Twój dnsmasq.conf (z folderu conf)"
fi

# 3. KONFIGURACJA LIGHTTPD (Techniczna - musi być, żeby Python działał)
echo "[3/7] Konfiguracja serwera WWW (CGI)..."
systemctl stop lighttpd
cat > /etc/lighttpd/lighttpd.conf <<EOF
server.modules = (
    "mod_indexfile", "mod_access", "mod_alias", "mod_redirect", "mod_cgi"
)
server.document-root    = "/var/www/html"
server.upload-dirs      = ( "/var/cache/lighttpd/uploads" )
server.errorlog         = "/var/log/lighttpd/error.log"
server.pid-file         = "/run/lighttpd.pid"
server.username         = "www-data"
server.groupname        = "www-data"
server.port             = 80
index-file.names        = ( "index.html" )
static-file.exclude-extensions = ( ".php", ".pl", ".fcgi" )
cgi.assign = ( ".py" => "/usr/bin/python3" )
include_shell "/usr/share/lighttpd/create-mime.conf.pl"
include "/etc/lighttpd/conf-enabled/*.conf"
EOF
lighty-enable-mod cgi

# 4. KOPIOWANIE STRONY WWW
echo "[4/7] Kopiowanie plików strony..."
# Kopiujemy tylko jeśli są w folderze
if [ -d "www/html" ]; then cp -r www/html/* /var/www/html/; 
elif [ -d "www" ]; then cp -r www/* /var/www/html/;
elif [ -d "html" ]; then cp -r html/* /var/www/html/; fi

[ -f "/var/www/html/web_app.html" ] && mv /var/www/html/web_app.html /var/www/html/index.html

# 5. WGRYWANIE NAPRAWIONEGO PYTHONA (API)
# Ten kod MUSI być wgrany, żeby strona działała, ale on CZYTA Twoje pliki, nie nadpisuje ich.
echo "[5/7] Instalacja backendu Python..."
mkdir -p /usr/lib/cgi-bin

cat > /usr/lib/cgi-bin/router_api.py << 'PYTHONEOF'
#!/usr/bin/env python3
import json
import subprocess
import os
import sys
import re

HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"

def run_command(command):
    try:
        result = subprocess.check_output(command, shell=True, text=True, stderr=subprocess.STDOUT)
        return result.strip()
    except: return ""

def get_current_config():
    data = {'dhcp_start': '192.168.0.10'}
    data['ip_address'] = run_command("hostname -I | awk '{print $1}'") or "192.168.0.1"
    try:
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f:
                content = f.read()
                s = re.search(r'^ssid=(.*)', content, re.MULTILINE)
                p = re.search(r'^wpa_passphrase=(.*)', content, re.MULTILINE)
                data['ssid'] = s.group(1).strip() if s else ""
                data['wifi_pass'] = p.group(1).strip() if p else ""
    except: pass
    return data

def save_wifi_config(ssid, password):
    if not ssid: return {"status": "error", "message": "No SSID"}
    try:
        lines = []
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f: lines = f.readlines()
        
        new_lines = []
        found_s, found_p = False, False
        for line in lines:
            if line.startswith('ssid='):
                new_lines.append(f"ssid={ssid}\n"); found_s = True
            elif line.startswith('wpa_passphrase='):
                new_lines.append(f"wpa_passphrase={password}\n"); found_p = True
            else: new_lines.append(line)
            
        if not found_s: new_lines.append(f"ssid={ssid}\n")
        if not found_p: new_lines.append(f"wpa_passphrase={password}\n")
        
        with open(HOSTAPD_CONF, 'w') as f: f.writelines(new_lines)
        run_command("sudo systemctl restart hostapd")
        return {"status": "success", "message": "Saved"}
    except Exception as e: return {"status": "error", "message": str(e)}

print("Content-Type: application/json\n")
try:
    if os.environ.get("REQUEST_METHOD") == "POST":
        ln = int(os.environ.get('CONTENT_LENGTH', 0))
        if ln > 0:
            d = json.loads(sys.stdin.read(ln))
            if d.get('action') == 'save_wifi':
                print(json.dumps(save_wifi_config(d.get('ssid'), d.get('password'))))
    else: print(json.dumps(get_current_config()))
except: print(json.dumps({"status": "error"}))
PYTHONEOF

chmod +x /usr/lib/cgi-bin/router_api.py

# 6. INTERNET (NAPRAWA POŁĄCZENIA)
echo "[6/7] Konfiguracja Internetu (Maskarada)..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
sysctl -p /etc/sysctl.d/99-ipforward.conf

iptables -F
iptables -t nat -F
# Wykrywanie kabla
ETH=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(e|en)' | head -n 1)
[ -z "$ETH" ] && ETH="end0"

iptables -t nat -A POSTROUTING -o $ETH -j MASQUERADE
iptables -A FORWARD -i $ETH -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o $ETH -j ACCEPT

netfilter-persistent save

# Wymuszenie IP routera
ip link set wlan0 down
ip addr flush dev wlan0
ip addr add 192.168.0.1/24 dev wlan0
ip link set wlan0 up

# 7. UPRAWNIENIA I START
echo "[7/7] Nadawanie uprawnień (chown) i restart..."

# KLUCZOWE: Oddajemy Twój plik stronie WWW, żeby mogła go czytać/edytować
chown www-data:www-data /etc/hostapd/hostapd.conf
chmod 664 /etc/hostapd/hostapd.conf

# Uprawnienia sudo dla WWW
cat > /etc/sudoers.d/router-web <<EOF
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hostapd
EOF
chmod 0440 /etc/sudoers.d/router-web

# Odblokowanie usług
systemctl stop systemd-resolved
systemctl disable systemd-resolved
systemctl unmask hostapd

systemctl restart dnsmasq
systemctl restart hostapd
systemctl restart lighttpd

echo "=== GOTOWE ==="
echo "Użyto Twoich plików konfiguracyjnych."
echo "Internet i strona powinny działać."
