#!/bin/bash

# --- 0. SPRAWDZENIE ROOT ---
if [ ! "$UID" -eq 0 ]; then
    echo "URUCHOM JAKO ROOT: sudo bash install_ultra.sh"
    exit 1
fi

echo "--- START: INSTALACJA ULTRA (Wszystko w jednym) ---"

# --- 1. INSTALACJA WSZYSTKICH PAKIETÓW ---
echo "[1/9] Instalacja pakietów (WWW, Python, Sieć, Firewall)..."
apt-get update
# Instalujemy wszystko, włącznie z narzędziami do trwałego zapisu firewalla
apt-get install -y lighttpd python3 hostapd dnsmasq git iptables netfilter-persistent iptables-persistent dos2unix

# --- 2. USUWANIE STARYCH KONFLIKTÓW ---
echo "[2/9] Usuwanie błędnych skryptów z repozytorium..."
rm -f scripts/lighttpd.sh
rm -f scripts/install_web.sh

# --- 3. KONFIGURACJA SERWERA WWW (Port 80) ---
echo "[3/9] Konfiguracja Lighttpd..."
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

include_shell "/usr/share/lighttpd/create-mime.conf.pl"
index-file.names        = ( "index.html" )
static-file.exclude-extensions = ( ".php", ".pl", ".fcgi" )
cgi.assign = ( ".py" => "/usr/bin/python3" )
include "/etc/lighttpd/conf-enabled/*.conf"
EOF

lighty-enable-mod cgi

# --- 4. WGRYWANIE STRONY WWW ---
echo "[4/9] Kopiowanie plików strony..."
rm -rf /var/www/html/*
if [ -d "www/html" ]; then cp -r www/html/* /var/www/html/;
elif [ -d "www" ]; then cp -r www/* /var/www/html/;
elif [ -d "html" ]; then cp -r html/* /var/www/html/; fi

[ -f "/var/www/html/web_app.html" ] && mv /var/www/html/web_app.html /var/www/html/index.html
rm -f /var/www/html/index.lighttpd.html

# --- 5. GENEROWANIE POPRAWNEGO PYTHON API (Wersja 2025) ---
echo "[5/9] Tworzenie backendu Python (bez błędu CGI)..."
mkdir -p /usr/lib/cgi-bin/

# Tworzymy plik Pythona od zera, żeby uniknąć problemów z Windows/Linux
cat > /usr/lib/cgi-bin/router_api.py << 'PYTHON_EOF'
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
    except:
        return ""

def get_config():
    data = {'dhcp_start': '192.168.0.10'}
    data['ip_address'] = run_command("hostname -I | awk '{print $1}'") or "0.0.0.0"
    
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

def save_wifi(ssid, password):
    if not ssid: return {"status": "error", "message": "No SSID"}
    try:
        # Zapis bezpośredni (uprawnienia załatwione w bashu)
        lines = ["interface=wlan0\n", "hw_mode=g\n", "channel=7\n", "wpa=2\n", 
                 "wpa_key_mgmt=WPA-PSK\n", "rsn_pairwise=CCMP\n"]
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f:
                lines = f.readlines()
        
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
    except Exception as e:
        return {"status": "error", "message": str(e)}

print("Content-Type: application/json\n")
if os.environ.get("REQUEST_METHOD") == "GET":
    print(json.dumps(get_config()))
elif os.environ.get("REQUEST_METHOD") == "POST":
    try:
        ln = int(os.environ.get('CONTENT_LENGTH', 0))
        if ln > 0:
            d = json.loads(sys.stdin.read(ln))
            if d.get('action') == 'save_wifi':
                print(json.dumps(save_wifi(d.get('ssid'), d.get('password'))))
    except: print(json.dumps({"status": "error"}))
PYTHON_EOF

chmod +x /usr/lib/cgi-bin/router_api.py

# --- 6. UPRAWNIENIA I WŁAŚCICIEL (Żeby Python mógł zapisywać) ---
echo "[6/9] Nadawanie uprawnień..."
mkdir -p /etc/hostapd
touch /etc/hostapd/hostapd.conf
# Kluczowy moment: dajemy plik configu we władanie strony WWW
chown www-data:www-data /etc/hostapd/hostapd.conf
chmod 664 /etc/hostapd/hostapd.conf

cat > /etc/sudoers.d/router-web-ui << EOF
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hostapd
www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart dnsmasq
www-data ALL=(ALL) NOPASSWD: /usr/bin/ip
EOF
chmod 0440 /etc/sudoers.d/router-web-ui
chown -R www-data:www-data /var/www/html

# --- 7. FIREWALL I INTERNET (To o co prosiłeś!) ---
echo "[7/9] Konfiguracja Firewalla i Internetu (Automatyczna)..."

# Włączamy przekazywanie pakietów (Internet)
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-router.conf
sysctl -p /etc/sysctl.d/99-router.conf

# Czyścimy stare reguły
iptables -F
iptables -t nat -F

# Ustawiamy Maskaradę (Internet z kabla end0/eth0 idzie do WiFi)
# Próbujemy wykryć interfejs, zazwyczaj end0 na Orange Pi Zero 3
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$IFACE" ]; then IFACE="end0"; fi
echo "   -> Wykryto interfejs internetowy: $IFACE"

iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE

# Otwieramy Port 80 (WWW), 53 (DNS), 67 (DHCP)
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
iptables -A INPUT -i wlan0 -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i wlan0 -p udp --dport 67 -j ACCEPT

# ZAPISUJEMY TO NA STAŁE
netfilter-persistent save
systemctl enable netfilter-persistent

# --- 8. URUCHOMIENIE ORYGINALNYCH SKRYPTÓW (Dla WiFi) ---
echo "[8/9] Konfiguracja Access Pointa..."
# Naprawiamy literówkę w network_setup.sh jeśli istnieje
if [ -f "scripts/network_setup.sh" ]; then
    sed -i 's/If \[/if \[/g' scripts/network_setup.sh
fi

if [ -d "scripts" ]; then
    chmod +x scripts/*.sh
    # Uruchamiamy setup interfejsów i AP, ale firewall już mamy gotowy
    ./scripts/interfaces_setup.sh 2>/dev/null
    ./scripts/hostapd_setup.sh 2>/dev/null
    ./scripts/dnsmasq_setup.sh 2>/dev/null
fi

# --- 9. FINAŁ ---
echo "[9/9] Restart usług..."
systemctl unmask lighttpd
systemctl restart lighttpd
systemctl restart hostapd
systemctl restart dnsmasq

echo "======================================================"
echo " SUKCES ULTRA! Wszystko zainstalowane."
echo " 1. Internet (Maskarada) jest włączony i zapisany."
echo " 2. Strona WWW działa na porcie 80."
echo " 3. Python backend jest naprawiony."
echo "======================================================"
