#!/bin/bash

# Uruchom jako root
if [ "$EUID" -ne 0 ]; then echo "Uruchom przez sudo!"; exit; fi

echo "--- Uruchamiam TWOJE skrypty konfiguracji sieci ---"

# 1. Naprawiamy literówki w Twoim pliku network_setup.sh (If -> if), żeby zadziałał
if [ -f "scripts/network_setup.sh" ]; then
    sed -i 's/If/if/g' scripts/network_setup.sh
    sed -i 's/Fi/fi/g' scripts/network_setup.sh
    sed -i 's/Chmod/chmod/g' scripts/network_setup.sh
    sed -i 's/Echo/echo/g' scripts/network_setup.sh
    sed -i 's/Systemctl/systemctl/g' scripts/network_setup.sh
fi

# 2. Uruchamiamy Twoje skrypty (WiFi, DHCP, Internet)
# Zakładam, że są w folderze bieżącym lub w scripts/
chmod +x *.sh 2>/dev/null
chmod +x scripts/*.sh 2>/dev/null

# Uruchamiamy konfigurację interfejsów (IP 192.168.0.1)
if [ -f "scripts/interfaces_setup.sh" ]; then ./scripts/interfaces_setup.sh; 
elif [ -f "interfaces_setup.sh" ]; then ./interfaces_setup.sh; fi

# Uruchamiamy WiFi (To z fixem Unisoc)
if [ -f "scripts/ap_setup.sh" ]; then ./scripts/ap_setup.sh; 
elif [ -f "ap_setup.sh" ]; then ./ap_setup.sh; fi

# Uruchamiamy DHCP
if [ -f "scripts/dnsmasq.sh" ]; then ./scripts/dnsmasq.sh; 
elif [ -f "dnsmasq.sh" ]; then ./dnsmasq.sh; fi

# Uruchamiamy Internet (iptables)
if [ -f "scripts/iptables.sh" ]; then ./scripts/iptables.sh; 
elif [ -f "iptables.sh" ]; then ./iptables.sh; fi

echo "--- Twoja sieć jest gotowa. Teraz naprawiam TYLKO stronę WWW ---"

# 3. Konfiguracja Lighttpd (Muszę to zmienić, bo Twój plik nie obsługuje Pythona)
apt-get install -y lighttpd python3
systemctl stop lighttpd

cat > /etc/lighttpd/lighttpd.conf <<EOF
server.modules = (
    "mod_indexfile", "mod_access", "mod_alias", "mod_redirect", "mod_cgi"
)
server.document-root = "/var/www/html"
server.port = 80
index-file.names = ( "index.html" )
# TO JEST KLUCZOWE - Obsługa Pythona
cgi.assign = ( ".py" => "/usr/bin/python3" )
include_shell "/usr/share/lighttpd/create-mime.conf.pl"
EOF

# Kopiowanie strony
rm -rf /var/www/html/*
if [ -d "www/html" ]; then cp -r www/html/* /var/www/html/; 
elif [ -d "www" ]; then cp -r www/* /var/www/html/;
else cp * /var/www/html/ 2>/dev/null; fi
[ -f "/var/www/html/web_app.html" ] && mv /var/www/html/web_app.html /var/www/html/index.html

# 4. Wgrywam backend Python (Ten, który nie robi błędów przy zapisie)
mkdir -p /usr/lib/cgi-bin
cat > /usr/lib/cgi-bin/router_api.py << 'PYTHONEOF'
#!/usr/bin/env python3
import json, subprocess, os, sys, re
HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"

def run(cmd):
    try: return subprocess.check_output(cmd, shell=True, text=True).strip()
    except: return ""

def get_conf():
    ip = run("hostname -I | awk '{print $1}'") or "192.168.0.1"
    data = {'ip_address': ip, 'dhcp_start': '192.168.0.10'}
    try:
        with open(HOSTAPD_CONF, 'r') as f: c = f.read()
        s = re.search(r'^ssid=(.*)', c, re.MULTILINE)
        p = re.search(r'^wpa_passphrase=(.*)', c, re.MULTILINE)
        data['ssid'] = s.group(1).strip() if s else ""
        data['wifi_pass'] = p.group(1).strip() if p else ""
    except: pass
    return data

def save(ssid, password):
    if not ssid: return {"status": "error"}
    try:
        # Odczyt
        with open(HOSTAPD_CONF, 'r') as f: lines = f.readlines()
        new_l = []
        fs, fp = False, False
        for l in lines:
            if l.startswith('ssid='): new_l.append(f"ssid={ssid}\n"); fs=True
            elif l.startswith('wpa_passphrase='): new_l.append(f"wpa_passphrase={password}\n"); fp=True
            else: new_l.append(l)
        if not fs: new_l.append(f"ssid={ssid}\n")
        if not fp: new_l.append(f"wpa_passphrase={password}\n")
        
        # Zapis (Dzięki uprawnieniom poniżej to zadziała)
        with open(HOSTAPD_CONF, 'w') as f: f.writelines(new_l)
        run("sudo systemctl restart hostapd")
        return {"status": "success"}
    except Exception as e: return {"status": "error", "msg": str(e)}

print("Content-Type: application/json\n")
try:
    if os.environ.get("REQUEST_METHOD") == "POST":
        d = json.loads(sys.stdin.read(int(os.environ.get('CONTENT_LENGTH', 0))))
        if d.get('action') == 'save_wifi': print(json.dumps(save(d.get('ssid'), d.get('password'))))
    else: print(json.dumps(get_conf()))
except: print(json.dumps({"status": "error"}))
PYTHONEOF
chmod +x /usr/lib/cgi-bin/router_api.py

# 5. UPRAWNIENIA (To jest to, co naprawia błąd zapisu!)
# Oddajemy plik konfiguracyjny stronie WWW
chown www-data:www-data /etc/hostapd/hostapd.conf
chmod 664 /etc/hostapd/hostapd.conf

# Pozwalamy stronie resetować WiFi po zmianie hasła
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hostapd" > /etc/sudoers.d/router-web
chmod 0440 /etc/sudoers.d/router-web

# Restart
systemctl restart lighttpd
systemctl restart dnsmasq
systemctl restart hostapd

echo "GOTOWE. Użyto Twoich plików sieciowych + naprawiono zapis na stronie."
