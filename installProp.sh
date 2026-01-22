#!/bin/bash

# Upewnij się, że jesteś rootem
if [ "$EUID" -ne 0 ]; then echo "Uruchom przez sudo!"; exit; fi

echo "=== START NAPRAWY FINALNEJ ==="

# 1. ZDEJMOWANIE BLOKAD (Naprawa błędu "Masked" i "Read-only")
echo "[1/6] Odblokowywanie systemu..."
mount -o remount,rw / 2>/dev/null
# TO NAPRAWIA TWÓJ BŁĄD ZE ZDJĘCIA:
systemctl unmask hostapd
systemctl unmask dnsmasq
systemctl unmask lighttpd

# 2. INSTALACJA PAKIETÓW
echo "[2/6] Sprawdzanie pakietów..."
apt-get update -y
apt-get install -y lighttpd python3 hostapd dnsmasq

# 3. WGRYWANIE BACKENDU PYTHON (Wersja odporna na błędy)
echo "[3/6] Instalacja skryptu Python..."
mkdir -p /usr/lib/cgi-bin

cat > /usr/lib/cgi-bin/router_api.py << 'PYTHONEOF'
#!/usr/bin/env python3
import json, subprocess, os, sys, re

HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"

def run(cmd):
    try: return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.STDOUT).strip()
    except: return ""

def get_conf():
    ip = run("hostname -I | awk '{print $1}'") or "192.168.0.1"
    data = {'ip_address': ip, 'dhcp_start': '192.168.0.10', 'ssid': '', 'wifi_pass': ''}
    try:
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f: c = f.read()
            s = re.search(r'^ssid=(.*)', c, re.MULTILINE)
            p = re.search(r'^wpa_passphrase=(.*)', c, re.MULTILINE)
            data['ssid'] = s.group(1).strip() if s else ""
            data['wifi_pass'] = p.group(1).strip() if p else ""
    except: pass
    return data

def save(ssid, password):
    if not ssid: return {"status": "error", "message": "SSID nie moze byc pusty"}
    
    try:
        # Odczyt
        lines = []
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f: lines = f.readlines()
        
        # Edycja
        new_l = []
        fs, fp = False, False
        for l in lines:
            if l.startswith('ssid='): new_l.append(f"ssid={ssid}\n"); fs=True
            elif l.startswith('wpa_passphrase='): new_l.append(f"wpa_passphrase={password}\n"); fp=True
            else: new_l.append(l)
        if not fs: new_l.append(f"ssid={ssid}\n")
        if not fp: new_l.append(f"wpa_passphrase={password}\n")
        
        # Zapis
        with open(HOSTAPD_CONF, 'w') as f: f.writelines(new_l)
        
        # Restart (bez sudo, bo user www-data będzie miał uprawnienia w sudoers)
        subprocess.check_output("sudo systemctl restart hostapd", shell=True, stderr=subprocess.STDOUT)
        
        return {"status": "success", "message": "Zapisano! Router restartuje sie..."}

    except subprocess.CalledProcessError as e:
        err = e.output if e.output else str(e)
        return {"status": "error", "message": f"Blad restartu WiFi: {err}"}
    except Exception as e:
        return {"status": "error", "message": f"Blad: {str(e)}"}

print("Content-Type: application/json\n")
try:
    if os.environ.get("REQUEST_METHOD") == "POST":
        ln = int(os.environ.get('CONTENT_LENGTH', 0))
        d = json.loads(sys.stdin.read(ln))
        if d.get('action') == 'save_wifi': print(json.dumps(save(d.get('ssid'), d.get('password'))))
    else: print(json.dumps(get_conf()))
except Exception as e: print(json.dumps({"status": "error", "message": str(e)}))
PYTHONEOF

# 4. NAPRAWA UPRAWNIEN (Usuwanie znaków Windowsa i chmod)
echo "[4/6] Naprawa uprawnień plików..."
sed -i 's/\r$//' /usr/lib/cgi-bin/router_api.py
chmod +x /usr/lib/cgi-bin/router_api.py
chown www-data:www-data /usr/lib/cgi-bin/router_api.py

# Plik konfiguracyjny - musi być dostępny do zapisu
touch /etc/hostapd/hostapd.conf
chown www-data:www-data /etc/hostapd/hostapd.conf
chmod 666 /etc/hostapd/hostapd.conf

# 5. ZEZWOLENIE NA RESTART (sudoers)
echo "[5/6] Konfiguracja sudoers..."
rm -f /etc/sudoers.d/router-web
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hostapd" > /etc/sudoers.d/router-web
chmod 0440 /etc/sudoers.d/router-web

# 6. KONFIGURACJA SERWERA WWW
echo "[6/6] Restart usług..."
cat > /etc/lighttpd/lighttpd.conf <<EOF
server.modules = ( "mod_access", "mod_alias", "mod_redirect", "mod_cgi" )
server.document-root = "/var/www/html"
server.port = 80
index-file.names = ( "index.html" )
cgi.assign = ( ".py" => "/usr/bin/python3" )
include_shell "/usr/share/lighttpd/create-mime.conf.pl"
EOF

# Restart wszystkiego (teraz zadziała, bo zrobiliśmy unmask)
systemctl restart lighttpd
systemctl restart dnsmasq
systemctl restart hostapd

echo "========================================="
echo " SUKCES! Blokada 'masked' zdjęta."
echo " Strona powinna teraz zmieniać hasło."
echo "========================================="
