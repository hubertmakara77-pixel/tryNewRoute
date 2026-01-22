#!/bin/bash

# --- 1. SZYBKA NAPRAWA INTERNETU (Bez tego apt update wywala błąd jak na zdjęciu) ---
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# --- 2. NAPRAWA LITERÓWEK W TWOIM SKRYPCIE (Network) ---
# Twój plik network_setup.sh ma błędy (If/Fi z dużej litery), co przerywa instalację.
# Naprawiamy to "w locie" zanim go uruchomisz.
if [ -f "scripts/network_setup.sh" ]; then
    sed -i 's/If /if /g' scripts/network_setup.sh
    sed -i 's/Fi/fi/g' scripts/network_setup.sh
    sed -i 's/Chmod/chmod/g' scripts/network_setup.sh
    sed -i 's/Echo/echo/g' scripts/network_setup.sh
    sed -i 's/Systemctl/systemctl/g' scripts/network_setup.sh
fi

chmod +x scripts/*.sh

if [ ! $UID -eq 0 ]; then
	echo "Please run script as root: sudo ./install.sh"
	exit 0
fi

# --- 3. TWOJA CZĘŚĆ (INSTALACJA) ---
apt update
# Dodaję ręcznie Pythona, bo Twoje skrypty go nie instalują, a jest potrzebny do strony
apt install -y python3

set -e
for script in scripts/*.sh; do
    echo ">>> Uruchamiam: $script"
	bash "$script"
done

# ==========================================================
# --- 4. MOJE DOPISKI (Żeby strona działała i zmieniała hasło) ---
# ==========================================================

echo ">>> Konfiguracja Backend Python i Uprawnień..."

# A. Wgrywamy API (Kod Python - ten działający)
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
    if not ssid: return {"status": "error", "message": "SSID pusty"}
    try:
        lines = []
        if os.path.exists(HOSTAPD_CONF):
            with open(HOSTAPD_CONF, 'r') as f: lines = f.readlines()
        new_l = []
        fs, fp = False, False
        for l in lines:
            if l.startswith('ssid='): new_l.append(f"ssid={ssid}\n"); fs=True
            elif l.startswith('wpa_passphrase='): new_l.append(f"wpa_passphrase={password}\n"); fp=True
            else: new_l.append(l)
        if not fs: new_l.append(f"ssid={ssid}\n")
        if not fp: new_l.append(f"wpa_passphrase={password}\n")
        
        with open(HOSTAPD_CONF, 'w') as f: f.writelines(new_l)
        # Restart hostapd (dzięki sudoers zadziała bez hasła)
        subprocess.check_output("sudo systemctl restart hostapd", shell=True, stderr=subprocess.STDOUT)
        return {"status": "success", "message": "Zapisano! Restart..."}
    except Exception as e: return {"status": "error", "message": str(e)}

print("Content-Type: application/json\n")
try:
    if os.environ.get("REQUEST_METHOD") == "POST":
        ln = int(os.environ.get('CONTENT_LENGTH', 0))
        d = json.loads(sys.stdin.read(ln))
        if d.get('action') == 'save_wifi': print(json.dumps(save(d.get('ssid'), d.get('password'))))
    else: print(json.dumps(get_conf()))
except Exception as e: print(json.dumps({"status": "error", "message": str(e)}))
PYTHONEOF

# B. Konfiguracja Lighttpd (Nadpisujemy config, żeby włączyć obsługę .py)
cat > /etc/lighttpd/lighttpd.conf <<EOF
server.modules = ( "mod_access", "mod_alias", "mod_redirect", "mod_cgi" )
server.document-root = "/var/www/html"
server.port = 80
index-file.names = ( "index.html" )
cgi.assign = ( ".py" => "/usr/bin/python3" )
include_shell "/usr/share/lighttpd/create-mime.conf.pl"
EOF

# C. Uprawnienia (To jest KLUCZOWE, bez tego masz Permission Denied)
# 1. Python wykonywalny
sed -i 's/\r$//' /usr/lib/cgi-bin/router_api.py
chmod +x /usr/lib/cgi-bin/router_api.py
chown www-data:www-data /usr/lib/cgi-bin/router_api.py

# 2. Plik hostapd (musi należeć do www-data, bo Twój skrypt tworzy go jako root)
chown www-data:www-data /etc/hostapd/hostapd.conf
chmod 666 /etc/hostapd/hostapd.conf

# 3. Zezwolenie na restart w sudoers
rm -f /etc/sudoers.d/router-web
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hostapd" > /etc/sudoers.d/router-web
chmod 0440 /etc/sudoers.d/router-web

# Restart usług na koniec
systemctl restart lighttpd
# Upewniamy się, że Twoje serwisy wstają
systemctl restart hostapd

echo "=== GOTOWE ==="
