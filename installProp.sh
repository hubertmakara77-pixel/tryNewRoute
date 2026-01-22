#!/bin/bash

# Upewnij się, że jesteś rootem
if [ "$EUID" -ne 0 ]; then echo "Uruchom przez sudo!"; exit; fi

echo "=== START INSTALACJI HYBRYDOWEJ ==="

# 1. Instalacja pakietów
apt-get update
apt-get install -y hostapd dnsmasq lighttpd python3 iptables netfilter-persistent iptables-persistent

# 2. Fix dla WiFi (z Twojego pliku ap_setup.sh)
echo "[INFO] Instalowanie poprawki Unisoc WiFi..."
cat > /usr/local/bin/unisoc-wifi-fix.sh <<-'EOF'
#!/bin/bash
IFACE="wlan0"
for i in {1..10}; do
    if ip link show $IFACE > /dev/null 2>&1; then break; fi
    sleep 1
done
iw dev $IFACE set power_save off 2>/dev/null
ip link set $IFACE txqueuelen 100 2>/dev/null
ethtool -K $IFACE gro off 2>/dev/null
ethtool -K $IFACE lro off 2>/dev/null
ip link set $IFACE up 2>/dev/null
exit 0
EOF
chmod +x /usr/local/bin/unisoc-wifi-fix.sh

cat > /etc/systemd/system/unisoc-wifi-fix.service <<EOF
[Unit]
Description=Unisoc WiFi Fix
After=network-pre.target
Before=hostapd.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/unisoc-wifi-fix.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now unisoc-wifi-fix.service

# 3. Konfiguracja WiFi (HOSTAPD) - Używam danych z Twojego pliku
echo "[INFO] Konfiguracja Hostapd..."
cat > /etc/hostapd/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
# Tutaj wpisuje dane z Twojego pliku ap_setup.sh
ssid=dsadasd
hw_mode=g
channel=6
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=cycki123
rsn_pairwise=CCMP
ieee80211n=1
wmm_enabled=1
country_code=PL
EOF
# Wskazanie configu
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

# 4. Konfiguracja DHCP (DNSMASQ)
echo "[INFO] Konfiguracja DHCP..."
cat > /etc/dnsmasq.conf <<EOF
interface=wlan0
dhcp-range=192.168.0.10,192.168.0.50,24h
server=8.8.8.8
EOF

# 5. Konfiguracja Internetu (IPTABLES - naprawione)
echo "[INFO] Konfiguracja Internetu..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
sysctl -p /etc/sysctl.d/99-ipforward.conf

iptables -F
iptables -t nat -F
# Wykrywanie interfejsu kablowego (end0 lub eth0)
ETH=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(e|en)' | head -n 1)
[ -z "$ETH" ] && ETH="end0"

iptables -t nat -A POSTROUTING -o $ETH -j MASQUERADE
iptables -A FORWARD -i $ETH -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o $ETH -j ACCEPT

netfilter-persistent save

# Przypisanie IP do WiFi
ip link set wlan0 down
ip addr flush dev wlan0
ip addr add 192.168.0.1/24 dev wlan0
ip link set wlan0 up

# 6. Konfiguracja WWW i Python (Naprawione, bo Twój lighttpd.sh tego nie miał)
echo "[INFO] Konfiguracja WWW i Python..."
systemctl stop lighttpd
cat > /etc/lighttpd/lighttpd.conf <<EOF
server.modules = (
    "mod_indexfile", "mod_access", "mod_alias", "mod_redirect", "mod_cgi"
)
server.document-root = "/var/www/html"
server.port = 80
index-file.names = ( "index.html" )
cgi.assign = ( ".py" => "/usr/bin/python3" )
include_shell "/usr/share/lighttpd/create-mime.conf.pl"
EOF

# Kopiowanie Twojej strony
rm -rf /var/www/html/*
if [ -d "www/html" ]; then cp -r www/html/* /var/www/html/; 
elif [ -d "www" ]; then cp -r www/* /var/www/html/;
else cp * /var/www/html/ 2>/dev/null; fi
[ -f "/var/www/html/web_app.html" ] && mv /var/www/html/web_app.html /var/www/html/index.html

# 7. Wgrywanie backendu Python (POPRAWIONEGO)
# Twój stary kod Pythona używał 'tee' i 'cgitb', co powodowało błędy zapisu.
# Ten kod poniżej działa bezpośrednio.
mkdir -p /usr/lib/cgi-bin
cat > /usr/lib/cgi-bin/router_api.py << 'PYTHONEOF'
#!/usr/bin/env python3
import json, subprocess, os, sys, re
HOSTAPD_CONF = "/etc/hostapd/hostapd.conf"

def run(cmd):
    try: return subprocess.check_output(cmd, shell=True, text=True).strip()
    except: return ""

def get_conf():
    data = {'ip': run("hostname -I | awk '{print $1}'") or "192.168.0.1"}
    try:
        with open(HOSTAPD_CONF, 'r') as f: c = f.read()
        s = re.search(r'^ssid=(.*)', c, re.MULTILINE)
        p = re.search(r'^wpa_passphrase=(.*)', c, re.MULTILINE)
        data['ssid'] = s.group(1) if s else ""
        data['pass'] = p.group(1) if p else ""
    except: pass
    return data

def save(ssid, password):
    if not ssid: return {"status": "error"}
    try:
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

# 8. Uprawnienia i Start
chown www-data:www-data /etc/hostapd/hostapd.conf
chmod 664 /etc/hostapd/hostapd.conf
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart hostapd" > /etc/sudoers.d/router-web
chmod 0440 /etc/sudoers.d/router-web

systemctl unmask hostapd
systemctl stop systemd-networkd
systemctl stop wpa_supplicant
systemctl restart dnsmasq
systemctl restart hostapd
systemctl restart lighttpd

echo "=== GOTOWE ==="
echo "Sieć: dsadasd / Hasło: cycki123 (wzięte z Twojego pliku)"
echo "Strona: http://192.168.0.1"
