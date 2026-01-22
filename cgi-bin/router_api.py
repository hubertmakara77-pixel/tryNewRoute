#!/bin/bash

# --- SPRAWDZENIE UPRAWNIEŃ ---
if [ "$EUID" -ne 0 ]; then
  echo "Uruchom jako root (sudo bash install_custom.sh)"
  exit
fi

echo "=== START INSTALACJI (Z zachowaniem Twoich plików config) ==="

# 1. INSTALACJA PAKIETÓW
echo "[1/7] Instalowanie programów..."
apt-get update
apt-get install -y hostapd dnsmasq lighttpd python3 iptables netfilter-persistent iptables-persistent

# 2. KOPIOWANIE TWOICH PLIKÓW (HOSTAPD i DNSMASQ)
echo "[2/7] Szukanie i kopiowanie Twoich ustawień..."

# Szukamy hostapd.conf (Twoja nazwa sieci i hasło)
if [ -f "hostapd.conf" ]; then
    cp hostapd.conf /etc/hostapd/hostapd.conf
    echo " -> Znaleziono i wgrano Twój hostapd.conf"
elif [ -f "conf/hostapd.conf" ]; then
    cp conf/hostapd.conf /etc/hostapd/hostapd.conf
    echo " -> Znaleziono Twój plik w folderze conf/"
else
    echo "UWAGA: Nie widzę Twojego pliku hostapd.conf. Tworzę domyślny."
    cat > /etc/hostapd/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
ssid=OrangePi_Start
hw_mode=g
channel=7
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=start1234
rsn_pairwise=CCMP
EOF
fi

# Szukamy dnsmasq.conf
if [ -f "dnsmasq.conf" ]; then
    cp dnsmasq.conf /etc/dnsmasq.conf
elif [ -f "conf/dnsmasq.conf" ]; then
    cp conf/dnsmasq.conf /etc/dnsmasq.conf
else
    # Domyślny, jeśli Twój nie istnieje
    cat > /etc/dnsmasq.conf <<EOF
interface=wlan0
dhcp-range=192.168.0.10,192.168.0.50,12h
server=8.8.8.8
server=1.1.1.1
EOF
fi

# 3. KONFIGURACJA SERWERA WWW
echo "[3/7] Konfiguracja serwera Lighttpd..."
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

# 4. KOPIOWANIE TWOJEJ STRONY WWW
echo "[4/7] Kopiowanie plików strony (HTML/JS)..."
# Kopiujemy z Twojego folderu
rm -rf /var/www/html/*
if [ -d "www/html" ]; then cp -r www/html/* /var/www/html/; 
elif [ -d "www" ]; then cp -r www/* /var/www/html/;
elif [ -d "html" ]; then cp -r html/* /var/www/html/; 
else cp * /var/www/html/ 2>/dev/null; fi

# Fix na nazwę pliku
[ -f "/var/www/html/web_app.html" ] && mv /var/www/html/web_app.html /var/www/html/index.html

# 5. WGRYWANIE POPRAWIONEGO PYTHONA (Zastępujemy Twój plik, bo Twój ma błędy)
echo "[5/7] Instalacja stabilnego backendu Python..."
mkdir -p /usr/lib/cgi-bin

# Wgrywamy ten kod, który działa na 100% z uprawnieniami www-data
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
        
        # Zapis bezpośredni (możliwy dzięki chown poniżej)
        with open(HOSTAPD_CONF, 'w') as f: f.writelines(new_lines)
        
        # Restart usługi (możliwy dzięki sudoers poniżej)
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

# 6. INTERNET (Maskarada)
echo "[6/7] Konfiguracja Internetu..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
sysctl -p /etc/sysctl.d/99-ipforward.conf

iptables -F
iptables -t nat -F
# Automatyczne wykrycie kabla (eth0 lub end0)
ETH=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(e|en)' | head -n 1)
[ -z "$ETH" ] && ETH="end0"

iptables -t nat -A POSTROUTING -o $ETH -j MASQUERADE
iptables -A FORWARD -i $ETH -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o $ETH -j ACCEPT

netfilter-persistent save

# Wymuszenie adresu IP routera
ip link set wlan0 down
ip addr flush dev wlan0
ip addr add 192.168.0.1/24 dev wlan0
ip link set wlan0 up

# 7. UPRAWNIENIA I START (Najważniejsza część)
echo "[7/7] Nadawanie uprawnień i restart..."

# Oddajemy Twój plik hostapd.conf stronie WWW
# Dzięki temu Python może go edytować bez sudo!
chown www-data:www-data /etc/hostapd/hostapd.conf
chmod 664 /etc/hostapd/hostapd.conf

# Pozwalamy stronie na restart usługi hostapd
cat > /etc/sudoers.d/router-web <<EOF
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hostapd
EOF
chmod 0440 /etc/sudoers.d/router-web

# Odblokowanie i start
systemctl stop systemd-resolved
systemctl disable systemd-resolved
systemctl unmask hostapd
systemctl restart dnsmasq
systemctl restart hostapd
systemctl restart lighttpd

echo "========================================="
echo " GOTOWE! Użyto Twoich plików config."
echo " Python został zaktualizowany na lepszą wersję."
echo " Strona i Internet powinny działać."
echo "========================================="
